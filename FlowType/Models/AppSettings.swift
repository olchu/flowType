import Foundation

struct AppSettings {
    var model: TranscriptionModel = .tiny
    var language: TranscriptionLanguage = .auto
    var autoPaste = true
    var restoreClipboard = true
}
