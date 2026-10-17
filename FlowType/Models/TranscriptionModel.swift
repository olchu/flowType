import Foundation

enum TranscriptionEngine {
    case whisperKit
    case parakeet
}

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case tiny = "Tiny"
    case largeV3TurboCompact = "Large v3 Turbo 632MB"
    case largeV3 = "Large v3"
    case parakeetUltra = "Parakeet Ultra 630MB"

    static let repository = "argmaxinc/whisperkit-coreml"

    var id: String { rawValue }

    var engine: TranscriptionEngine {
        switch self {
        case .tiny, .largeV3TurboCompact, .largeV3:
            .whisperKit
        case .parakeetUltra:
            .parakeet
        }
    }

    /// Only WhisperKit models transcribe while recording; Parakeet decodes the
    /// finished recording, which is faster than Whisper's tail re-decode.
    var supportsStreaming: Bool {
        engine == .whisperKit
    }

    /// Whisper invents text for trailing silence, so it is cut before decoding.
    /// Parakeet does not, and keeps the whole recording.
    var trimsTrailingSilence: Bool {
        engine == .whisperKit
    }

    var sourceName: String {
        whisperKitIdentifier ?? "FluidInference/parakeet-ultra-coreml"
    }

    var whisperKitIdentifier: String? {
        switch self {
        case .tiny:
            "openai_whisper-tiny"
        case .largeV3TurboCompact:
            "openai_whisper-large-v3-v20240930_turbo_632MB"
        case .largeV3:
            "openai_whisper-large-v3_947MB"
        case .parakeetUltra:
            nil
        }
    }
}
