// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    private let instanceGuard = SingleInstanceGuard()
    private var isPreparingToTerminate = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        do {
            guard try instanceGuard.acquire() else {
                activateExistingInstance()
                NSApplication.shared.terminate(nil)
                return
            }
        } catch {
            NSApplication.shared.presentError(error)
            NSApplication.shared.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else {
            return .terminateNow
        }
        guard !isPreparingToTerminate else {
            return .terminateLater
        }
        isPreparingToTerminate = true
        model.prepareForTermination { _ in
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        instanceGuard.release()
    }

    private func activateExistingInstance() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return
        }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != currentPID }?
            .activate(options: [.activateAllWindows])
    }
}
