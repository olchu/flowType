import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("Microphone") {
                    Text(appState.microphonePermission.rawValue)
                        .foregroundStyle(appState.microphonePermission.isGranted ? Color.secondary : Color.red)
                }

                LabeledContent("Accessibility") {
                    Text(appState.hasAccessibilityPermission ? "Granted" : "Missing")
                        .foregroundStyle(appState.hasAccessibilityPermission ? Color.secondary : Color.red)
                }

                HStack {
                    Button("Grant Microphone") {
                        appState.requestMicrophonePermission()
                    }
                    .disabled(appState.microphonePermission.isGranted)

                    Button("Grant Accessibility") {
                        appState.requestAccessibilityPermission()
                    }
                    .disabled(appState.hasAccessibilityPermission)

                    Button("Refresh") {
                        appState.refreshPermissions()
                    }
                }
            }

            Section("Transcription") {
                Picker("Model", selection: $appState.settings.model) {
                    ForEach(TranscriptionModel.allCases) { model in
                        Text(model.rawValue).tag(model)
                    }
                }

                Picker("Language", selection: $appState.settings.language) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.rawValue).tag(language)
                    }
                }
            }

            Section("Paste") {
                Toggle("Auto paste", isOn: $appState.settings.autoPaste)
                Toggle("Restore clipboard after paste", isOn: $appState.settings.restoreClipboard)
            }

            Section("Hotkey") {
                LabeledContent("Default") {
                    Text("Fn")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Status") {
                    Text(appState.isHotkeyRunning ? "Running" : "Not running")
                        .foregroundStyle(appState.isHotkeyRunning ? Color.secondary : Color.red)
                }

                Button("Restart Hotkey") {
                    appState.restartHotkey()
                }

                Text("The hotkey listener requires Accessibility permission.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
