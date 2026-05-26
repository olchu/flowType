import Foundation

enum TranscriptionModel: String, Identifiable {
    case tiny = "Tiny"
    case largeV3TurboCompact = "Large v3 Turbo 632MB"
    case largeV3 = "Large v3"

    var id: String { rawValue }

    var whisperKitIdentifier: String {
        switch self {
        case .tiny:
            "openai_whisper-tiny"
        case .largeV3TurboCompact:
            "openai_whisper-large-v3-v20240930_turbo_632MB"
        case .largeV3:
            "openai_whisper-large-v3_947MB"
        }
    }
}
