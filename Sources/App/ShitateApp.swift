// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import AppKit
import SwiftUI

@main
struct ShitateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let bridge = STAudioEngineBridge()

    var body: some Scene {
        WindowGroup("Shi-tate", id: "main") {
            AppShellView(version: bridge.displayVersion)
                .frame(minWidth: 520, minHeight: 320)
        }

        MenuBarExtra("Shi-tate", systemImage: "waveform") {
            Text("Shi-tate \(bridge.displayVersion)")
            Divider()
            Button("Open Shi-tate") {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }

        Settings {
            Form {
                Text("Audio and plug-in settings arrive in later implementation phases.")
            }
            .padding(20)
            .frame(width: 460)
        }
    }
}

private struct AppShellView: View {
    let version: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Shi-tate", systemImage: "waveform")
                .font(.title)
            Text("Build foundation")
                .font(.headline)
            Text("Audio routing and VST3 hosting are not available yet.")
                .foregroundStyle(.secondary)
            Spacer()
            Text("Version \(version)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}
