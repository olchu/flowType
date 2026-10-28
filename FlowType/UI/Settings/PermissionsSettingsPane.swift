import SwiftUI

struct PermissionsSettingsPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsPage(.permissions) {
            SettingsSection("Access") {
                PermissionRow(
                    systemImage: "mic",
                    title: "Microphone",
                    detail: "Records your voice while you hold Fn. Audio never leaves this Mac.",
                    isGranted: appState.microphonePermission.isGranted,
                    actionTitle: appState.microphonePermission == .notDetermined ? "Allow…" : "Open Settings…"
                ) {
                    appState.requestMicrophonePermission()
                }

                PermissionRow(
                    systemImage: "accessibility",
                    title: "Accessibility",
                    detail: "Listens for the Fn key and pastes the text into other apps.",
                    isGranted: appState.hasAccessibilityPermission,
                    actionTitle: "Open Settings…"
                ) {
                    appState.requestAccessibilityPermission()
                }

                SettingsRow("Granted in System Settings?", subtitle: "Changes made there are picked up when you come back.") {
                    Button("Check Again") {
                        appState.restartHotkey()
                    }
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let systemImage: String
    let title: String
    let detail: String
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        SettingsRow(title, subtitle: detail, icon: systemImage) {
            if isGranted {
                StatusBadge("Granted", tone: .positive)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.settingsProminent)
            }
        }
    }
}
