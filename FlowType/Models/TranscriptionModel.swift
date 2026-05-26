import Foundation

enum TranscriptionModel: String, CaseIterable, Identifiable {
    case tiny = "Tiny"
    case base = "Base"
    case small = "Small"

    var id: String { rawValue }

    var whisperKitIdentifier: String {
        switch self {
        case .tiny:
            "tiny"
        case .base:
            "base"
        case .small:
            "small"
        }
    }
}
