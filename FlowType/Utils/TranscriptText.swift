import Foundation

enum TranscriptText {
    nonisolated static func clean(_ text: String) -> String {
        let normalized = text.replacing(
            /<\|[^|]+\|>/,
            with: ""
        )
        .replacing(
            /\s+/,
            with: " "
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)

        return removingLocalDuplicateWords(from: normalized)
    }

    /// Joins text decoded from adjacent, non-overlapping audio ranges. Unlike
    /// `merged`, it never drops words on a fuzzy match: only an exact repeat
    /// of at least two words across the boundary is removed.
    nonisolated static func joined(prefix: String, continuation: String) -> String {
        let prefix = clean(prefix)
        let continuation = clean(continuation)
        guard !prefix.isEmpty else { return continuation }
        guard !continuation.isEmpty else { return prefix }

        let prefixWords = words(in: prefix).map(comparableWord)
        let continuationWords = words(in: continuation)
        let continuationComparableWords = continuationWords.map(comparableWord)
        let maximumOverlap = min(8, prefixWords.count, continuationWords.count)

        if maximumOverlap >= 2 {
            for overlap in stride(from: maximumOverlap, through: 2, by: -1)
            where Array(prefixWords.suffix(overlap)) == Array(continuationComparableWords.prefix(overlap)) {
                let rest = continuationWords.dropFirst(overlap).joined(separator: " ")
                return rest.isEmpty ? prefix : "\(prefix) \(rest)"
            }
        }

        return "\(prefix) \(continuation)"
    }

