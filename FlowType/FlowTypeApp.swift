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
        }
        .menuBarExtraStyle(.menu)

        Window("Flow Type Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let transcript = Self.cleanupTranscriptArgument {
            Task {
                let result = await TranscriptCleanupService().clean(transcript, mode: .localLLM)
                print(result.text)
                print("decision=\(result.decision)")
                NSApplication.shared.terminate(nil)
            }
            return
        }

        guard ProcessInfo.processInfo.arguments.contains("--prewarm-cleanup-model") else { return }

        Task {
            do {
                try await TranscriptCleanupService().prewarmLocalLLM()
                print("Cleanup model is ready.")
                NSApplication.shared.terminate(nil)
            } catch {
                fputs("Could not prewarm cleanup model: \(error.localizedDescription)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
    }

    private static var cleanupTranscriptArgument: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--cleanup-transcript") else { return nil }

        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { return nil }
        return arguments[valueIndex]
    }
}
