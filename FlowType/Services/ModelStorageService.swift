import Foundation
import WhisperKit

final class ModelStorageService {
    private let fileManager = FileManager.default

    func isDownloaded(_ model: TranscriptionModel) -> Bool {
        fileManager.fileExists(atPath: localDirectory(for: model).path)
    }

    func download(_ model: TranscriptionModel) async throws {
        _ = try await WhisperKit.download(
            variant: model.whisperKitIdentifier,
            from: TranscriptionModel.repository
        )
    }

    func delete(_ model: TranscriptionModel) throws {
        let directory = localDirectory(for: model)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        try fileManager.removeItem(at: directory)
    }

    func localDirectory(for model: TranscriptionModel) -> URL {
        defaultDownloadBase
            .appending(path: "models")
            .appending(path: "argmaxinc")
            .appending(path: "whisperkit-coreml")
            .appending(path: model.whisperKitIdentifier)
    }

    private var defaultDownloadBase: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "huggingface")
    }
}
