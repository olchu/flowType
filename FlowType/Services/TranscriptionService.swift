import Foundation
import WhisperKit

@MainActor
final class TranscriptionService {
    enum TranscriptionError: LocalizedError {
        case emptyRecording
        case missingAudioFile
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .emptyRecording:
                "No audio was captured."
            case .missingAudioFile:
                "Recorded audio could not be prepared for transcription."
            case .emptyTranscript:
                "WhisperKit did not return any text."
            }
        }
    }

    private var pipeline: WhisperKit?
    private var loadedModel: TranscriptionModel?

    func transcribe(
        _ audio: RecordedAudio,
        language: TranscriptionLanguage,
        model: TranscriptionModel
    ) async throws -> String {
        defer { audio.removeTemporaryFile() }

        guard !audio.isEmpty else {
            throw TranscriptionError.emptyRecording
        }

        guard let audioURL = audio.temporaryFileURL else {
            throw TranscriptionError.missingAudioFile
        }

        let pipeline = try await pipeline(for: model)
        let options = DecodingOptions(
            language: language.whisperKitCode,
            detectLanguage: language == .auto
        )
        let results = try await pipeline.transcribe(
            audioPath: audioURL.path,
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

    private func pipeline(for model: TranscriptionModel) async throws -> WhisperKit {
        if let pipeline, loadedModel == model {
            return pipeline
        }

        let config = WhisperKitConfig(
            model: model.whisperKitIdentifier,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: true
        )
        let pipeline = try await WhisperKit(config)

        self.pipeline = pipeline
        loadedModel = model
        return pipeline
    }
}
