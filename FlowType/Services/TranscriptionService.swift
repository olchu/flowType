import Foundation
import WhisperKit

actor TranscriptionService {
    enum TranscriptionError: LocalizedError {
        case emptyRecording
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .emptyRecording:
                "No audio was captured."
            case .emptyTranscript:
                "WhisperKit did not return any text."
            }
        }
    }

    private var pipeline: WhisperKit?
    private var loadedModel: TranscriptionModel?

    func prewarm(model: TranscriptionModel, onProgress: (@Sendable (Double, String) -> Void)? = nil) async throws {
        _ = try await pipeline(for: model, shouldPrewarm: true, onProgress: onProgress)
    }

    func transcribe(
        _ audio: RecordedAudio,
        language: TranscriptionLanguage,
        model: TranscriptionModel
    ) async throws -> String {
        guard !audio.isEmpty else {
            throw TranscriptionError.emptyRecording
        }

        let pipeline = try await pipeline(for: model, shouldPrewarm: false)
        let options = DecodingOptions(
            language: language.whisperKitCode,
            detectLanguage: language == .auto,
            concurrentWorkerCount: Self.transcriptionWorkerCount
        )
        let samples = audio.samples(resampledTo: Double(WhisperKit.sampleRate))
        let results = try await pipeline.transcribe(
            audioArray: samples,
            decodeOptions: options
        )

        let transcript = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty else {
            throw TranscriptionError.emptyTranscript
        }

        return transcript
    }

    private func pipeline(
        for model: TranscriptionModel,
        shouldPrewarm: Bool,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> WhisperKit {
        if let pipeline, loadedModel == model {
            return pipeline
        }

        if let onProgress {
            let tracker = LoadingStageTracker()
            Logging.shared.loggingCallback = { message in
                if let (progress, label) = tracker.process(message: message) {
                    onProgress(progress, label)
                }
            }
        }

        defer {
            if onProgress != nil {
                Logging.shared.logLevel = .error
                Logging.shared.loggingCallback = nil
            }
        }

        let config = WhisperKitConfig(
            model: model.whisperKitIdentifier,
            modelRepo: TranscriptionModel.repository,
            verbose: onProgress != nil,
            logLevel: .debug,
            prewarm: shouldPrewarm,
            load: true,
            download: true
        )
        let pipeline = try await WhisperKit(config)

        self.pipeline = pipeline
        loadedModel = model
        return pipeline
    }

    private static var transcriptionWorkerCount: Int? {
        #if (os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64)
        1
        #else
        nil
        #endif
    }

    func resetLoadedModel(ifMatching model: TranscriptionModel) {
        guard loadedModel == model else { return }
        pipeline = nil
        loadedModel = nil
    }
}

// Sequentially matches WhisperKit loading log messages to progress values.
// Thread-safe: can be called from any thread.
private final class LoadingStageTracker: @unchecked Sendable {
    private struct Stage {
        let keyword: String
        let progress: Double
        let label: String
    }

    // Two-pass loading: prewarm (specialization) then full load.
    // Stage ordering must match WhisperKit's log emission order exactly.
    private let stages: [Stage] = [
        Stage(keyword: "Prewarming models",        progress: 0.05, label: "Specializing for device..."),
        Stage(keyword: "Loading feature extractor", progress: 0.10, label: "Loading feature extractor..."),
        Stage(keyword: "Loaded feature extractor",  progress: 0.22, label: "Feature extractor specialized"),
        Stage(keyword: "Loading text decoder",      progress: 0.24, label: "Loading text decoder..."),
        Stage(keyword: "Loaded text decoder",       progress: 0.38, label: "Text decoder specialized"),
        Stage(keyword: "Loading audio encoder",     progress: 0.40, label: "Loading audio encoder..."),
        Stage(keyword: "Loaded audio encoder",      progress: 0.48, label: "Audio encoder specialized"),
        Stage(keyword: "Loading models",            progress: 0.50, label: "Loading full model..."),
        Stage(keyword: "Loading feature extractor", progress: 0.55, label: "Loading feature extractor..."),
        Stage(keyword: "Loaded feature extractor",  progress: 0.67, label: "Feature extractor loaded"),
        Stage(keyword: "Loading text decoder",      progress: 0.69, label: "Loading text decoder..."),
        Stage(keyword: "Loaded text decoder",       progress: 0.80, label: "Text decoder loaded"),
        Stage(keyword: "Loading audio encoder",     progress: 0.82, label: "Loading audio encoder..."),
        Stage(keyword: "Loaded audio encoder",      progress: 0.93, label: "Audio encoder loaded"),
        Stage(keyword: "Loaded models for whisper", progress: 1.00, label: "Model ready"),
    ]

    nonisolated(unsafe) private var currentIndex = 0
    private let lock = NSLock()

    nonisolated init() {}

    nonisolated func process(message: String) -> (Double, String)? {
        lock.lock()
        defer { lock.unlock() }

        guard currentIndex < stages.count else { return nil }
        let stage = stages[currentIndex]
        guard message.contains(stage.keyword) else { return nil }
        currentIndex += 1
        return (stage.progress, stage.label)
    }
}
