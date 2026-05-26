import Foundation
import WhisperKit

@MainActor
final class TranscriptionService {
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

    func prewarm(model: TranscriptionModel) async throws {
        _ = try await pipeline(for: model, shouldPrewarm: true)
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
            detectLanguage: language == .auto
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
        shouldPrewarm: Bool
    ) async throws -> WhisperKit {
        if let pipeline, loadedModel == model {
            return pipeline
        }

        let config = WhisperKitConfig(
            model: model.whisperKitIdentifier,
            modelRepo: TranscriptionModel.repository,
            verbose: false,
            logLevel: .error,
            prewarm: shouldPrewarm,
            load: true,
            download: true
        )
        let pipeline = try await WhisperKit(config)

        self.pipeline = pipeline
        loadedModel = model
        return pipeline
    }

    func resetLoadedModel(ifMatching model: TranscriptionModel) {
        guard loadedModel == model else { return }
        pipeline = nil
        loadedModel = nil
    }
}
