import Foundation

enum TranscriptionLanguage: String, CaseIterable, Codable, Identifiable {
    case auto = "Auto"
    case russian = "Russian"
    case english = "English"

    nonisolated var id: String { rawValue }

    nonisolated var whisperKitCode: String? {
        switch self {
        case .auto:
            nil
        case .russian:
            "ru"
        case .english:
            "en"
        }
    }
}
