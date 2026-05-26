import AppKit
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading) {
            statusSection

            Divider()

            if !appState.hasAccessibilityPermission {
                Button("Open Accessibility Settings") {
                    appState.requestAccessibilityPermission()
                }
            }

            if !appState.microphonePermission.isGranted {
                Button("Grant Microphone Permission") {
                    appState.requestMicrophonePermission()
                }
            }

            Button("Refresh Permissions") {
                appState.refreshPermissions()
            }

            Button("Start Recording") {
                appState.startDictation()
            }
            .disabled(!appState.canStartRecording)

            Button("Stop and Paste") {
                appState.finishDictation()
            }
            .disabled(!appState.canStopRecording)

            Divider()

            if !appState.lastTranscript.isEmpty {
                Text("Last transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(appState.lastTranscript)
                    .lineLimit(3)
            }

            Button("Settings...") {
                NSApplication.shared.sendAction(
                    Selector(("showSettingsWindow:")),
                    to: nil,
                    from: nil
                )
            }

            Button("Quit FlowType") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .frame(minWidth: 240)
        .padding(.vertical, 6)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(appState.status.rawValue, systemImage: appState.status.systemImageName)
                .font(.headline)

            Text("Model: \(appState.settings.model.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(appState.modelWarmupMessage)
                .font(.caption)
                .foregroundStyle(appState.isModelWarmingUp ? Color.orange : Color.secondary)

            Text("Microphone: \(appState.microphonePermission.rawValue)")
                .font(.caption)
                .foregroundStyle(appState.microphonePermission.isGranted ? Color.secondary : Color.red)

            Text("Accessibility: \(appState.hasAccessibilityPermission ? "Granted" : "Missing")")
                .font(.caption)
                .foregroundStyle(appState.hasAccessibilityPermission ? Color.secondary : Color.red)

            Text("Hotkey: \(appState.isHotkeyRunning ? "Fn" : "Not running")")
                .font(.caption)
                .foregroundStyle(appState.isHotkeyRunning ? Color.secondary : Color.red)

            if !appState.isHotkeyRunning {
                Text(appState.hotkeyStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = appState.lastErrorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)

                Button("Restart Hotkey") {
                    appState.restartHotkey()
                }

                Button("Clear Error") {
                    appState.clearError()
                }
            }
        }
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
