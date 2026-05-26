import Foundation

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case tiny = "Tiny"
    case base = "Base"
    case small = "Small"

    var id: String { rawValue }

    var whisperKitIdentifier: String {
        switch self {
        case .tiny:
            "openai_whisper-tiny"
        case .base:
            "openai_whisper-base"
        case .small:
            "openai_whisper-small"
        }
    }
}
