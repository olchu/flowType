import SwiftUI

struct ModelsSettingsPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section {
                activeModel
            }

            Section {
                ForEach(TranscriptionProfile.allCases) { profile in
                    ProfileRow(profile: profile)
                }
            } header: {
                Text("Speech recognition")
            } footer: {
                Text("Models run on this Mac. Each one is downloaded once and kept until you delete it.")
            }
        }
    }

    private var activeModel: some View {
        HStack(spacing: 12) {
            SettingsIcon(systemName: "cpu.fill", tint: .purple, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(appState.settings.profile.model.rawValue)
                    .font(.headline)

                Text(appState.modelWarmupMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

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
        .padding(.vertical, 4)
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
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.rawValue)
                        .font(.headline)

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
        .padding(.vertical, 4)
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
