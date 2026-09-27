import Foundation
import WhisperKit

final class ModelStorageService {
    private let fileManager = FileManager.default

    func isDownloaded(_ model: TranscriptionModel) -> Bool {
        switch model.engine {
        case .whisperKit:
            localDirectory(for: model).map { fileManager.fileExists(atPath: $0.path) } ?? false
        case .parakeet:
            ParakeetTranscriber.isDownloaded
        }
    }

    func download(_ model: TranscriptionModel) async throws {
        switch model.engine {
        case .whisperKit:
            guard let identifier = model.whisperKitIdentifier else { return }
            _ = try await WhisperKit.download(
                variant: identifier,
                from: TranscriptionModel.repository
            )
        case .parakeet:
            try await ParakeetTranscriber.download()
        }
    }

    func delete(_ model: TranscriptionModel) throws {
        let directory = switch model.engine {
        case .whisperKit: localDirectory(for: model)
        case .parakeet: ParakeetTranscriber.cacheDirectory
        }
        guard let directory, fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    func localDirectory(for model: TranscriptionModel) -> URL? {
        guard let identifier = model.whisperKitIdentifier else { return nil }
        return defaultDownloadBase
            .appending(path: "models")
            .appending(path: "argmaxinc")
            .appending(path: "whisperkit-coreml")
            .appending(path: identifier)
    }

    private var defaultDownloadBase: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "huggingface")
    }
}
