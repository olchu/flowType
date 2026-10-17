import Foundation
import FluidAudio

/// NVIDIA Parakeet TDT (Ultra, 25 European languages) running on the Neural
/// Engine through FluidAudio. It decodes a whole dictation in a fraction of a
/// second and, unlike Whisper, does not invent text for silence, so it needs no
/// streaming preview or tail re-decoding.
///
/// Kept in its own file: FluidAudio and WhisperKit export clashing type names.
actor ParakeetTranscriber {
    private static let version: AsrModelVersion = .ultra

    private var manager: AsrManager?

    nonisolated static var cacheDirectory: URL {
        AsrModels.defaultCacheDirectory(for: version)
    }

    nonisolated static var isDownloaded: Bool {
        AsrModels.modelsExist(at: cacheDirectory, version: version)
    }

    nonisolated static func download() async throws {
        _ = try await AsrModels.download(version: version)
    }

    func prewarm() async throws {
        _ = try await loadedManager()
    }

    func unload() async {
        await manager?.cleanup()
        manager = nil
    }

    /// - Parameters:
    ///   - samples: 16 kHz mono audio.
    ///   - languageCode: ISO code used to filter out tokens of the wrong
    ///     script, or `nil` to let the model pick.
    func transcribe(_ samples: [Float], languageCode: String?) async throws -> String {
        let manager = try await loadedManager()
        var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(
            samples,
            decoderState: &decoderState,
            language: languageCode.flatMap(Language.init(rawValue:))
        )
        return result.text
    }

    private func loadedManager() async throws -> AsrManager {
        if let manager {
            return manager
        }

        let models = try await AsrModels.downloadAndLoad(version: Self.version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        return manager
    }
}
