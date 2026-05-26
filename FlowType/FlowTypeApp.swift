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
            Label("FlowType", systemImage: appState.status.systemImageName)
        }
        .menuBarExtraStyle(.menu)

        Window("FlowType Settings", id: "settings") {
            SettingsView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
    }
}
