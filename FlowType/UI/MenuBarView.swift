import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading) {
            Label(appState.menuStatusText, systemImage: appState.status.systemImageName)
                .font(.headline)

            Divider()

            Button {
                openWindow(id: "settings")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("Settings...", systemImage: "gearshape")
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit FlowType", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
        .frame(minWidth: 190)
        .padding(.vertical, 6)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState())
}
