import Foundation
import ServiceManagement

final class LoginItemService {
    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            "Enabled"
        case .notRegistered:
            "Disabled"
        case .requiresApproval:
            "Requires approval in System Settings"
        case .notFound:
            "Unavailable"
        @unknown default:
            "Unknown"
        }
    }

    func setEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            if SMAppService.mainApp.status != .enabled {
                try SMAppService.mainApp.register()
            }
        } else {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        }
    }
}
