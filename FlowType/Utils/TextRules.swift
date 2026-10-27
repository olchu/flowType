import Foundation

/// The text rules the user has switched on in Settings → Text Rules, applied
/// to the final text of every dictation, whatever the cleanup mode.
nonisolated struct TextRules: Sendable {
    var removesFillerWords: Bool
    var fillerWords: [String]
    var writesNumbersAsDigits: Bool
    var keepsSmallNumbersAsWords: Bool

    func apply(to text: String) -> String {
        var text = text
        if removesFillerWords {
            text = FillerWords.removing(fillerWords, from: text)
        }
        if writesNumbersAsDigits {
            text = SpokenNumbers.digits(in: text, keepsSmallNumbersAsWords: keepsSmallNumbersAsWords)
        }
        return text
    }
}
