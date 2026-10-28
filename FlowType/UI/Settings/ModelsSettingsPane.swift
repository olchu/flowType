import SwiftUI

struct ModelsSettingsPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        SettingsPage(.models) {
            SettingsSection("Active model") {
                activeModel
            }

            SettingsSection("Profiles", footer: "Models run on this Mac. Each one is downloaded once and kept until you delete it.") {
                ForEach(TranscriptionProfile.allCases) { profile in
                    ProfileRow(profile: profile)
                }
            }
        }
    }

    private var activeModel: some View {
        SettingsRow(appState.settings.profile.model.rawValue, subtitle: appState.modelWarmupMessage, icon: "cpu") {
            if appState.isModelWarmingUp {
                HStack(spacing: 8) {
                    ProgressView(value: appState.modelLoadingProgress)
                        .frame(width: 120)

                    Text("\(Int(appState.modelLoadingProgress * 100))%")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else if appState.selectedModelStorageState == .downloaded {
                StatusBadge("Loaded", tone: .positive)
            } else {
                StatusBadge("Not downloaded", tone: .warning)
            }
        }
    }
}

private struct ProfileRow: View {
    @EnvironmentObject private var appState: AppState
    @State private var isConfirmingDelete = false
    let profile: TranscriptionProfile

    private var isSelected: Bool {
        appState.settings.profile == profile
    }

    private var state: ModelStorageState {
        appState.storageState(of: profile.model)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? SettingsStyle.ink : Color.secondary.opacity(0.5))

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.rawValue)
                        .fontWeight(.medium)

                    Text(profile.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(profile.model.rawValue)
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    if case .error(let message) = state {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .onTapGesture {
                appState.settings.profile = profile
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

            storageControls
        }
        .confirmationDialog(
            "Delete \(profile.model.rawValue)?",
            isPresented: $isConfirmingDelete
        ) {
            Button("Delete", role: .destructive) {
                appState.delete(profile.model)
            }
        } message: {
            Text("The model is removed from disk. You can download it again later.")
        }
    }

    @ViewBuilder
    private var storageControls: some View {
        switch state {
        case .downloaded:
            HStack(spacing: 6) {
                StatusBadge("Downloaded", tone: .positive)

                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete \(profile.model.rawValue)")
                .accessibilityLabel("Delete \(profile.model.rawValue)")
            }
        case .downloading, .deleting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)

                Text(state.label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .notDownloaded, .error:
            Button {
                appState.download(profile.model)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
        }
    }
}
