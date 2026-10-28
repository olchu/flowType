import Foundation

/// The text rules the user has switched on in Settings → Text Rules, applied
/// to the final text of every dictation, whatever the cleanup mode.
nonisolated struct TextRules: Sendable {
    var removesFillerWords: Bool
    var fillerWords: [String]
    var writesNumbersAsDigits: Bool
    var keepsSmallNumbersAsWords: Bool
    var writesSpokenPunctuation: Bool
    var endsWithoutFullStop: Bool
    var wordReplacements: [WordReplacement]
    /// Only those that work inside a phrase apply here; a dictation of just
    /// a snippet's phrase never reaches the rules.
    var snippets: [Snippet]

    func apply(to text: String) -> String {
        var text = text
        // Before the spoken marks, so a "точка" said at the end still
        // writes one.
        if endsWithoutFullStop {
            text = Self.removingFinalFullStop(from: text)
        }
        // While the recogniser's commas still mark the pauses that tell a
        // command from a word: removing a filler takes one with it.
        if writesSpokenPunctuation {
            text = VoicePunctuation.applying(to: text)
        }

        let replacements = wordReplacements.map { (heard: $0.heard, written: $0.written) }
            + snippets.filter(\.worksInsidePhrase).flatMap { snippet in
                snippet.triggers.map { (heard: $0, written: snippet.text) }
            }
        // Line by line, as the rules below read a line a space at a time.
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            // First, while the words are still as heard: "айфон
            // пятнадцать" would no longer match once it reads "айфон 15".
            var line = PhraseReplacements.applying(replacements, to: String(line))
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

    /// "Привет." → "Привет". Leaves "?", "!", "…" and abbreviations such
    /// as "т.д." alone.
    static func removingFinalFullStop(from text: String) -> String {
        guard text.hasSuffix("."), !text.hasSuffix(".."),
              let lastWord = text.split(separator: " ").last,
              !lastWord.dropLast().contains(".")
        else {
            return text
        }
        return String(text.dropLast())
    }
}
