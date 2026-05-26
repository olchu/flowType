import Foundation

struct AppSettings: Codable, Equatable {
    var profile: TranscriptionProfile = .balanced
    var language: TranscriptionLanguage = .auto
    var autoPaste = true
    var restoreClipboard = true
    var microphoneSensitivity = 0.5

    private enum CodingKeys: String, CodingKey {
        case profile
        case language
        case autoPaste
        case restoreClipboard
        case microphoneSensitivity
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decodeIfPresent(TranscriptionProfile.self, forKey: .profile) ?? .balanced
        language = try container.decodeIfPresent(TranscriptionLanguage.self, forKey: .language) ?? .auto
        autoPaste = try container.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? true
        restoreClipboard = try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? true
        microphoneSensitivity = try container.decodeIfPresent(Double.self, forKey: .microphoneSensitivity) ?? 0.5
    }
}
