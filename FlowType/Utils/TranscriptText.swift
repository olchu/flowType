import Foundation

enum TranscriptText {
    struct MergeResult {
        let text: String
        let decision: String
        let overlapWords: Int
        let droppedTailWords: Int
        let baseWordCount: Int
        let tailWordCount: Int

        var diagnosticDescription: String {
            [
                "decision=\(decision)",
                "overlapWords=\(overlapWords)",
                "droppedTailWords=\(droppedTailWords)",
                "baseWords=\(baseWordCount)",
                "tailWords=\(tailWordCount)"
            ].joined(separator: " ")
        }
    }

    nonisolated static func clean(_ text: String) -> String {
        text.replacing(
            /<\|[^|]+\|>/,
            with: ""
        )
        .replacing(
            /\s+/,
            with: " "
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func merged(_ pieces: [String]) -> String {
        pieces.reduce("") { partialResult, piece in
            mergedResult(base: partialResult, tail: piece).text
        }
    }

    nonisolated static func merged(base: String, tail: String) -> String {
        mergedResult(base: base, tail: tail).text
    }

    nonisolated static func mergedResult(base: String, tail: String) -> MergeResult {
        let base = clean(base)
        let tail = clean(tail)

        guard !base.isEmpty else {
            return MergeResult(
                text: tail,
                decision: "empty-base",
                overlapWords: 0,
                droppedTailWords: 0,
                baseWordCount: 0,
                tailWordCount: words(in: tail).count
            )
        }
        guard !tail.isEmpty else {
            return MergeResult(
                text: base,
                decision: "empty-tail",
                overlapWords: 0,
                droppedTailWords: 0,
                baseWordCount: words(in: base).count,
                tailWordCount: 0
            )
        }

        let baseWords = words(in: base)
        let tailWords = words(in: tail)

        guard !baseWords.isEmpty else {
            return MergeResult(
                text: tail,
                decision: "empty-base-words",
                overlapWords: 0,
                droppedTailWords: 0,
                baseWordCount: 0,
                tailWordCount: tailWords.count
            )
        }
        guard !tailWords.isEmpty else {
            return MergeResult(
                text: base,
                decision: "empty-tail-words",
                overlapWords: 0,
                droppedTailWords: 0,
                baseWordCount: baseWords.count,
                tailWordCount: 0
            )
        }

        let baseComparableWords = baseWords.map(comparableWord)
        let tailComparableWords = tailWords.map(comparableWord)

        if isRedundantTail(tailComparableWords, after: baseComparableWords, minimumWordCount: 1) {
            return MergeResult(
                text: base,
                decision: "redundant-tail",
                overlapWords: tailWords.count,
                droppedTailWords: tailWords.count,
                baseWordCount: baseWords.count,
                tailWordCount: tailWords.count
            )
        }

        if let overlap = bestAlignedOverlap(base: baseComparableWords, tail: tailComparableWords) {
            let newTailWords = Array(tailWords.dropFirst(overlap.droppedTailWords))
            let newTailComparableWords = Array(tailComparableWords.dropFirst(overlap.droppedTailWords))

            if isRedundantTail(newTailComparableWords, after: baseComparableWords, minimumWordCount: 2) {
                return MergeResult(
                    text: base,
                    decision: "aligned-redundant-tail",
                    overlapWords: overlap.matchedWords,
                    droppedTailWords: tailWords.count,
                    baseWordCount: baseWords.count,
                    tailWordCount: tailWords.count
                )
            }

            let newTail = newTailWords.joined(separator: " ")
            return MergeResult(
                text: newTail.isEmpty ? base : "\(base) \(newTail)",
                decision: newTail.isEmpty ? "aligned-empty-tail" : "aligned-overlap",
                overlapWords: overlap.matchedWords,
                droppedTailWords: overlap.droppedTailWords,
                baseWordCount: baseWords.count,
                tailWordCount: tailWords.count
            )
        }

        return MergeResult(
            text: "\(base) \(tail)",
            decision: "append-tail",
            overlapWords: 0,
            droppedTailWords: 0,
            baseWordCount: baseWords.count,
            tailWordCount: tailWords.count
        )
    }

    nonisolated private static func words(in transcript: String) -> [String] {
        transcript.split(separator: " ").map(String.init)
    }

    nonisolated private static func comparableWord(_ word: String) -> String {
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

    nonisolated private static func bestAlignedOverlap(base: [String], tail: [String]) -> (droppedTailWords: Int, matchedWords: Int)? {
        let maxTailPrefix = min(tail.count, 24)
        let maxBaseSuffix = min(base.count, 28)
        var best: (droppedTailWords: Int, matchedWords: Int, score: Double)?

        for tailPrefixCount in stride(from: maxTailPrefix, through: 1, by: -1) {
            let tailPrefix = Array(tail.prefix(tailPrefixCount))

            for baseSuffixCount in stride(from: maxBaseSuffix, through: 1, by: -1) {
                let baseSuffix = Array(base.suffix(baseSuffixCount))
                let matchedWords = alignedMatchCount(baseSuffix, tailPrefix)

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
                    best = (tailPrefixCount, matchedWords, score)
                }
            }
        }

        guard let best else { return nil }
        return (best.droppedTailWords, best.matchedWords)
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

    nonisolated private static func alignedMatchCount(_ base: [String], _ tail: [String]) -> Int {
        guard !base.isEmpty && !tail.isEmpty else { return 0 }

        var previousRow = Array(repeating: 0, count: tail.count + 1)

        for baseWord in base {
            var currentRow = Array(repeating: 0, count: tail.count + 1)

            for tailIndex in tail.indices {
                if wordsMatch(baseWord, tail[tailIndex]) {
                    currentRow[tailIndex + 1] = previousRow[tailIndex] + 1
                } else {
                    currentRow[tailIndex + 1] = max(previousRow[tailIndex + 1], currentRow[tailIndex])
                }
            }

            previousRow = currentRow
        }

        return previousRow.last ?? 0
    }

    nonisolated private static func wordsMatch(_ lhs: String, _ rhs: String) -> Bool {
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
