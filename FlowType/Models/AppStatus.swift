import Foundation

enum AppStatus: String, Equatable {
    case ready = "Ready"
    case recording = "Recording"
    case transcribing = "Transcribing"
    case error = "Error"

    var systemImageName: String {
        switch self {
        case .ready:
            "mic"
        case .recording:
            "waveform"
        case .transcribing:
            "text.bubble"
        case .error:
            "exclamationmark.triangle"
        }
    }
}
