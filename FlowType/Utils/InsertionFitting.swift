import Foundation
import NaturalLanguage

/// Fits a dictation into the text around the cursor, so it reads as part of
/// it:
///
/// - after a word, a digit or a comma it goes on with a small letter and a
///   space between: "Привет|" + "Как дела" → "Привет как дела";
/// - at the start of a field, a line or a sentence it takes a capital;
/// - with text after the cursor on the same line it leaves out its full
///   stop and keeps a space before that text.
///
/// Names keep their capital wherever they land: "Привет|" + "Маша" stays
/// "Привет Маша".
nonisolated enum InsertionFitting {
    /// `before` and `after` are the text on either side of the cursor, nil
    /// when the field doesn't tell it. With `keepsWording`, as for a
    /// snippet, only the spaces around the text change.
    static func fit(_ text: String, before: String?, after: String?, keepsWording: Bool = false) -> String {
        var text = text
        if let before {
            text = fittingStart(of: text, after: before, keepsWording: keepsWording)
        }
        if let after {
            text = fittingEnd(of: text, before: after, keepsWording: keepsWording)
        }
        return text
    }

    /// Marks that go on the sentence, so the next word takes a small letter.
    private static let continuingMarks: Set<Character> = [",", ";", ":", "—", "–", "-"]
    /// Marks the next word follows without a space.
    private static let openingMarks: Set<Character> = ["(", "[", "{", "«", "“", "„", "/"]
    /// Marks that follow the word before without a space.
    private static let attachingMarks: Set<Character> = [".", ",", "!", "?", ":", ";", "…", ")", "]", "}", "»", "”"]

    private static func fittingStart(of text: String, after before: String, keepsWording: Bool) -> String {
        var text = keepsWording ? text : fittingCase(of: text, after: before)
        if let last = before.last, !last.isWhitespace, !openingMarks.contains(last),
           let first = text.first, !first.isWhitespace, !attachingMarks.contains(first) {
            text = " " + text
        }
        return text
    }

    private static func fittingCase(of text: String, after before: String) -> String {
        let preceding = withoutTrailingSpaces(before[...])
        let previous = preceding.last
        // A dash that starts its line is a list item or a line of
        // dialogue, which starts with a capital.
        let isLineStartDash = previous.map { "-–—•".contains($0) } == true
            && (withoutTrailingSpaces(preceding.dropLast()).last?.isNewline ?? true)
        if isLineStartDash || previous.map({ $0.isNewline || TranscriptText.sentenceEnds.contains($0) }) ?? true {
            return changingFirstWord(of: text, with: TranscriptText.capitalizingFirstLetter)
        }
        if let previous, previous.isLetter || previous.isNumber || continuingMarks.contains(previous), !startsWithName(text) {
            return changingFirstWord(of: text, with: TranscriptText.lowercasingFirstLetter)
        }
        return text
    }

    private static func fittingEnd(of text: String, before after: String, keepsWording: Bool) -> String {
        var text = text
        if !keepsWording, after.prefix(while: { !$0.isNewline }).contains(where: { !$0.isWhitespace }) {
            text = TextRules.removingFinalFullStop(from: text)
        }
        if let next = after.first, next.isLetter || next.isNumber,
           let last = text.last, !last.isWhitespace, !openingMarks.contains(last) {
            text += " "
        }
        return text
    }

    private static func withoutTrailingSpaces(_ text: Substring) -> Substring {
        var text = text
        while let last = text.last, last == " " || last == "\t" || last == "\u{00A0}" {
            text.removeLast()
        }
        return text
    }

    private static func changingFirstWord(of text: String, with change: (String) -> String) -> String {
        let end = text.firstIndex(where: \.isWhitespace) ?? text.endIndex
        return change(String(text[..<end])) + text[end...]
    }

    private static func startsWithName(_ text: String) -> Bool {
        guard let start = text.firstIndex(where: \.isLetter) else { return false }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        // A phrase of a few words is too short to tell its language, and
        // without it Russian names go unrecognised.
        let isRussian = text.unicodeScalars.contains { ("\u{0400}"..."\u{04FF}").contains($0) }
        tagger.setLanguage(isRussian ? .russian : .english, range: text.startIndex..<text.endIndex)
        let (tag, _) = tagger.tag(at: start, unit: .word, scheme: .nameType)
        return tag.map([NLTag.personalName, .placeName, .organizationName].contains) ?? false
    }
}
