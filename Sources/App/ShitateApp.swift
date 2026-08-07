// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import AppKit
import SwiftUI

@main
struct ShitateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Shi-tate", id: "main") {
            MainView()
                .environment(model)
                .task {
                    appDelegate.model = model
                    await model.bootstrap()
                }
        }

        MenuBarExtra("Shi-tate", systemImage: model.statusSymbol) {
            MenuBarView()
                .environment(model)
        }

        Settings {
            SettingsView()
                .environment(model)
        }

        .commands {
            CommandMenu("Routing") {
                Button(model.isRoutingActive ? "Stop Routing" : "Start Routing") {
                    model.isRoutingActive ? model.stopRouting() : model.startRouting()
                }
                .disabled(!model.isRoutingActive && !model.canStartRouting)
                Button(model.isMuted ? "Unmute" : "Mute") {
                    model.toggleMute()
                }
                .keyboardShortcut("m", modifiers: [.control, .shift])
                .disabled(model.state != .running && model.state != .muted)

                Divider()

                Button("Save Session") {
                    model.requestSaveSession()
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.canEditPluginChain)
            }
        }
    }
}
