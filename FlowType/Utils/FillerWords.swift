import Foundation

/// Removes filler words and hesitation sounds from a transcript.
///
/// A word from the list goes only where it stands apart: at the start of a
/// phrase or after a comma, and followed by a comma, the end of a sentence
/// or the end of the text ("Ну, давай" → "Давай", "Я, типа, не знаю" →
/// "Я не знаю"). Inside a phrase it carries meaning and stays ("что-то
/// типа этого", "сделай короче", "а потом"). Hesitation sounds ("э", "эм",
/// "ммм") never carry meaning and go wherever they are.
///
/// Relies on the punctuation the recognisers put in; the commas and the
/// capital letter around a removed word are mended.
nonisolated enum FillerWords {
    static let defaults = [
        "ну", "типа", "как бы", "короче", "в общем", "а",
        "like", "you know", "I mean", "basically", "kind of", "sort of",
    ]

    static func removing(_ fillers: [String], from text: String) -> String {
        let phrases = fillers
            .map { $0.split(separator: " ").map { TranscriptText.comparableWord(String($0)) }.filter { !$0.isEmpty } }
            .filter { !$0.isEmpty }
            // Longer phrases first, so "в общем" wins over a lone "в".
            .sorted { $0.count > $1.count }
        let longestPhrase = phrases.first?.count ?? 1

        var tokens = text.split(separator: " ").map { Token(String($0)) }
        var start = 0
        // Each pass removes one run; chains like "Ну, короче, типа," take a
        // pass per word. A removal changes only the word before the run, so
        // the next pass starts just far enough back to see a phrase across it.
        while let run = firstRemovableRun(in: tokens, from: start, phrases: phrases) {
            remove(run, from: &tokens)
            start = max(0, run.lowerBound - longestPhrase)
        }
        return tokens.map(\.text).joined(separator: " ")
    }

    private struct Token {
        let text: String
        /// The word without punctuation around it, for matching.
        let core: String
        /// Punctuation after the word: ",", ".", "?!" and so on.
        let trailing: String

        init(_ text: String) {
            self.text = text
            core = TranscriptText.comparableWord(text)
            trailing = String(text.reversed().prefix { $0.isPunctuation }.reversed())
        }

        var endsSentence: Bool {
            trailing.contains(where: FillerWords.sentenceEnds.contains)
        }

        var endsWithComma: Bool {
            trailing.hasSuffix(",")
        }
    }

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…"]

    private static func firstRemovableRun(in tokens: [Token], from first: Int, phrases: [[String]]) -> Range<Int>? {
        for start in tokens.indices.dropFirst(first) {
            if isHesitation(tokens[start].core) {
                return start..<start + 1
            }
            // Only a word set apart before it can be a filler.
            guard start == 0 || tokens[start - 1].endsSentence || tokens[start - 1].endsWithComma else { continue }

            for phrase in phrases {
                let end = start + phrase.count
                guard end <= tokens.count,
                      zip(tokens[start..<end], phrase).allSatisfy({ $0.core == $1 }),
                      // A comma inside the phrase means its words belong to
                      // different parts of the sentence.
                      tokens[start..<end - 1].allSatisfy({ $0.trailing.isEmpty })
                else {
                    continue
                }
                let last = tokens[end - 1]
                if last.endsWithComma || last.endsSentence || end == tokens.count {
                    return start..<end
                }
            }
        }
        return nil
    }

    private static func remove(_ run: Range<Int>, from tokens: inout [Token]) {
        let removedPunctuation = tokens[run.upperBound - 1].trailing
        let wasCapitalized = tokens[run.lowerBound].text.first?.isUppercase ?? false
        let previous = run.lowerBound > 0 ? run.lowerBound - 1 : nil
        let isPhraseStart = previous.map { tokens[$0].endsSentence } ?? true

        if let previous, !isPhraseStart {
            let terminal = removedPunctuation.filter(sentenceEnds.contains)
            if !terminal.isEmpty {
                // "знаю, короче." → "знаю."
                tokens[previous] = Token(withoutTrailingComma(tokens[previous].text) + terminal)
            } else if tokens[previous].endsWithComma
                        && (removedPunctuation.hasSuffix(",") || removedPunctuation.isEmpty)
                        && !introductoryWords.contains(tokens[previous].core) {
                // "Я, типа, не знаю" → "Я не знаю": both commas only set
                // the removed word apart. After "так" or "ладно" the comma
                // is theirs: "Так, ну, начнём" → "Так, начнём".
                tokens[previous] = Token(withoutTrailingComma(tokens[previous].text))
            }
        }

        tokens.removeSubrange(run)

        // "Ну, давай" → "Давай".
        if isPhraseStart && wasCapitalized && run.lowerBound < tokens.count {
            tokens[run.lowerBound] = Token(capitalizingFirstLetter(tokens[run.lowerBound].text))
        }
    }

    /// Words that take a comma of their own, so it stays when the filler
    /// after them goes.
    private static let introductoryWords: Set<String> = [
        "так", "итак", "ладно", "хорошо", "окей", "да", "нет", "слушай", "слушайте",
        "смотри", "смотрите", "кстати", "значит", "конечно", "наверное", "например",
        "привет", "спасибо", "so", "well", "okay", "ok", "yes", "no", "hey",
    ]

    /// "э", "эээ", "эм", "ммм", "хм", "ааа", and their English kin.
    /// "мм" is left alone: it is as often millimetres.
    private static let hesitation = /э+м*|м{3,}|х+м+|а{2,}|u+h+|u+m+|h+m+|e+r+m+/

    private static func isHesitation(_ word: String) -> Bool {
        word.wholeMatch(of: hesitation) != nil
    }

    private static func withoutTrailingComma(_ text: String) -> String {
        text.hasSuffix(",") ? String(text.dropLast()) : text
    }

    /// Leaves words with capitals of their own alone: "iPhone", "eBay".
    private static func capitalizingFirstLetter(_ text: String) -> String {
        guard let index = text.firstIndex(where: \.isLetter), !text.contains(where: \.isUppercase) else { return text }
        return text.replacingCharacters(in: index...index, with: text[index].uppercased())
    }
}
