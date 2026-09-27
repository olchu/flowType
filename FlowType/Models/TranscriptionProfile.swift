import Foundation

enum TranscriptionProfile: String, CaseIterable, Codable, Identifiable {
    case fast = "Fast"
    case balanced = "Balanced"
    case accurate = "Accurate"
    case parakeet = "Parakeet"

    var id: String { rawValue }

    var model: TranscriptionModel {
        switch self {
        case .fast:
            .tiny
        case .balanced:
            .largeV3TurboCompact
        case .accurate:
            .largeV3
        case .parakeet:
            .parakeetUltra
        }
    }

    var detail: String {
        switch self {
        case .fast:
            "Fast startup, lower accuracy"
        case .balanced:
            "Better accuracy, smaller Turbo model"
        case .accurate:
            "Best accuracy, slower startup"
        case .parakeet:
            "NVIDIA Parakeet: fastest, accurate on Russian, English and 23 more European languages. No live preview while recording."
        }
    }
}
