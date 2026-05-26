import Foundation

enum ModelStorageState: Equatable {
    case notDownloaded
    case downloaded
    case downloading
    case deleting
    case error(String)

    var label: String {
        switch self {
        case .notDownloaded:
            "Not downloaded"
        case .downloaded:
            "Downloaded"
        case .downloading:
            "Downloading..."
        case .deleting:
            "Deleting..."
        case .error(let message):
            message
        }
    }
}
