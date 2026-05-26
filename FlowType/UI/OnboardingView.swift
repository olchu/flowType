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
            Text("FlowType")
                .font(.largeTitle.bold())

            Text("Before dictation can work, FlowType needs a local WhisperKit model. The model runs on this Mac, so your audio stays local.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Recommended profile") {
                Text(appState.settings.profile.rawValue)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Model") {
                Text(appState.settings.profile.model.rawValue)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Status") {
                Text(statusText)
                    .foregroundStyle(statusColor)
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
                appState.downloadSelectedModelFromOnboarding()
            } label: {
                Label(downloadButtonTitle, systemImage: downloadButtonIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canDownload)
        }
    }

    private var statusText: String {
        switch appState.selectedModelStorageState {
        case .notDownloaded:
            "Not downloaded"
        case .downloaded:
            "Downloaded"
        case .downloading:
            "Downloading..."
        case .deleting:
            "Deleting..."
        case .error(let message):
            message
        }
    }

    private var statusColor: Color {
        switch appState.selectedModelStorageState {
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

    private var canDownload: Bool {
        switch appState.selectedModelStorageState {
        case .notDownloaded, .error:
            true
        case .downloaded, .downloading, .deleting:
            false
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
        switch appState.selectedModelStorageState {
        case .downloaded:
            "checkmark.circle"
        case .downloading:
            "arrow.down.circle"
        default:
            "arrow.down.circle"
        }
    }
}

#Preview {
    OnboardingView()
        .environmentObject(AppState())
}
