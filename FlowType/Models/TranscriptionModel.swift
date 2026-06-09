import Foundation

enum TranscriptionModel: String, Hashable, Identifiable {
    case tiny = "Tiny"
    case base = "Base"
    case small = "Small"

    static let repository = "argmaxinc/whisperkit-coreml"

    static let availableModels: [TranscriptionModel] = [
        .tiny,
        .base,
        .small,
    ]

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

    var detail: String {
        switch self {
        case .tiny:
            "Smallest download and fastest startup; useful for quick Intel smoke tests."
        case .base:
            "Recommended Intel default; much lighter than Large while keeping usable dictation quality."
        case .small:
            "Higher accuracy option for Intel Macs; expect slower transcription than Base."
        }
    }
}
