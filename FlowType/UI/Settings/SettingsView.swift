import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case permissions
    case models
    case transcription
    case textRules
    case indicator
    case sounds

    var id: Self { self }

    var title: String {
        switch self {
        case .general:
            "General"
        case .permissions:
            "Permissions"
        case .models:
            "Models"
        case .transcription:
            "Transcription"
        case .textRules:
            "Text Rules"
        case .indicator:
            "Indicator"
        case .sounds:
            "Sounds"
        }
    }

    /// Shown filled when the pane is selected.
    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .permissions:
            "hand.raised"
        case .models:
            "cpu"
        case .transcription:
            "bubble.left"
        case .textRules:
            "list.bullet"
        case .indicator:
            "waveform"
        case .sounds:
            "speaker.wave.2"
        }
    }

    var subtitle: String {
        switch self {
        case .general:
            "Configure how Flow Type works on your Mac."
        case .permissions:
            "What Flow Type needs to hear you and type for you."
        case .models:
            "Speech recognition that runs on this Mac."
        case .transcription:
            "How your speech becomes text."
        case .textRules:
            "Rules applied to the text after recognition."
        case .indicator:
            "How the indicator above the Dock looks and reacts."
        case .sounds:
            "Cues for each step of a dictation."
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection = LaunchArguments.settingsPane ?? .general

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 260)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 620)
        .settingsTheme()
        .onAppear {
            appState.refreshPermissions()
            appState.refreshLaunchAtLoginStatus()
        }
        // Permissions are granted in System Settings; pick them up on return.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appState.refreshPermissions()
            appState.refreshLaunchAtLoginStatus()
        }
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                SidebarHeader()

                ForEach(SettingsPane.allCases) { pane in
                    sidebarRow(for: pane)
                }
            }
            .padding(.horizontal, 10)
            // The arrow keys move through the panes, as in a sidebar list;
            // the selected row shows where focus is.
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                let panes = SettingsPane.allCases
                guard let index = panes.firstIndex(of: selection) else { return }
                switch direction {
                case .up: selection = panes[max(index - 1, 0)]
                case .down: selection = panes[min(index + 1, panes.count - 1)]
                default: break
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Settings")
        }
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            // The author's mark, dark in light and inverted in dark.
            Image("OlchuLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 18)
                .foregroundStyle(.primary.opacity(0.85))
                .padding(.leading, 22)
                .padding(.bottom, 18)
                .accessibilityLabel("olchu")
        }
    }

    private func sidebarRow(for pane: SettingsPane) -> some View {
        let isSelected = selection == pane

        return Button {
            selection = pane
        } label: {
            HStack(spacing: 12) {
                Image(systemName: pane.systemImage)
                    .symbolVariant(isSelected ? .fill : .none)
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 22)

                Text(pane.title)

                Spacer(minLength: 0)

                sidebarAccessory(for: pane)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .settingsSelection(isSelected, cornerRadius: 11)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sidebarAccessory(for pane: SettingsPane) -> some View {
        switch pane {
        case .permissions where !appState.microphonePermission.isGranted || !appState.hasAccessibilityPermission:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .help("Some permissions are missing")
        case .models where appState.isModelWarmingUp:
            ProgressView()
                .controlSize(.mini)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch selection {
            case .general:
                GeneralSettingsPane()
            case .permissions:
                PermissionsSettingsPane()
            case .models:
                ModelsSettingsPane()
            case .transcription:
                TranscriptionSettingsPane()
            case .textRules:
                TextRulesSettingsPane()
            case .indicator:
                IndicatorSettingsPane()
            case .sounds:
                SoundsSettingsPane()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let message = appState.lastErrorMessage {
                ErrorBanner(message: message) {
                    appState.clearError()
                }
            }
        }
    }
}

/// App icon, name and readiness at the top of the sidebar.
private struct SidebarHeader: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Flow Type")
                    .font(.headline)

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)

                    Text(appState.menuStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.top, 4)
        .padding(.bottom, 16)
    }

    private var statusColor: Color {
        if appState.isReadyForUse {
            return .green
        }
        return appState.status == .error ? .red : .orange
    }
}

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)

            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Dismiss", action: onDismiss)
                .controlSize(.small)
        }
        .padding(12)
        .background(.red.opacity(0.1), in: .rect(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.red.opacity(0.25))
        )
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppState())
}
