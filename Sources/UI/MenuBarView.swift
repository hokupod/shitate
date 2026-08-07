// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Shi-tate") {
            showMainWindow(section: model.selectedSection)
        }
        Divider()
        Button(model.primaryAudioActionTitle) {
            model.performPrimaryAudioAction()
        }
        .disabled(model.primaryAudioActionDisabled)
        Button(model.isMuted ? "Unmute" : "Mute") {
            model.toggleMute()
        }
        .disabled(model.state != .running && model.state != .muted)
        Divider()
        Label(
            "Input: \(model.selectedInput?.displayName ?? "Not selected")",
            systemImage: "mic"
        )
        Label("Output: \(model.activeOutputDescription)", systemImage: "arrow.up.forward.circle")
        if let error = model.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
        }
        Divider()
        SettingsLink {
            Text("Settings…")
        }
        Button("About Shi-tate") {
            showMainWindow(section: .about)
        }
        Divider()
        Button("Quit Shi-tate") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func showMainWindow(section: ProductSection) {
        model.selectedSection = section
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }
}
