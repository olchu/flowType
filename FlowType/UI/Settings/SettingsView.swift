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

    var systemImage: String {
        switch self {
        case .general:
            "gearshape.fill"
        case .permissions:
            "hand.raised.fill"
        case .models:
            "cpu.fill"
        case .transcription:
            "text.bubble.fill"
        case .textRules:
            "text.badge.checkmark"
        case .indicator:
            "waveform"
        case .sounds:
            "speaker.wave.2.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general:
            .gray
        case .permissions:
            .blue
        case .models:
            .purple
        case .transcription:
            .orange
        case .textRules:
            .green
        case .indicator:
            .teal
        case .sounds:
            .pink
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 214, max: 260)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 540, idealHeight: 620)
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
        List(selection: $selection) {
            ForEach(SettingsPane.allCases) { pane in
                sidebarRow(for: pane)
                    .tag(pane)
            }
        }
        .safeAreaInset(edge: .top) {
            SidebarHeader()
        }
    }

    private func sidebarRow(for pane: SettingsPane) -> some View {
        Label {
            HStack {
                Text(pane.title)

                Spacer()

                sidebarAccessory(for: pane)
            }
        } icon: {
            SettingsIcon(systemName: pane.systemImage, tint: pane.tint)
        }
        .padding(.vertical, 2)
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
        let pane = selection ?? .general

        Group {
            switch pane {
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
        .formStyle(.grouped)
        .navigationTitle(pane.title)
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
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
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
