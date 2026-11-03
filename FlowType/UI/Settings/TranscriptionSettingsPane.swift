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

            if appState.settings.cleanupMode == .externalLLM {
                externalLLMSection
            }
        }
    }

    private var externalLLMSection: some View {
        SettingsSection("External LLM", footer: externalLLMFooter) {
            SettingsRow("Provider") {
                Picker("Provider", selection: provider) {
                    ForEach(ExternalLLMProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            SettingsRow("Server") {
                TextField("Server", text: $appState.settings.externalLLM.baseURL, prompt: Text("https://example.com/v1"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(maxWidth: 320)
            }

            if appState.settings.externalLLM.provider.takesAPIKey {
                SettingsRow(
                    "API key",
                    subtitle: appState.settings.externalLLM.provider.requiresAPIKey ? nil : "If the server asks for one."
                ) {
                    SecureField("API key", text: $appState.externalLLMAPIKey, prompt: Text("Kept in the Keychain"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(maxWidth: 320)
                }
            }

            SettingsRow("Model") {
                HStack(spacing: 6) {
                    TextField("Model", text: $appState.settings.externalLLM.model, prompt: Text("Press Check to list the models"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()

                    if !appState.externalLLMModels.isEmpty {
                        Menu {
                            ForEach(appState.externalLLMModels, id: \.self) { model in
                                Button(model) {
                                    appState.settings.externalLLM.model = model
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Choose a model")
                    }
                }
                .frame(maxWidth: 320)
            }

            SettingsRow("Your instructions", subtitle: "Added to the built-in prompt.") {
                TextField(
                    "Instructions",
                    text: $appState.settings.externalLLM.instructions,
                    prompt: Text("Keep English terms in Latin script"),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .lineLimit(1...5)
                .frame(maxWidth: 320)
            }

            SettingsRow("Connection") {
                HStack(spacing: 8) {
                    if appState.isCheckingExternalLLM {
                        ProgressView()
                            .controlSize(.small)
                    } else if let message = appState.externalLLMMessage {
                        Text(message.text)
                            .foregroundStyle(message.isSuccess ? Color.secondary : Color.red)
                            .lineLimit(3)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }

                    Button("Check") {
                        appState.checkExternalLLM()
                    }
                    .controlSize(.small)
                    .disabled(appState.isCheckingExternalLLM)
                }
                .frame(maxWidth: 360, alignment: .trailing)
            }
        }
    }

    /// Switching provider brings its own server and model.
    private var provider: Binding<ExternalLLMProvider> {
        Binding {
            appState.settings.externalLLM.provider
        } set: {
            appState.settings.externalLLM.select($0)
        }
    }

    private var externalLLMFooter: String {
        let external = appState.settings.externalLLM
        let fallback = "If the model doesn't answer within \(ExternalLLMClient.timeout(for: external).components.seconds) seconds, the rule-based text is pasted."
        if external.isLocal {
            return "The model runs on this Mac, so the text stays here. Your dictionary's words are added to the prompt, so the model keeps their spelling. \(fallback)"
        }
        let host = external.host ?? "the server"
        return "Every dictation's text is sent to \(host) after the local rules, with your dictionary's words, and the provider's privacy terms apply to it. Audio and snippets never leave your Mac. \(fallback)"
    }

    private var cleanupFooter: String {
        if appState.settings.cleanupMode == .localLLM {
            "\(appState.settings.cleanupMode.detail) \(appState.settings.cleanupModel.detail)"
        } else {
            appState.settings.cleanupMode.detail
        }
    }
}
