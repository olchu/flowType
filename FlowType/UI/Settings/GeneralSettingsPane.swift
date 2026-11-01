import AppKit
import SwiftUI

struct GeneralSettingsPane: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appState: AppState
    @State private var isConfirmingReset = false
    @State private var isConfirmingClearHistory = false

    var body: some View {
        SettingsPage(.general) {
            SettingsSection("Hotkey", footer: "Hold the key while you speak and release it to paste the text. If it went nowhere, put the cursor where it belongs and press ⌃⌥V to paste it again.") {
                SettingsRow("Hold to dictate") {
                    Picker("Hold to dictate", selection: $appState.settings.dictationKey) {
                        ForEach(DictationKey.allCases) { key in
                            Text(key.rawValue).tag(key)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }

                SettingsToggle(
                    "Double-press for hands-free",
                    subtitle: "Keeps recording after you let go, until you press the key once more. Esc cancels.",
                    isOn: $appState.settings.handsFreeByDoublePress
                )

                if appState.settings.handsFreeByDoublePress {
                    SettingsRow("Finish hands-free after", subtitle: "A recording you forgot about stops by itself, and its text is pasted.") {
                        HStack(spacing: 8) {
                            TextField("Minutes", value: handsFreeLimit, format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 48)

                            Text("min")
                                .foregroundStyle(.secondary)

                            Stepper("Minutes", value: handsFreeLimit, in: Self.handsFreeLimits)
                                .labelsHidden()
                        }
                    }
                }

                SettingsRow("Paste last dictation") {
                    if appState.isHotkeyRunning && !appState.isPasteLastHotKeyAvailable {
                        Text("⌃⌥V is taken by another app")
                            .foregroundStyle(.secondary)
                    } else {
                        KeyCap(label: "⌃⌥V")
                    }
                }

                SettingsRow("Listener") {
                    StatusBadge(
                        appState.isHotkeyRunning ? "Running" : "Not running",
                        tone: appState.isHotkeyRunning ? .positive : .negative
                    )
                }

                if !appState.isHotkeyRunning {
                    SettingsRow(appState.hotkeyStatusMessage) {
                        Button("Restart Listener") {
                            appState.restartHotkey()
                        }
                    }
                }
            }

            SettingsSection("Microphone", footer: "Follows the system's microphone unless you choose one. A chosen microphone that isn't connected gives way to the system's until it's back.") {
                SettingsRow("Input") {
                    Picker("Input", selection: $appState.settings.microphoneUID) {
                        Text("System Default").tag(String?.none)
                        ForEach(appState.microphones) { microphone in
                            Text(microphone.name).tag(String?.some(microphone.uid))
                        }
                        if let uid = appState.settings.microphoneUID, !appState.microphones.contains(where: { $0.uid == uid }) {
                            Text("Not connected").tag(String?.some(uid))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            SettingsSection("Paste") {
                SettingsToggle(
                    "Paste automatically",
                    subtitle: "Insert the text into the focused field. When off, it is only copied.",
                    isOn: $appState.settings.autoPaste
                )

                SettingsToggle(
                    "Restore clipboard",
                    subtitle: "Put back what was on the clipboard before the paste.",
                    isOn: $appState.settings.restoreClipboard
                )
                .disabled(!appState.settings.autoPaste)
            }

            SettingsSection("History", footer: "The last 100 dictations from the past week, encrypted on this Mac with a key kept in the Keychain. Audio is never saved.") {
                SettingsToggle(
                    "Keep history",
                    subtitle: "Search past dictations and paste one again in a click.",
                    isOn: $appState.settings.keepsHistory
                )

                SettingsRow("Dictations") {
                    HStack(spacing: 8) {
                        Button("Clear…", role: .destructive) {
                            isConfirmingClearHistory = true
                        }

                        Button("Open History") {
                            openWindow(id: "history")
                        }
                        .buttonStyle(.settingsProminent)
                    }
                }
            }

            SettingsSection("Startup") {
                SettingsToggle(
                    "Open at login",
                    subtitle: appState.launchAtLoginStatusMessage,
                    isOn: Binding(
                        get: { appState.isLaunchAtLoginEnabled },
                        set: { appState.setLaunchAtLoginEnabled($0) }
                    )
                )
            }

            SettingsSection("Reset", footer: "Flow Type \(appVersion) · Local voice dictation") {
                SettingsRow("Reset settings", subtitle: "Downloaded models and permissions are kept.") {
                    Button("Reset…", role: .destructive) {
                        isConfirmingReset = true
                    }
                    .buttonStyle(.settingsProminent)
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
            Text("Hotkey, microphone, profile, language, cleanup, text rules, paste, indicator and sound settings go back to their defaults. Your dictionary, snippets and history are kept.")
        }
        .clearHistoryConfirmation(isPresented: $isConfirmingClearHistory, history: appState.history)
    }

    private static let handsFreeLimits = 1...480

    /// Typing gets past the stepper's range, so it is held to it here.
    private var handsFreeLimit: Binding<Int> {
        Binding(
            get: { appState.settings.handsFreeLimitMinutes },
            set: { appState.settings.handsFreeLimitMinutes = min(max($0, Self.handsFreeLimits.lowerBound), Self.handsFreeLimits.upperBound) }
        )
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.8"
    }
}
