import Foundation

struct AppSettings {
    var model: TranscriptionModel = .largeV3Turbo
    var language: TranscriptionLanguage = .auto
    var autoPaste = true
    var restoreClipboard = true
}
