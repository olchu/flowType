import Foundation

enum TranscriptionFinalizationMode: String, Codable, CaseIterable, Identifiable {
    case streamTail = "Stream + tail"
    case fullRecording = "Full recording"
    case streamOnly = "Stream only"

    var id: Self { self }

    var detail: String {
        switch self {
        case .streamTail:
            "Current mode. Uses streaming text, then verifies the final few seconds."
        case .fullRecording:
            "Baseline mode. Transcribes the whole recording after you release Fn."
        case .streamOnly:
            "Fastest mode. Uses only streaming text, so the final words may be less reliable."
        }
    }
}

struct AppSettings: Codable, Equatable {
    var profile: TranscriptionProfile = .balanced
    var language: TranscriptionLanguage = .auto
    var finalizationMode: TranscriptionFinalizationMode = .streamTail
    var autoPaste = true
    var restoreClipboard = true
    var microphoneSensitivity = 0.5
    var verifiesFinalTail = false

    private enum CodingKeys: String, CodingKey {
        case profile
        case language
        case finalizationMode
        case autoPaste
        case restoreClipboard
        case microphoneSensitivity
        case verifiesFinalTail
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decodeIfPresent(TranscriptionProfile.self, forKey: .profile) ?? .balanced
        language = try container.decodeIfPresent(TranscriptionLanguage.self, forKey: .language) ?? .auto
        finalizationMode = try container.decodeIfPresent(TranscriptionFinalizationMode.self, forKey: .finalizationMode) ?? .streamTail
        autoPaste = try container.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? true
        restoreClipboard = try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? true
        microphoneSensitivity = try container.decodeIfPresent(Double.self, forKey: .microphoneSensitivity) ?? 0.5
        verifiesFinalTail = try container.decodeIfPresent(Bool.self, forKey: .verifiesFinalTail) ?? false
    }
}
