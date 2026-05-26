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
