import Foundation

enum TranscriptText {
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
            merged(base: partialResult, tail: piece)
        }
    }

    nonisolated static func merged(base: String, tail: String) -> String {
        let base = clean(base)
        let tail = clean(tail)

        guard !base.isEmpty else { return tail }
        guard !tail.isEmpty else { return base }

        let baseWords = words(in: base)
        let tailWords = words(in: tail)

        guard !baseWords.isEmpty else { return tail }
        guard !tailWords.isEmpty else { return base }

        let baseComparableWords = baseWords.map(comparableWord)
        let tailComparableWords = tailWords.map(comparableWord)

        if isRedundantTail(tailComparableWords, after: baseComparableWords, minimumWordCount: 1) {
            return base
        }

        let maxOverlap = min(baseWords.count, tailWords.count, 24)
        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            let baseSuffix = Array(baseComparableWords.suffix(overlap))
            let tailPrefix = Array(tailComparableWords.prefix(overlap))

            guard overlaps(baseSuffix, tailPrefix) else { continue }

            let newTailWords = Array(tailWords.dropFirst(overlap))
            let newTailComparableWords = Array(tailComparableWords.dropFirst(overlap))

            if isRedundantTail(newTailComparableWords, after: baseComparableWords, minimumWordCount: 2) {
                return base
            }

            let newTail = newTailWords.joined(separator: " ")
            return newTail.isEmpty ? base : "\(base) \(newTail)"
        }

        return "\(base) \(tail)"
    }

    nonisolated private static func words(in transcript: String) -> [String] {
        transcript.split(separator: " ").map(String.init)
    }

    nonisolated private static func comparableWord(_ word: String) -> String {
        word
            .lowercased()
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
        default:
            return Double(exactMatches) / Double(pairs.count) >= 0.68
        }
    }

    nonisolated private static func wordsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs)
    }
}
