import Foundation

enum TranscriptionLanguage: String, CaseIterable, Codable, Identifiable {
    case auto = "Auto"
    case russian = "Russian"
    case english = "English"

    var id: String { rawValue }

    var whisperKitCode: String? {
        switch self {
        case .auto:
            nil
        case .russian:
            "ru"
        case .english:
            "en"
        }
    }

    var speechLocale: Locale {
        switch self {
        case .auto:
            .current
        case .russian:
            Locale(identifier: "ru_RU")
        case .english:
            Locale(identifier: "en_US")
        }
    }
}
