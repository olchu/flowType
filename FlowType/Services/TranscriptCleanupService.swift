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

    func prewarmLocalLLM(model: CleanupLLMModel) async throws {
        try await localLLM.prewarm(model: model)
    }

    /// `rules` apply in every mode, to the final text: after the model, so
    /// the model reads the words as spoken and can't undo a rule.
    func clean(
        _ transcript: String,
        mode: TranscriptCleanupMode,
        model: CleanupLLMModel,
        external: ExternalLLMConfiguration,
        rules: TextRules
    ) async -> Result {
        let baseline = TranscriptText.clean(transcript)
        let dictionary = rules.wordReplacements.map { (heard: $0.heard, written: $0.written) }

        let result = switch mode {
        case .off:
            Result(text: transcript, decision: "off")
        case .localRules:
            Result(text: baseline, decision: "local-rules")
        case .localLLM:
            await correction(of: baseline, by: "local-llm", tolerance: .local, dictionary: dictionary) {
                try await localLLM.correct(transcript: $0, model: model)
            }
        case .externalLLM:
            await correction(of: baseline, by: "external-llm", tolerance: .external, dictionary: dictionary) {
                try await Self.externalCorrection(of: $0, configuration: external)
            }
        }
        return Result(text: rules.apply(to: result.text), decision: result.decision)
    }

    /// The external model's answer to a short dictation, and how long it
    /// took, to check the connection from the settings.
    nonisolated static func testExternalLLM(_ configuration: ExternalLLMConfiguration) async throws -> (text: String, duration: Duration) {
        let start = ContinuousClock.now
        let text = try await externalCorrection(of: "ну давай созвонимся завтра в среду нет в четверг", configuration: configuration)
        return (text, start.duration(to: .now))
    }

    /// The model's edit of `baseline`, or `baseline` itself when the
    /// dictation is too short for the model, the model fails or its edit is
    /// rejected.
    private func correction(
        of baseline: String,
        by model: String,
        tolerance: RejectionTolerance,
        dictionary: [(heard: String, written: String)],
        correct: (String) async throws -> String
    ) async -> Result {
        guard Self.contentWords(in: baseline).count >= Self.minimumWordsForLLM else {
            return Result(text: baseline, decision: "\(model)-skipped reason=short fallback=local-rules")
        }

        let corrected: String
        do {
            corrected = TranscriptText.clean(try await correct(baseline))
        } catch {
            return Result(text: baseline, decision: "\(model)-unavailable error=\(error) fallback=local-rules")
        }

        // Compared with the dictionary applied to both: a model that already
        // wrote a dictionary word as it's spelled hasn't made it up.
        if let rejection = Self.rejectionReason(
            corrected: PhraseReplacements.applying(dictionary, to: corrected),
            original: PhraseReplacements.applying(dictionary, to: baseline),
            tolerance: tolerance
        ) {
            return Result(text: baseline, decision: "\(model)-rejected reason=\(rejection) fallback=local-rules")
        }

        return Result(text: corrected, decision: model)
    }

    nonisolated private static func externalCorrection(
        of transcript: String, configuration: ExternalLLMConfiguration
    ) async throws -> String {
        let examples = CleanupPrompt.externalExamples.flatMap { example in
            [
                ExternalLLMClient.Message(role: .user, content: CleanupPrompt.wrapped(example.transcript)),
                ExternalLLMClient.Message(role: .assistant, content: example.corrected),
            ]
        }
        let response = try await ExternalLLMClient.complete(
            system: CleanupPrompt.externalInstructions(
                vocabulary: configuration.vocabulary, instructions: configuration.settings.instructions
            ),
            messages: examples + [ExternalLLMClient.Message(role: .user, content: CleanupPrompt.wrapped(transcript))],
            maxTokens: CleanupPrompt.maximumResponseTokens(for: transcript),
            configuration: configuration
        )
        let corrected = CleanupPrompt.cleanedResponse(response)
        guard !corrected.isEmpty else { throw ExternalLLMClient.Failure.emptyResponse }
        return corrected
    }

    /// How far a model's edit may stray from the dictation. The external
    /// model also takes out false starts and self-corrections, which drops
    /// whole phrases.
    nonisolated private struct RejectionTolerance {
        /// The shortest edit, as a share of the dictation's length.
        var shortestLength: Double
        /// Words per one the model may make up.
        var wordsPerInvented: Int
        var leastInvented: Int
        /// Words per one the model may drop.
        var wordsPerDropped: Int
        var leastDropped: Int
        /// Whether a number of four or more digits may go.
        var mayDropNumbers: Bool

        static let local = RejectionTolerance(
            shortestLength: 0.5, wordsPerInvented: 12, leastInvented: 1, wordsPerDropped: 8, leastDropped: 1,
            mayDropNumbers: false
        )

        static let external = RejectionTolerance(
            shortestLength: 0.3, wordsPerInvented: 8, leastInvented: 2, wordsPerDropped: 3, leastDropped: 2,
            mayDropNumbers: true
        )
    }

    // A couple of words gain nothing from the model but still pay its latency.
    nonisolated private static let minimumWordsForLLM = 3

    /// The model may only touch punctuation, fix a misheard word or drop a
    /// repeat. Anything that adds, drops or reorders content is treated as a
    /// hallucination and the rule-based text is used instead.
    nonisolated private static func rejectionReason(
        corrected: String, original: String, tolerance: RejectionTolerance
    ) -> String? {
        guard !corrected.isEmpty else { return "empty" }

        let lowerBound = Int(Double(original.count) * tolerance.shortestLength)
        let upperBound = max(24, Int(Double(original.count) * 1.25))
        guard corrected.count >= lowerBound && corrected.count <= upperBound else {
            return "length"
        }

        // A self-correction drops a number on purpose ("за 2024, нет, за
        // 2025"), so the external model may drop numbers but not make up one.
        let originalNumbers = protectedNumbers(in: original), correctedNumbers = protectedNumbers(in: corrected)
        guard tolerance.mayDropNumbers
            ? correctedNumbers.isSubset(of: originalNumbers)
            : originalNumbers.isSubset(of: correctedNumbers) else {
            return "numbers"
        }

        let originalWords = contentWords(in: original)
        let correctedWords = contentWords(in: corrected)

        guard !replacesSpokenNumbersWithDigits(
            originalWords: originalWords,
            correctedWords: correctedWords,
            corrected: corrected
        ) else {
            return "spoken-numbers"
        }

        guard !looksTruncated(originalWords: originalWords, correctedWords: correctedWords) else {
            return "truncated"
        }

        guard !originalWords.isEmpty else { return nil }
        guard !correctedWords.isEmpty else { return "no-content" }

        // Words the model made up. A few cover fixing misheard words.
        let inventedWords = correctedWords.filter { word in
            !originalWords.contains { TranscriptText.wordsMatch($0, word) }
        }
        guard inventedWords.count <= max(tolerance.leastInvented, originalWords.count / tolerance.wordsPerInvented) else {
            return "invented=\(inventedWords.count)"
        }

        // Words the model removed. A word that is still present elsewhere was a
        // repeat, which is exactly what the model should remove.
        let droppedWords = originalWords.filter { word in
            !correctedWords.contains { TranscriptText.wordsMatch($0, word) }
        }
        guard droppedWords.count <= max(tolerance.leastDropped, originalWords.count / tolerance.wordsPerDropped) else {
            return "dropped=\(droppedWords.count)"
        }

        let orderedMatches = TranscriptText.orderedMatchCount(originalWords, correctedWords)
        guard Double(orderedMatches) >= Double(correctedWords.count) * 0.85 else {
            return "reordered"
        }

        return nil
    }

    nonisolated private static func protectedNumbers(in text: String) -> Set<String> {
        Set(TranscriptText.words(in: text).compactMap { token in
            let scalars = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).unicodeScalars
            let digits = scalars.filter { CharacterSet.decimalDigits.contains($0) }
            guard digits.count >= 4 else { return nil }
            return String(String.UnicodeScalarView(digits))
        })
    }

    nonisolated private static func replacesSpokenNumbersWithDigits(
        originalWords: [String],
        correctedWords: [String],
        corrected: String
    ) -> Bool {
        let originalNumberWords = russianNumberWords.intersection(originalWords)
        guard !originalNumberWords.isEmpty else {
            return false
        }

        let removedNumberWords = originalNumberWords.subtracting(correctedWords)
        guard !removedNumberWords.isEmpty else {
            return false
        }

        return corrected.unicodeScalars.contains { CharacterSet.decimalDigits.contains($0) }
    }

    /// Comparable forms of the words that carry content.
    nonisolated private static func contentWords(in text: String) -> [String] {
        TranscriptText.words(in: text).map(TranscriptText.comparableWord).filter { word in
            word.count >= 3 && word.unicodeScalars.contains { CharacterSet.letters.contains($0) }
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

    nonisolated private static func looksTruncated(originalWords: [String], correctedWords: [String]) -> Bool {
        guard let originalLast = originalWords.last, let correctedLast = correctedWords.last else {
            return false
        }

        return originalLast.hasPrefix(correctedLast) && originalLast != correctedLast
    }

}

private extension CleanupLLMModel {
    var configuration: ModelConfiguration {
        switch self {
        case .qwen25_1_5B: LLMRegistry.qwen2_5_1_5b
        case .qwen35_2B: LLMRegistry.qwen3_5_2b_4bit
        case .qwen3_4B: LLMRegistry.qwen3_4b_4bit
        case .gemma4E2B: LLMRegistry.gemma4_e2b_it_4bit
        }
    }
}

private actor EmbeddedLocalLLMTranscriptCorrector {
    enum CorrectionError: Error {
        case modelLoading
        case emptyResponse
    }

    private var loadedModel: CleanupLLMModel?
    private var container: ModelContainer?
    private var loadTask: (model: CleanupLLMModel, task: Task<ModelContainer, Error>)?

    func prewarm(model: CleanupLLMModel) async throws {
        _ = try await loadedContainer(for: model)
    }

    func correct(transcript: String, model: CleanupLLMModel) async throws -> String {
        // Never hold a dictation hostage to a model download or load; the
        // rule-based text is pasted and the model is ready next time.
        guard let container, loadedModel == model else {
            Task { _ = try? await loadedContainer(for: model) }
            throw CorrectionError.modelLoading
        }

        let response = try await Self.respond(
            to: transcript,
            with: container,
            maxTokens: CleanupPrompt.maximumResponseTokens(for: transcript)
        )
        let corrected = CleanupPrompt.cleanedResponse(response)

        guard !corrected.isEmpty else {
            throw CorrectionError.emptyResponse
        }

        return corrected
    }

    private func loadedContainer(for model: CleanupLLMModel) async throws -> ModelContainer {
        if let container, loadedModel == model {
            return container
        }
        if let loadTask, loadTask.model == model {
            return try await loadTask.task.value
        }

        // Switching models: release the old weights before loading new ones.
        container = nil
        loadedModel = nil

        let task = Task { try await Self.loadContainer(model.configuration) }
        loadTask = (model, task)
        do {
            let loaded = try await task.value
            // The first generation compiles the Metal kernels, which took
            // ~4 s on the first dictation after launch. Pay it here, before
            // the model is marked ready, so no dictation waits for it.
            _ = try? await Self.respond(to: "проверка связи", with: loaded, maxTokens: 4)
            // A newer selection may have replaced this load meanwhile.
            guard loadTask?.model == model else { return loaded }
            container = loaded
            loadedModel = model
            loadTask = nil
            return loaded
        } catch {
            if loadTask?.model == model {
                loadTask = nil
            }
            throw error
        }
    }

    private static func respond(
        to transcript: String,
        with container: ModelContainer,
        maxTokens: Int
    ) async throws -> String {
        // A fresh session per call. ChatSession keeps the whole conversation,
        // so reusing one fed every earlier dictation back to the model: old
        // text leaked into new corrections and each call got slower.
        let session = ChatSession(
            container,
            instructions: CleanupPrompt.localInstructions,
            history: examples,
            generateParameters: GenerateParameters(
                maxTokens: maxTokens,
                temperature: 0,
                topP: 1,
                topK: 1,
                repetitionPenalty: 1,
                repetitionContextSize: 64
            ),
            // Qwen3 and Gemma 4 would otherwise spend the token budget on a
            // hidden reasoning block before the answer.
            additionalContext: ["enable_thinking": false]
        )
        return try await session.respond(to: CleanupPrompt.wrapped(transcript))
    }

    private static func loadContainer(_ configuration: ModelConfiguration) async throws -> ModelContainer {
        try await #huggingFaceLoadModelContainer(configuration: configuration)
    }

    private nonisolated static var examples: [Chat.Message] {
        CleanupPrompt.examples.flatMap { [.user(CleanupPrompt.wrapped($0.transcript)), .assistant($0.corrected)] }
    }
}
