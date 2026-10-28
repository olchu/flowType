//
//  FlowTypeApp.swift
//  FlowType
//
//  Created by olchu on 25. 5. 2026..
//

import SwiftUI

@main
struct FlowTypeApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image("statusbar")
                .accessibilityLabel("Flow Type")
                .background(SettingsOnLaunch())
        }
        .menuBarExtraStyle(.menu)

        Window("Flow Type Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
        }
        // No title bar strip: each page shows its own large title, and the
        // window buttons sit over the sidebar.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 820, height: 620)
        .windowResizability(.contentMinSize)

        Window("Wave Tuner", id: "wave-tuner") {
            WaveTunerView()
                .environmentObject(appState)
        }
        .defaultSize(width: 860, height: 760)
        .windowResizability(.contentMinSize)
    }
}

/// Opens the settings window at launch for `--open-settings`. It sits in
/// the menu bar label, the one view drawn at launch: opening a window needs
/// SwiftUI's `openWindow`, and on macOS 14 no scene can open itself.
private struct SettingsOnLaunch: View {
    /// The label can appear again, after a display change for one; the
    /// window opens only the first time.
    private static var hasOpened = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .task {
                guard LaunchArguments.opensSettings, !Self.hasOpened else { return }
                Self.hasOpened = true
                openWindow(id: "settings")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let appearance = LaunchArguments.appearance {
            NSApp.appearance = appearance
        }

        if let transcript = LaunchArguments.cleanupTranscript {
            Task {
                let service = TranscriptCleanupService()
                try? await service.prewarmLocalLLM(model: Self.cleanupModelArgument)
                let start = ContinuousClock.now
                let result = await service.clean(
                    transcript, mode: .localLLM, model: Self.cleanupModelArgument,
                    rules: SettingsStorageService().load().textRules
                )
                let elapsed = start.duration(to: .now)
                print(result.text)
                print("decision=\(result.decision)")
                print("cleanup=\(elapsed.formatted(.units(allowed: [.milliseconds])))")
                NSApplication.shared.terminate(nil)
            }
            return
        }

        guard LaunchArguments.prewarmsCleanupModel else { return }

        Task {
            do {
                try await TranscriptCleanupService().prewarmLocalLLM(model: Self.cleanupModelArgument)
                print("Cleanup model is ready.")
                NSApplication.shared.terminate(nil)
            } catch {
                fputs("Could not prewarm cleanup model: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
    }

    /// The `--cleanup-model` one, or the saved setting.
    private static var cleanupModelArgument: CleanupLLMModel {
        LaunchArguments.cleanupModel ?? SettingsStorageService().load().cleanupModel
    }
}
