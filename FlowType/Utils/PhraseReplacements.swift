import Foundation

/// Writes spoken phrases the way the user wants them: the dictionary
/// ("флоу тайп" → "Flow Type") and snippets said inside a phrase.
///
/// Matches whole words, ignoring case and "ё", and keeps the punctuation
/// around the phrase: "Флоу тайп," → "Flow Type,". Words split by a mark
/// belong to different phrases and aren't matched: "флоу. Тайп".
nonisolated enum PhraseReplacements {
    static func applying(_ replacements: [(heard: String, written: String)], to text: String) -> String {
        let phrases = replacements
            .map { (words: comparableWords(in: $0.heard), written: $0.written) }
            .filter { !$0.words.isEmpty && !$0.written.isEmpty }
            // Longer phrases first, so "флоу тайп" wins over a lone "флоу".
            .sorted { $0.words.count > $1.words.count }
        guard !phrases.isEmpty else { return text }

        let tokens = text.split(separator: " ").map(String.init)
        let cores = tokens.map(TranscriptText.comparableWord)
        var output: [String] = []
        var index = 0

        while index < tokens.count {
            let match = phrases.first { phrase in
                let end = index + phrase.words.count
                return end <= tokens.count
                    && cores[index..<end].elementsEqual(phrase.words)
                    && tokens[index..<end - 1].allSatisfy { $0.last?.isPunctuation != true }
            }
            guard let match else {
                output.append(tokens[index])
                index += 1
                continue
            }

            let end = index + match.words.count
            let leading = tokens[index].prefix { !$0.isLetter && !$0.isNumber }
            let trailing = String(tokens[end - 1].reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
            // A capital the recogniser gave the phrase for starting a
            // sentence carries over to words, not to an address or a link.
            let startsWithCapital = tokens[index].first(where: \.isLetter)?.isUppercase ?? false
            let isWords = match.written.allSatisfy { $0.isLetter || $0 == " " || $0 == "-" || $0 == "'" }
            let written = startsWithCapital && isWords ? TranscriptText.capitalizingFirstLetter(match.written) : match.written
            output.append(leading + written + trailing)
            index = end
        }
        return output.joined(separator: " ")
    }

    /// Whether `text` is nothing but `phrase`, give or take the punctuation
    /// and capitals the recogniser added: "Моя почта." is "моя почта".
    static func isWhole(_ text: String, phrase: String) -> Bool {
        let words = comparableWords(in: phrase)
        return !words.isEmpty && comparableWords(in: text) == words
    }

    private static func comparableWords(in text: String) -> [String] {
        TranscriptText.words(in: text).map(TranscriptText.comparableWord).filter { !$0.isEmpty }
    }
}
