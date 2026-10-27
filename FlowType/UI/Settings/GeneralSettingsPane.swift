import AppKit
import SwiftUI

struct GeneralSettingsPane: View {
    @EnvironmentObject private var appState: AppState
    @State private var isConfirmingReset = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Flow Type")
                            .font(.title2.weight(.semibold))

                        Text("Local voice dictation · Version \(appVersion)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section {
                LabeledContent("Hold to dictate") {
                    KeyCap(label: "fn")
                }

                LabeledContent("Paste last dictation") {
                    if appState.isHotkeyRunning && !appState.isPasteLastHotKeyAvailable {
                        Text("⌃⌥V is taken by another app")
                            .foregroundStyle(.secondary)
                    } else {
                        KeyCap(label: "⌃⌥V")
                    }
                }

                LabeledContent("Listener") {
                    StatusBadge(
                        appState.isHotkeyRunning ? "Running" : "Not running",
                        tone: appState.isHotkeyRunning ? .positive : .negative
                    )
                }

                if !appState.isHotkeyRunning {
                    HStack {
                        Text(appState.hotkeyStatusMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Restart Listener") {
                            appState.restartHotkey()
                        }
                    }
                }
            } header: {
                Text("Hotkey")
            } footer: {
                Text("Hold Fn while you speak and release it to paste the text. If it went nowhere, put the cursor where it belongs and press ⌃⌥V to paste it again.")
            }

            Section("Paste") {
                Toggle(isOn: $appState.settings.autoPaste) {
                    Text("Paste automatically")
                    Text("Insert the text into the focused field. When off, it is only copied.")
                }

                Toggle(isOn: $appState.settings.restoreClipboard) {
                    Text("Restore clipboard")
                    Text("Put back what was on the clipboard before the paste.")
                }
                .disabled(!appState.settings.autoPaste)
            }

            Section("Startup") {
                Toggle(
                    isOn: Binding(
                        get: { appState.isLaunchAtLoginEnabled },
                        set: { appState.setLaunchAtLoginEnabled($0) }
                    )
                ) {
                    Text("Open at login")
                    Text(appState.launchAtLoginStatusMessage)
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Reset settings")
                        Text("Downloaded models and permissions are kept.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Reset…", role: .destructive) {
                        isConfirmingReset = true
                    }
                }
            }
        }
        .confirmationDialog(
            "Reset all settings to their defaults?",
            isPresented: $isConfirmingReset
        ) {
            Button("Reset Settings", role: .destructive) {
                appState.resetSettingsToDefaults()
            }
        } message: {
            Text("Profile, language, cleanup, paste, indicator and sound settings go back to their defaults.")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.8"
    }
}
