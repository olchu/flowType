import Foundation

/// The text rules the user has switched on in Settings → Text Rules, applied
/// to the final text of every dictation, whatever the cleanup mode.
nonisolated struct TextRules: Sendable {
    var removesFillerWords: Bool
    var fillerWords: [String]
    var writesNumbersAsDigits: Bool
    var keepsSmallNumbersAsWords: Bool
    var writesSpokenPunctuation: Bool

    func apply(to text: String) -> String {
        // First, while the recogniser's commas still mark the pauses that
        // tell a command from a word: removing a filler takes one with it.
        let text = writesSpokenPunctuation ? VoicePunctuation.applying(to: text) : text
        // Line by line, as the rules below read a line a space at a time.
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var line = String(line)
            if removesFillerWords {
                line = FillerWords.removing(fillerWords, from: line)
            }
            if writesNumbersAsDigits {
                line = SpokenNumbers.digits(in: line, keepsSmallNumbersAsWords: keepsSmallNumbersAsWords)
            }
            return line
        }
        .joined(separator: "\n")
    }
}
