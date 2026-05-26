import Foundation

struct AppSettings {
    var profile: TranscriptionProfile = .balanced
    var language: TranscriptionLanguage = .auto
    var autoPaste = true
    var restoreClipboard = true
}
