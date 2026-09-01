import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

actor TranscriptCleanupService {
    struct Result: Sendable {
        let text: String
        let decision: String
    }

    private let localLLM = EmbeddedLocalLLMTranscriptCorrector()

    func prewarmLocalLLM() async throws {
        try await localLLM.prewarm()
    }

    func clean(_ transcript: String, mode: TranscriptCleanupMode) async -> Result {
        let baseline = TranscriptText.clean(transcript)

        switch mode {
        case .off:
            return Result(text: transcript, decision: "off")

        case .localRules:
            return Result(text: baseline, decision: "local-rules")

        case .localLLM:
            guard let corrected = try? await localLLM.correct(transcript: baseline) else {
                return Result(text: baseline, decision: "local-llm-unavailable fallback=local-rules")
            }

            let cleanedCorrection = TranscriptText.clean(corrected)
            guard Self.accepts(corrected: cleanedCorrection, original: baseline) else {
                return Result(text: baseline, decision: "local-llm-rejected fallback=local-rules")
            }

            return Result(text: cleanedCorrection, decision: "local-llm")
        }
    }

    nonisolated private static func accepts(corrected: String, original: String) -> Bool {
        let original = TranscriptText.clean(original)
        let corrected = TranscriptText.clean(corrected)

        guard !corrected.isEmpty else { return false }

        let lowerBound = max(4, Int(Double(original.count) * 0.45))
        let upperBound = max(24, Int(Double(original.count) * 1.8))
        guard corrected.count >= lowerBound && corrected.count <= upperBound else {
            return false
        }

        guard protectedNumbers(in: original).isSubset(of: protectedNumbers(in: corrected)) else {
            return false
        }

        guard !replacesSpokenNumbersWithDigits(original: original, corrected: corrected) else {
            return false
        }

        guard !looksTruncated(corrected: corrected, original: original) else {
            return false
        }

        return contentWordSimilarity(between: original, and: corrected) >= 0.90
    }

    nonisolated private static func protectedNumbers(in text: String) -> Set<String> {
        let tokens = text.split(separator: " ").map(String.init)
        return Set(tokens.compactMap { token in
            let scalars = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).unicodeScalars
            let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }
            guard digits.count >= 4 else { return nil }
            return String(String.UnicodeScalarView(digits))
        })
    }

    nonisolated private static func replacesSpokenNumbersWithDigits(original: String, corrected: String) -> Bool {
        let originalWords = Set(contentWords(in: original))
        guard !originalWords.isDisjoint(with: russianNumberWords) else {
            return false
        }

        let correctedWords = Set(contentWords(in: corrected))
        let removedNumberWords = originalWords.intersection(russianNumberWords).subtracting(correctedWords)
        guard !removedNumberWords.isEmpty else {
            return false
        }

        return corrected.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }

    nonisolated private static func contentWordSimilarity(between original: String, and corrected: String) -> Double {
        let originalWords = contentWords(in: original)
        let correctedWords = contentWords(in: corrected)

        guard !originalWords.isEmpty else { return 1 }
        guard !correctedWords.isEmpty else { return 0 }

        var remainingCorrectedWords = correctedWords
        var matchedWords = 0

        for originalWord in originalWords {
            guard let matchIndex = remainingCorrectedWords.firstIndex(of: originalWord) else {
                continue
            }

            matchedWords += 1
            remainingCorrectedWords.remove(at: matchIndex)
        }

        let recall = Double(matchedWords) / Double(originalWords.count)
        let precision = Double(matchedWords) / Double(correctedWords.count)
        guard recall + precision > 0 else { return 0 }
        return 2 * recall * precision / (recall + precision)
    }

    nonisolated private static func contentWords(in text: String) -> [String] {
        text.split(separator: " ").compactMap { token in
            let normalized = token
                .lowercased()
                .replacingOccurrences(of: "ё", with: "е")
                .trimmingCharacters(in: .punctuationCharacters.union(.symbols))

            guard normalized.count >= 4 else { return nil }
            guard normalized.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
            return normalized
        }
    }

    nonisolated private static let russianNumberWords: Set<String> = [
        "ноль", "один", "одна", "одно", "первый", "первая", "первое",
        "два", "две", "второй", "вторая", "второе",
        "три", "третий", "третья", "третье",
        "четыре", "четвертый", "четвертая", "четвертое",
        "пять", "пятый", "пятая", "пятое",
        "шесть", "шестой", "шестая", "шестое",
        "семь", "седьмой", "седьмая", "седьмое",
        "восемь", "восьмой", "восьмая", "восьмое",
        "девять", "девятый", "девятая", "девятое",
        "десять", "десятый", "десятая", "десятое"
    ]

    nonisolated private static func looksTruncated(corrected: String, original: String) -> Bool {
        let originalWords = contentWords(in: original)
        let correctedWords = contentWords(in: corrected)
        guard let originalLast = originalWords.last, let correctedLast = correctedWords.last else {
            return false
        }

        return originalLast.hasPrefix(correctedLast) && originalLast != correctedLast
    }

}

private actor EmbeddedLocalLLMTranscriptCorrector {
    enum CorrectionError: Error {
        case emptyResponse
    }

    private var session: ChatSession?

    func prewarm() async throws {
        _ = try await session()
    }

    func correct(transcript: String) async throws -> String {
        let session = try await session()
        session.generateParameters.maxTokens = Self.maximumResponseTokens(for: transcript)
        let response = try await session.respond(to: prompt(for: transcript))
        let corrected = Self.cleanedModelResponse(response)

        guard !corrected.isEmpty else {
            throw CorrectionError.emptyResponse
        }

        return corrected
    }

    private func session() async throws -> ChatSession {
        if let session {
            return session
        }

        let container = try await #huggingFaceLoadModelContainer(
            configuration: LLMRegistry.qwen2_5_1_5b
        )
        let session = ChatSession(
            container,
            generateParameters: GenerateParameters(
                maxTokens: 160,
                temperature: 0,
                topP: 1,
                topK: 1,
                repetitionPenalty: 1,
                repetitionContextSize: 64
            )
        )
        self.session = session
        return session
    }

    private nonisolated func prompt(for transcript: String) -> String {
        """
        Ты минимально исправляешь текст после распознавания речи.
        Главная задача: сохранить слова пользователя, порядок слов и смысл.
        Разрешено только:
        - убрать явные повторы и мусорные вставки;
        - исправить очевидные ошибки распознавания;
        - добавить пробелы и пунктуацию.

        Запрещено:
        - менять форму слов, если исходная форма грамматически возможна;
        - заменять слова синонимами;
        - удалять или менять номера задач, даты, имена, ссылки и технические идентификаторы;
        - переводить текст в другой стиль.

        Верни только исправленный текст без комментариев.

        Текст:
        \(transcript)
        """
    }

    private nonisolated static func maximumResponseTokens(for transcript: String) -> Int {
        min(160, max(64, transcript.count / 2))
    }

    private nonisolated static func cleanedModelResponse(_ response: String) -> String {
        response
            .replacing(
                /^```(?:text)?\s*/.anchorsMatchLineEndings(),
                with: ""
            )
            .replacing(
                /\s*```$/.anchorsMatchLineEndings(),
                with: ""
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
