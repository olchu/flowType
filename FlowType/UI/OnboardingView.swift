import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header
            modelCard
            actions
        }
        .padding(28)
        .frame(width: 520, height: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Flow Type")
                .font(.largeTitle.bold())

            Text("Before dictation can work, Flow Type needs a local WhisperKit model. The model runs on this Mac, so your audio stays local.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Profile") {
                Text(appState.settings.profile.rawValue)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Model") {
                Text(appState.settings.profile.model.rawValue)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Status") {
                Text(appState.selectedModelStorageState.label)
                    .foregroundStyle(appState.selectedModelStorageState.color)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 8))
    }

    private var actions: some View {
        HStack {
            Button {
                appState.finishOnboarding()
            } label: {
                Text("Later")
            }

            Spacer()

            Button {
                appState.finishOnboarding()
            } label: {
                Text("Done")
            }
            .disabled(appState.selectedModelStorageState != .downloaded)

            Button {
                appState.download(appState.settings.profile.model)
            } label: {
                Label(downloadButtonTitle, systemImage: downloadButtonIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!appState.selectedModelStorageState.canDownload)
        }
    }

    private var downloadButtonTitle: String {
        switch appState.selectedModelStorageState {
        case .downloaded:
            "Downloaded"
        case .downloading:
            "Downloading"
        default:
            "Download Model"
        }
    }

    private var downloadButtonIcon: String {
        appState.selectedModelStorageState == .downloaded ? "checkmark.circle" : "arrow.down.circle"
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AppState())
}
