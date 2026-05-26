import AVFoundation
import Foundation

enum PermissionStatus: String, Equatable {
    case granted = "Granted"
    case notDetermined = "Not Determined"
    case denied = "Denied"
    case restricted = "Restricted"
    case unknown = "Unknown"

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized:
            self = .granted
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        @unknown default:
            self = .unknown
        }
    }

    var isGranted: Bool {
        self == .granted
    }
}
