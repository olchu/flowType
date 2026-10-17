import SwiftUI

struct PermissionsSettingsPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    systemImage: "mic.fill",
                    tint: .red,
                    title: "Microphone",
                    detail: "Records your voice while you hold Fn. Audio never leaves this Mac.",
                    isGranted: appState.microphonePermission.isGranted,
                    actionTitle: appState.microphonePermission == .notDetermined ? "Allow…" : "Open Settings…"
                ) {
                    appState.requestMicrophonePermission()
                }

                PermissionRow(
                    systemImage: "accessibility",
                    tint: .blue,
                    title: "Accessibility",
                    detail: "Listens for the Fn key and pastes the text into other apps.",
                    isGranted: appState.hasAccessibilityPermission,
                    actionTitle: "Open Settings…"
                ) {
                    appState.requestAccessibilityPermission()
                }
            } footer: {
                HStack {
                    Text("Changes made in System Settings are picked up when you come back.")

                    Spacer()

                    Button("Check Again") {
                        appState.restartHotkey()
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

private struct PermissionRow: View {
    let systemImage: String
    let tint: Color
    let title: String
    let detail: String
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: systemImage, tint: tint, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if isGranted {
                StatusBadge("Granted", tone: .positive)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}
