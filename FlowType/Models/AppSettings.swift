import Foundation

struct AppSettings: Codable, Equatable {
    var profile: TranscriptionProfile = .balanced
    var language: TranscriptionLanguage = .auto
    var autoPaste = true
    var restoreClipboard = true
}
