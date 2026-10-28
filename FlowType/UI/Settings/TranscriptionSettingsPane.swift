import SwiftUI

struct TranscriptionSettingsPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsPage(.transcription) {
            SettingsSection("Language", footer: "Auto lets the model detect the language of each dictation.") {
                SettingsSegmentedPicker(
                    label: "Language",
                    selection: $appState.settings.language,
                    options: TranscriptionLanguage.allCases,
                    title: \.rawValue
                )
            }

            if appState.settings.profile.model.supportsStreaming {
                SettingsSection("Streaming", footer: appState.settings.finalizationMode.detail) {
                    SettingsRow("Finalization") {
                        Picker("Finalization", selection: $appState.settings.finalizationMode) {
                            ForEach(TranscriptionFinalizationMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }

            SettingsSection("Cleanup", footer: cleanupFooter) {
                SettingsSegmentedPicker(
                    label: "Cleanup mode",
                    selection: $appState.settings.cleanupMode,
                    options: TranscriptCleanupMode.allCases,
                    title: \.rawValue
                )

                if appState.settings.cleanupMode == .localLLM {
                    SettingsRow("Model") {
                        Picker("Model", selection: $appState.settings.cleanupModel) {
                            ForEach(CleanupLLMModel.allCases) { model in
                                Text(model.rawValue).tag(model)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    SettingsRow("Status") {
                        HStack(spacing: 8) {
                            if appState.isCleanupModelWarmingUp {
                                ProgressView()
                                    .controlSize(.small)
                            }

                            Text(appState.cleanupModelMessage)
                                .foregroundStyle(.secondary)

                            if !appState.isCleanupModelWarmingUp {
                                Button("Load") {
                                    appState.prewarmTranscriptCleanupModel()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    private var cleanupFooter: String {
        if appState.settings.cleanupMode == .localLLM {
            "\(appState.settings.cleanupMode.detail) \(appState.settings.cleanupModel.detail)"
        } else {
            appState.settings.cleanupMode.detail
        }
    }
}
