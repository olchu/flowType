import SwiftUI

struct TranscriptionSettingsPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $appState.settings.language) {
                    ForEach(TranscriptionLanguage.allCases) { language in
                        Text(language.rawValue).tag(language)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Auto lets the model detect the language of each dictation.")
            }

            if appState.settings.profile.model.supportsStreaming {
                Section {
                    Picker("Finalization", selection: $appState.settings.finalizationMode) {
                        ForEach(TranscriptionFinalizationMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                } header: {
                    Text("Streaming")
                } footer: {
                    Text(appState.settings.finalizationMode.detail)
                }
            }

            Section {
                Picker("Mode", selection: $appState.settings.cleanupMode) {
                    ForEach(TranscriptCleanupMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if appState.settings.cleanupMode == .localLLM {
                    Picker("Model", selection: $appState.settings.cleanupModel) {
                        ForEach(CleanupLLMModel.allCases) { model in
                            Text(model.rawValue).tag(model)
                        }
                    }

                    LabeledContent("Status") {
                        if appState.isCleanupModelWarmingUp {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)

                                Text(appState.cleanupModelMessage)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack(spacing: 8) {
                                Text(appState.cleanupModelMessage)
                                    .foregroundStyle(.secondary)

                                Button("Load") {
                                    appState.prewarmTranscriptCleanupModel()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
            } header: {
                Text("Cleanup")
            } footer: {
                if appState.settings.cleanupMode == .localLLM {
                    Text("\(appState.settings.cleanupMode.detail) \(appState.settings.cleanupModel.detail)")
                } else {
                    Text(appState.settings.cleanupMode.detail)
                }
            }
        }
    }
}
