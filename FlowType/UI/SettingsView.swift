import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Form {
                statusSection
                applicationSection
                permissionsSection
                modelsSection
                translationModelSection
                transcriptionSection
                indicatorSection
                pasteSection
                hotkeySection
                resetSection
            }
            .formStyle(.grouped)

            Text(appVersionText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.trailing, 18)
                .padding(.bottom, 10)
        }
        .padding()
        .frame(minWidth: 640, idealWidth: 640, minHeight: 640)
    }

    private var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v\(version ?? "0.8")"
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Application") {
                Text(appState.menuStatusText)
                    .foregroundStyle(appState.isReadyForUse ? Color.green : Color.orange)
            }

            if let message = appState.lastErrorMessage {
                Text(message)
                    .foregroundStyle(.red)

                Button("Clear Error") {
                    appState.clearError()
                }
            }
        }
    }

    private var permissionsSection: some View {
        Section("Permissions") {
            LabeledContent("Microphone") {
                permissionText(appState.microphonePermission.rawValue, granted: appState.microphonePermission.isGranted)
            }

            LabeledContent("Accessibility") {
                permissionText(appState.hasAccessibilityPermission ? "Granted" : "Missing", granted: appState.hasAccessibilityPermission)
            }

            HStack {
                Button {
                    appState.requestMicrophonePermission()
                } label: {
                    Label("Grant Microphone", systemImage: "mic")
                }
                .disabled(appState.microphonePermission.isGranted)

                Button {
                    appState.requestAccessibilityPermission()
                } label: {
                    Label("Open Accessibility", systemImage: "accessibility")
                }
                .disabled(appState.hasAccessibilityPermission)

                Button {
                    appState.refreshPermissions()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private var applicationSection: some View {
        Section("Application") {
            Toggle(
                "Open at login",
                isOn: Binding(
                    get: { appState.isLaunchAtLoginEnabled },
                    set: { appState.setLaunchAtLoginEnabled($0) }
                )
            )

            LabeledContent("Login item") {
                Text(appState.launchAtLoginStatusMessage)
                    .foregroundStyle(appState.isLaunchAtLoginEnabled ? Color.green : Color.secondary)
            }

            Button {
                appState.refreshLaunchAtLoginStatus()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private var modelsSection: some View {
        Section("Models") {
            Picker("Use profile", selection: $appState.settings.profile) {
                ForEach(TranscriptionProfile.allCases) { profile in
                    Text(profile.rawValue).tag(profile)
                }
            }
            .onChange(of: appState.settings.profile) {
                appState.prewarmCurrentModel()
            }

            Text(appState.settings.profile.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Current model") {
                Text(appState.settings.profile.model.rawValue)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Model status") {
                if appState.isModelWarmingUp {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(appState.modelWarmupMessage)
                                .foregroundStyle(.orange)
                            Text("\(Int(appState.modelLoadingProgress * 100))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        ProgressView(value: appState.modelLoadingProgress)
                            .frame(width: 180)
                            .tint(.orange)
                    }
                } else {
                    Text(appState.modelWarmupMessage)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(TranscriptionModel.availableModels) { model in
                modelRow(for: model)
            }
        }
    }

    private var transcriptionSection: some View {
        Section("Transcription") {
            Picker("Language", selection: $appState.settings.language) {
                ForEach(TranscriptionLanguage.allCases) { language in
                    Text(language.rawValue).tag(language)
                }
            }

            Picker("Finalization mode", selection: $appState.settings.finalizationMode) {
                ForEach(TranscriptionFinalizationMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            Text(appState.settings.finalizationMode.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Verify final tail on short recordings", isOn: $appState.settings.verifiesFinalTail)

            Text("Use Full recording as the baseline when comparing timing logs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var translationModelSection: some View {
        Section("Local AI Translation") {
            LabeledContent("Model") {
                Text(LocalAITranslationService.modelName)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Status") {
                Text(appState.translationModelState.label)
                    .foregroundStyle(translationModelStatusColor)
            }

            if appState.translationModelState == .downloading {
                ProgressView(value: appState.translationModelProgress)
                Text("Downloading and loading: \(Int(appState.translationModelProgress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Runs entirely on this Mac. If the model is unavailable, Flow Type falls back to Apple Translation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button {
                    appState.downloadTranslationModel()
                } label: {
                    Label(
                        appState.translationModelState == .downloaded ? "Load Model" : "Download Model",
                        systemImage: "arrow.down.circle"
                    )
                }
                .disabled(appState.translationModelState == .downloading)

                if appState.translationModelState == .downloaded {
                    Button(role: .destructive) {
                        appState.deleteTranslationModel()
                    } label: {
                        Label("Delete Model", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var translationModelStatusColor: Color {
        switch appState.translationModelState {
        case .downloaded:
            .green
        case .downloading, .deleting:
            .orange
        case .error:
            .red
        case .notDownloaded:
            .secondary
        }
    }

    private var pasteSection: some View {
        Section("Paste") {
            Toggle("Auto paste", isOn: $appState.settings.autoPaste)
            Toggle("Restore clipboard after paste", isOn: $appState.settings.restoreClipboard)
        }
    }

    private var indicatorSection: some View {
        Section("Indicator") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Microphone sensitivity")

                    Spacer()

                    Text("\(Int(appState.settings.microphoneSensitivity * 100))%")
                        .foregroundStyle(.secondary)
                }

                Slider(value: $appState.settings.microphoneSensitivity, in: 0...1) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "speaker")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3")
                }
            }

            Text("Lower values ignore more background noise. Higher values make the bars react to quieter speech.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var hotkeySection: some View {
        Section("Hotkey") {
            LabeledContent("Key") {
                Text("Fn")
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Translate selection") {
                Text("⌥⌘T")
                    .foregroundStyle(.secondary)
            }

            Text("Editable text is translated and replaced. Read-only selections are translated in a nearby window. Russian and English direction is detected automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(appState.translationStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Listener") {
                permissionText(appState.isHotkeyRunning ? "Running" : "Not running", granted: appState.isHotkeyRunning)
            }

            Text(appState.hotkeyStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                appState.restartHotkey()
            } label: {
                Label("Restart Hotkey", systemImage: "keyboard")
            }
        }
    }

    private var resetSection: some View {
        Section("Reset") {
            Text("Restore default profile, language, paste behavior, and indicator sensitivity. Downloaded models and permissions are not changed.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(role: .destructive) {
                appState.resetSettingsToDefaults()
            } label: {
                Label("Reset Settings", systemImage: "arrow.counterclockwise")
            }
        }
    }

    private func modelRow(for model: TranscriptionModel) -> some View {
        let state = appState.modelStorageStates[model] ?? .notDownloaded
        let isCurrent = appState.settings.profile.model == model

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.rawValue)
                        .font(.headline)

                    Text(model.whisperKitIdentifier)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(isCurrent ? "Selected" : state.label)
                    .font(.caption)
                    .foregroundStyle(color(for: state, isCurrent: isCurrent))
            }

            HStack {
                Button {
                    appState.download(model)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .disabled(state == .downloaded || state == .downloading || state == .deleting)

                Button(role: .destructive) {
                    appState.delete(model)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(state != .downloaded || state == .deleting)
            }
        }
        .padding(.vertical, 4)
    }

    private func permissionText(_ text: String, granted: Bool) -> some View {
        Text(text)
            .foregroundStyle(granted ? Color.green : Color.red)
    }

    private func color(for state: ModelStorageState, isCurrent: Bool) -> Color {
        if isCurrent {
            return .accentColor
        }

        switch state {
        case .downloaded:
            return .green
        case .notDownloaded:
            return .secondary
        case .downloading, .deleting:
            return .orange
        case .error:
            return .red
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
