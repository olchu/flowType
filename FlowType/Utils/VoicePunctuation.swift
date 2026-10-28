import Foundation

/// Writes spoken punctuation as marks: "Привет, запятая, как дела,
/// вопросительный знак." → "Привет, как дела?", "открыть кавычки привет
/// закрыть кавычки" → "«привет»", and "новая строка" or "new line" breaks
/// the line.
///
/// Commands whose words are also everyday speech, "точка", "знак вопроса",
/// count only where a phrase ends: followed by the punctuation the
/// recogniser put in for the pause, by another command or by the end of the
/// text. Inside a phrase their words are text: "точка зрения", "новая
/// строка кода", "большой знак вопроса для нас". At the start of the text
/// they count only on their own, so a dictation of just "знак вопроса"
/// ends the sentence before it. Names that mean nothing but a mark,
/// "тире", "открыть скобку", count anywhere. The spoken mark
/// takes the place of the recogniser's own mark before it, and the next
/// word's capital follows the spoken mark.
nonisolated enum VoicePunctuation {
    private enum Mark {
        /// Written straight after the word before: ".", ",", "?", "…".
        case attached(String)
        /// After the word before, keeping the recogniser's mark after the
        /// command, which ends the sentence more often than not: "»", ")".
        case closing(String)
        /// Written straight before the word after: "«", "(".
        case opening(String)
        /// A dash set apart by spaces: "Москва — столица".
        case dash
        /// A line break or an empty line between paragraphs.
        case lineBreak(String)

        /// The recogniser's marks before the command that this one takes
        /// the place of. Its comma for the pause goes before a quote, a
        /// bracket or a line break, but its full stop or colon stays.
        var replacedMarks: Set<Character> {
            switch self {
            case .attached, .closing, .dash: [".", ",", "!", "?", ":", ";", "…"]
            case .opening, .lineBreak: [","]
            }
        }

        /// Spoken marks stack, "?!", rather than take each other's place.
        var isSpokenPunctuation: Bool {
            switch self {
            case .attached, .dash: true
            case .closing, .opening, .lineBreak: false
            }
        }
    }

    private struct Command {
        /// Each word with the forms it can take: "открыть" or "открой".
        let words: [Set<String>]
        let mark: Mark
        /// Whether the command needs a phrase to end after it.
        var needsPause = false
    }

    /// A command that starts like a longer one comes after it: "точка с
    /// запятой" before "точка".
    private static let commands: [Command] = [
        Command(words: [["точка"], ["с"], ["запятой"]], mark: .attached(";")),
        Command(words: [["точка"]], mark: .attached("."), needsPause: true),
        Command(words: [["запятая"]], mark: .attached(","), needsPause: true),
        Command(words: [["вопросительный"], ["знак"]], mark: .attached("?"), needsPause: true),
        Command(words: [["знак"], ["вопроса"]], mark: .attached("?"), needsPause: true),
        Command(words: [["восклицательный"], ["знак"]], mark: .attached("!"), needsPause: true),
        Command(words: [["знак"], ["восклицания"]], mark: .attached("!"), needsPause: true),
        Command(words: [["двоеточие"]], mark: .attached(":")),
        Command(words: [["многоточие"]], mark: .attached("…")),
        Command(words: [["тире"]], mark: .dash),
        Command(words: [["открыть", "открой"], ["кавычки"]], mark: .opening("«")),
        Command(words: [["закрыть", "закрой"], ["кавычки"]], mark: .closing("»")),
        Command(words: [["открыть", "открой"], ["скобку", "скобки"]], mark: .opening("(")),
        Command(words: [["закрыть", "закрой"], ["скобку", "скобки"]], mark: .closing(")")),
        Command(words: [["новая"], ["строка"]], mark: .lineBreak("\n"), needsPause: true),
        Command(words: [["новый"], ["абзац"]], mark: .lineBreak("\n\n"), needsPause: true),
        Command(words: [["period"]], mark: .attached("."), needsPause: true),
        Command(words: [["full"], ["stop"]], mark: .attached("."), needsPause: true),
        Command(words: [["comma"]], mark: .attached(","), needsPause: true),
        Command(words: [["semicolon"]], mark: .attached(";")),
        Command(words: [["question"], ["mark"]], mark: .attached("?"), needsPause: true),
        Command(words: [["exclamation"], ["mark", "point"]], mark: .attached("!"), needsPause: true),
        Command(words: [["colon"]], mark: .attached(":"), needsPause: true),
        Command(words: [["ellipsis"]], mark: .attached("…")),
        Command(words: [["dot"], ["dot"], ["dot"]], mark: .attached("…")),
        Command(words: [["dash"]], mark: .dash, needsPause: true),
        Command(words: [["open"], ["quote", "quotes"]], mark: .opening("\u{201C}")),
        Command(words: [["close", "end"], ["quote", "quotes"]], mark: .closing("\u{201D}")),
        Command(words: [["unquote"]], mark: .closing("\u{201D}")),
        Command(words: [["open"], ["bracket", "paren", "parenthesis"]], mark: .opening("(")),
        Command(words: [["close"], ["bracket", "paren", "parenthesis"]], mark: .closing(")")),
        Command(words: [["new"], ["line"]], mark: .lineBreak("\n"), needsPause: true),
        Command(words: [["new"], ["paragraph"]], mark: .lineBreak("\n\n"), needsPause: true),
    ]

    static func applying(to text: String) -> String {
        let tokens = text.split(separator: " ").map(String.init)
        let commandsAt = commandPositions(in: tokens)
        guard commandsAt.contains(where: { $0 != nil }) else { return text }

        var output = ""
        var nextWordCase: LetterCase?
        /// The mark last written, nil after a word.
        var previous: Mark?
        var index = 0

        func addSpace() {
            if case .opening = previous { return }
            if !output.isEmpty && !output.hasSuffix("\n") {
                output += " "
            }
        }

        while index < tokens.count {
            guard let (end, mark) = commandsAt[index] else {
                addSpace()
                output += nextWordCase.map { $0.applied(to: tokens[index]) } ?? tokens[index]
                nextWordCase = nil
                previous = nil
                index += 1
                continue
            }

            if previous?.isSpokenPunctuation != true {
                while let last = output.last, mark.replacedMarks.contains(last) {
                    output.removeLast()
                }
            }
            // The recogniser ended a sentence at the command and capitalised
            // the word after it; a comma or a dash doesn't.
            let continuesSentence: LetterCase? = tokens[end - 1].contains(where: TranscriptText.sentenceEnds.contains) ? .lowercased : nil

            switch mark {
            case .attached(let text):
                output += text
                nextWordCase = switch text {
                case ".", "?", "!": .capitalized
                case "…": nil
                default: continuesSentence
                }
            case .closing(let text):
                output += text + String(tokens[end - 1].reversed().prefix(while: mark.replacedMarks.contains).reversed())
                nextWordCase = nil
            case .opening(let text):
                addSpace()
                output += text
                // The recogniser's capital for a new sentence went to the
                // command; the word after it takes it.
                nextWordCase = tokens[index].first?.isUppercase == true ? .capitalized : nil
            case .dash:
                addSpace()
                output += "—"
                nextWordCase = continuesSentence
            case .lineBreak(let text):
                output += text
                nextWordCase = .capitalized
            }
            previous = mark
            index = end
        }
        return output
    }

    /// For each token, the command that starts there, with the index after
    /// it.
    private static func commandPositions(in tokens: [String]) -> [(end: Int, mark: Mark)?] {
        let cores = tokens.map(TranscriptText.comparableWord)
        var found = [(end: Int, mark: Mark)?](repeating: nil, count: tokens.count + 1)

        // From the end, so a command followed by another knows whether that
        // one counts.
        for start in tokens.indices.reversed() {
            let command = commands.first { command in
                let end = start + command.words.count
                return end <= tokens.count
                    && zip(cores[start..<end], command.words).allSatisfy { $1.contains($0) }
                    // A mark inside means the words belong to different
                    // phrases: "новая. Строка".
                    && tokens[start..<end - 1].allSatisfy { !endsWithPunctuation($0) }
            }
            guard let command else { continue }
            let end = start + command.words.count
            // "Точка, в которой мы находимся" starts with a word, not a mark.
            let endsPhrase = end == tokens.count || found[end] != nil || (start > 0 && endsWithPunctuation(tokens[end - 1]))
            if !command.needsPause || endsPhrase {
                found[start] = (end, command.mark)
            }
        }
        return found
    }

    private static func endsWithPunctuation(_ token: String) -> Bool {
        token.last?.isPunctuation ?? false
    }

    private enum LetterCase {
        case capitalized
        case lowercased

        func applied(to word: String) -> String {
            switch self {
            case .capitalized: TranscriptText.capitalizingFirstLetter(word)
            case .lowercased: TranscriptText.lowercasingFirstLetter(word)
            }
        }
    }
}
