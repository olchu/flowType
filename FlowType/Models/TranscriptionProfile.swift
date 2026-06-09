import Foundation

enum TranscriptionProfile: String, CaseIterable, Codable, Identifiable {
    case fast = "Fast"
    case balanced = "Balanced"
    case accurate = "Accurate"

    var id: String { rawValue }

    var model: TranscriptionModel {
        switch self {
        case .fast:
            .tiny
        case .balanced:
            .base
        case .accurate:
            .small
        }
    }

    var detail: String {
        switch self {
        case .fast:
            "Lightest Intel-friendly model, lowest accuracy"
        case .balanced:
            "Recommended Intel default, better accuracy without Large model cost"
        case .accurate:
            "Best Intel-friendly accuracy, slower startup and transcription"
        }
    }
}