    /// Whisper fills silence and noise with phrases from video subtitles.
    /// A segment consisting of one of them carries no dictated speech.
    nonisolated static func isLikelyHallucination(_ segment: String) -> Bool {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.wholeMatch(of: /[\[\(\*♪][^\]\)\*♪]*[\]\)\*♪]/) != nil {
            return true
        }

        let normalizedWords = words(in: clean(trimmed)).map(comparableWord).filter { !$0.isEmpty }
        let normalized = normalizedWords.joined(separator: " ")

        return hallucinationPhrases.contains { phrase in
            normalized.contains(phrase)
                && normalizedWords.count <= phrase.split(separator: " ").count + 3
        }
    }

    nonisolated private static let hallucinationPhrases = [
        "продолжение следует",
        "субтитры сделал",
        "субтитры создавал",
        "субтитры подготовил",
        "редактор субтитров",
        "субтитры by",
        "dimatorzok",
        "спасибо за просмотр",
        "подписывайтесь на канал",
        "ставьте лайки",
        "thank you for watching",
        "thanks for watching",
        "subtitles by"
    ]

    nonisolated static func merged(_ pieces: [String]) -> String {
        pieces.reduce("") { merged(base: $0, tail: $1) }
    }

    nonisolated private static func merged(base: String, tail: String) -> String {
        let base = clean(base)
        let tail = clean(tail)
        guard !base.isEmpty else { return tail }
        guard !tail.isEmpty else { return base }

        let baseComparableWords = words(in: base).map(comparableWord)
        let tailWords = words(in: tail)
        let tailComparableWords = tailWords.map(comparableWord)

        if isRedundantTail(tailComparableWords, after: baseComparableWords, minimumWordCount: 1) {
            return base
        }

        guard let droppedTailWords = bestAlignedOverlap(base: baseComparableWords, tail: tailComparableWords) else {
            return "\(base) \(tail)"
        }

        let newTailComparableWords = Array(tailComparableWords.dropFirst(droppedTailWords))
        if isRedundantTail(newTailComparableWords, after: baseComparableWords, minimumWordCount: 2) {
            return base
        }

        return "\(base) \(tailWords.dropFirst(droppedTailWords).joined(separator: " "))"
    }

    nonisolated static func words(in transcript: String) -> [String] {
        transcript.split(separator: " ").map(String.init)
    }

    nonisolated private static func removingLocalDuplicateWords(from transcript: String) -> String {
        let tokens = words(in: transcript)
        guard tokens.count > 1 else { return transcript }

        var result: [String] = []
        result.reserveCapacity(tokens.count)

        var tokenIndex = tokens.startIndex
        while tokenIndex < tokens.endIndex {
            let token = tokens[tokenIndex]

            if let echoRange = spokenNumberEchoRangeReplacement(startingAt: tokenIndex, in: tokens) {
                result.append(token)
                result.append(echoRange.replacement)
                tokenIndex = echoRange.nextIndex
                continue
            }

            if let previous = result.last, shouldDropAdjacentDuplicate(previous: previous, current: token) {
                if let merged = tokenWithTransferredTerminalPunctuation(previous: previous, current: token) {
                    result[result.count - 1] = merged
                }
                tokenIndex = tokens.index(after: tokenIndex)
                continue
            }

            let noiseIndex = tokens.index(after: tokenIndex)
            let duplicateIndex = tokens.index(noiseIndex, offsetBy: 1, limitedBy: tokens.endIndex)
            if let duplicateIndex,
               duplicateIndex < tokens.endIndex,
               isNumericFragment(tokens[noiseIndex]),
               shouldDropAdjacentDuplicate(previous: token, current: tokens[duplicateIndex]) {
                result.append(token)
                tokenIndex = tokens.index(after: duplicateIndex)
                continue
            }

            result.append(token)
            tokenIndex = tokens.index(after: tokenIndex)
        }

        return result.joined(separator: " ")
    }

    nonisolated private static func shouldDropAdjacentDuplicate(previous: String, current: String) -> Bool {
        let previousComparable = comparableWord(previous)
        let currentComparable = comparableWord(current)

        guard previousComparable.count >= 5 && currentComparable.count >= 5 else {
            return false
        }

        return wordsMatch(previousComparable, currentComparable)
    }

    nonisolated private static func tokenWithTransferredTerminalPunctuation(previous: String, current: String) -> String? {
        guard terminalPunctuation(in: previous) == nil, let punctuation = terminalPunctuation(in: current) else {
            return nil
        }

        return "\(previous)\(punctuation)"
    }

    nonisolated private static func isTerminalPunctuation(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?"
    }

    nonisolated private static func isNumericFragment(_ token: String) -> Bool {
        let scalarView = token.unicodeScalars
        let hasDigit = scalarView.contains { CharacterSet.decimalDigits.contains($0) }
        let hasSeparator = scalarView.contains { scalar in
            scalar == "." || scalar == "," || scalar == ":" || scalar == ";"
        }

        return hasDigit && hasSeparator
    }

    nonisolated private static func spokenNumberEchoRangeReplacement(
        startingAt tokenIndex: [String].Index,
        in tokens: [String]
    ) -> (replacement: String, nextIndex: [String].Index)? {
        let firstToken = tokens[tokenIndex]
        guard let firstNumber = digit(forSpokenNumber: comparableWord(firstToken)) else {
            return nil
        }

        let nextIndex = tokens.index(after: tokenIndex)
        guard nextIndex < tokens.endIndex else { return nil }

        let rangeIndex: [String].Index
        if comparableWord(tokens[nextIndex]) == "это" {
            rangeIndex = tokens.index(after: nextIndex)
        } else {
            rangeIndex = nextIndex
        }

        guard rangeIndex < tokens.endIndex else { return nil }
        guard let range = smallNumericRange(in: tokens[rangeIndex]), range.lowerBound == firstNumber else {
            return nil
        }
        guard let secondNumber = spokenNumber(forDigit: range.upperBound) else {
            return nil
        }

        let replacement = if let punctuation = terminalPunctuation(in: tokens[rangeIndex]) {
            "\(secondNumber)\(punctuation)"
        } else {
            secondNumber
        }

        return (replacement, tokens.index(after: rangeIndex))
    }

    nonisolated private static func smallNumericRange(in token: String) -> ClosedRange<Int>? {
        let trimmed = token.trimmingCharacters(in: .punctuationCharacters)
        let parts = trimmed.split { character in
            character == "-" || character == "–" || character == "—"
        }
        guard parts.count == 2, let lower = Int(parts[0]), let upper = Int(parts[1]) else {
            return nil
        }
        guard (0...10).contains(lower), (0...10).contains(upper), lower < upper else {
            return nil
        }

        return lower...upper
    }

    nonisolated private static func terminalPunctuation(in token: String) -> Character? {
        guard let last = token.last, isTerminalPunctuation(last) else { return nil }
        return last
    }

    nonisolated private static let spokenNumbers = [
        "ноль", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять", "десять"
    ]

    nonisolated private static func digit(forSpokenNumber word: String) -> Int? {
        switch word {
        case "одна", "одно": 1
        case "две": 2
        default: spokenNumbers.firstIndex(of: word)
        }
    }

    nonisolated private static func spokenNumber(forDigit digit: Int) -> String? {
        spokenNumbers.indices.contains(digit) ? spokenNumbers[digit] : nil
    }

    /// Lowercased, ё-insensitive form of a word without surrounding punctuation.
    nonisolated static func comparableWord(_ word: String) -> String {
        word
            .lowercased()
            // Whisper commonly alternates between е and ё across overlapping
            // streaming and final-tail decodes. Treat them as the same word so
            // a repeated tail is not appended as a second sentence.
            .replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }

    nonisolated private static func isRedundantTail(_ tail: [String], after base: [String], minimumWordCount: Int) -> Bool {
        guard !tail.isEmpty else { return true }
        guard tail.count >= minimumWordCount else { return false }
        guard tail.count <= base.count else { return false }

        let baseSuffix = Array(base.suffix(tail.count))
        return overlaps(baseSuffix, tail)
    }

    nonisolated private static func overlaps(_ lhs: [String], _ rhs: [String]) -> Bool {
        guard lhs.count == rhs.count else { return false }

        let pairs = zip(lhs, rhs).filter { !$0.0.isEmpty && !$0.1.isEmpty }
        guard !pairs.isEmpty else { return false }

        let exactMatches = pairs.reduce(0) { count, pair in
            count + (wordsMatch(pair.0, pair.1) ? 1 : 0)
        }

        switch pairs.count {
        case 1:
            return exactMatches == 1
        case 2:
            return exactMatches == 2
        case 3:
            // Final-tail decoding often hallucinates a different lead-in word
            // while repeating the same two-word ending, for example:
            // "работает мой переводчик" -> "Вот мой переводчик".
            return exactMatches >= 2
        default:
            return Double(exactMatches) / Double(pairs.count) >= 0.68
        }
    }

    /// Returns how many leading tail words repeat the end of `base`.
    nonisolated private static func bestAlignedOverlap(base: [String], tail: [String]) -> Int? {
        let baseWindow = Array(base.suffix(28))
        let tailWindow = Array(tail.prefix(24))
        // `wordsMatch` runs an edit distance; compare every pair only once.
        let matches = baseWindow.map { baseWord in tailWindow.map { wordsMatch(baseWord, $0) } }
        var best: (droppedTailWords: Int, score: Double)?

        for tailPrefixCount in stride(from: tailWindow.count, through: 1, by: -1) {
            for baseSuffixCount in stride(from: baseWindow.count, through: 1, by: -1) {
                let matchedWords = longestCommonSubsequence(
                    lhsIndices: (baseWindow.count - baseSuffixCount)..<baseWindow.count,
                    rhsCount: tailPrefixCount
                ) { matches[$0][$1] }

                guard acceptsAlignedOverlap(
                    matchedWords: matchedWords,
                    baseSuffixCount: baseSuffixCount,
                    tailPrefixCount: tailPrefixCount
                ) else {
                    continue
                }

                let coverage = Double(matchedWords) / Double(tailPrefixCount)
                let score = coverage + Double(tailPrefixCount) * 0.02 + Double(matchedWords) * 0.04

                if best == nil || score > best!.score {
                    best = (tailPrefixCount, score)
                }
            }
        }

        return best?.droppedTailWords
    }

    nonisolated private static func acceptsAlignedOverlap(
        matchedWords: Int,
        baseSuffixCount: Int,
        tailPrefixCount: Int
    ) -> Bool {
        guard matchedWords > 0 else { return false }

        switch tailPrefixCount {
        case 1:
            return matchedWords == 1 && baseSuffixCount == 1
        case 2:
            return matchedWords == 2
        case 3:
            return matchedWords >= 2
        default:
            let tailCoverage = Double(matchedWords) / Double(tailPrefixCount)
            let baseCoverage = Double(matchedWords) / Double(baseSuffixCount)
            return matchedWords >= 3 && tailCoverage >= 0.62 && baseCoverage >= 0.45
        }
    }

    /// Number of words two comparable-word lists share in the same order.
    nonisolated static func orderedMatchCount(_ lhs: [String], _ rhs: [String]) -> Int {
        longestCommonSubsequence(lhsIndices: lhs.indices, rhsCount: rhs.count) { wordsMatch(lhs[$0], rhs[$1]) }
    }

    nonisolated private static func longestCommonSubsequence(
        lhsIndices: Range<Int>,
        rhsCount: Int,
        matches: (Int, Int) -> Bool
    ) -> Int {
        var previousRow = Array(repeating: 0, count: rhsCount + 1)

        for lhsIndex in lhsIndices {
            var currentRow = Array(repeating: 0, count: rhsCount + 1)

            for rhsIndex in 0..<rhsCount {
                currentRow[rhsIndex + 1] = matches(lhsIndex, rhsIndex)
                    ? previousRow[rhsIndex] + 1
                    : max(previousRow[rhsIndex + 1], currentRow[rhsIndex])
            }

            previousRow = currentRow
        }

        return previousRow[rhsCount]
    }

    /// Compares two comparable words, tolerating the small inflection
    /// differences Whisper produces between decodes.
    nonisolated static func wordsMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty && !rhs.isEmpty else { return false }

        if lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) {
            return true
        }

        // Overlapping Whisper decodes often disagree only on the last letter of
        // Russian inflections ("очистке" vs "очистки"). Treat a single edit in
        // medium/long words as the same word so the final tail is not appended
        // as a duplicate phrase.
        guard min(lhs.count, rhs.count) >= 5 else {
            return false
        }

        let distanceLimit = max(lhs.count, rhs.count) >= 8 ? 2 : 1
        return editDistance(lhs, rhs, limit: distanceLimit) <= distanceLimit
    }

    nonisolated private static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let lhsCharacters = Array(lhs)
        let rhsCharacters = Array(rhs)

        guard abs(lhsCharacters.count - rhsCharacters.count) <= limit else {
            return limit + 1
        }

        var previousRow = Array(0...rhsCharacters.count)

        for (lhsIndex, lhsCharacter) in lhsCharacters.enumerated() {
            var currentRow = [lhsIndex + 1]
            currentRow.reserveCapacity(rhsCharacters.count + 1)

            var rowMinimum = currentRow[0]
            for (rhsIndex, rhsCharacter) in rhsCharacters.enumerated() {
                let insertion = currentRow[rhsIndex] + 1
                let deletion = previousRow[rhsIndex + 1] + 1
                let substitution = previousRow[rhsIndex] + (lhsCharacter == rhsCharacter ? 0 : 1)
                let value = min(insertion, deletion, substitution)

                currentRow.append(value)
                rowMinimum = min(rowMinimum, value)
            }

            if rowMinimum > limit {
                return limit + 1
            }

            previousRow = currentRow
        }

        return previousRow.last ?? limit + 1
    }
}
