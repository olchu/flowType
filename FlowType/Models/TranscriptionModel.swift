import Foundation

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case largeV3Turbo = "Large v3 Turbo"
    case tiny = "Tiny"
    case small = "Small"
    case largeV3 = "Large v3"

    var id: String { rawValue }

    var whisperKitIdentifier: String {
        switch self {
        case .largeV3Turbo:
            "openai_whisper-large-v3_turbo_954MB"
        case .tiny:
            "openai_whisper-tiny"
        case .small:
            "openai_whisper-small"
        case .largeV3:
            "openai_whisper-large-v3_947MB"
        }
    }
}
