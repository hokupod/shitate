// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import AppKit
import Foundation

@MainActor
final class WorkspaceEventService {
    static let defaultWakeDelay = Duration.seconds(1)

    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    private let notificationCenter: NotificationCenter
    private let wakeDelay: Duration
    private var observers: [NSObjectProtocol] = []
    private var wakeTask: Task<Void, Never>?

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        wakeDelay: Duration = defaultWakeDelay
    ) {
        self.notificationCenter = notificationCenter
        self.wakeDelay = wakeDelay
    }

    func start() {
        guard observers.isEmpty else {
            return
        }
        observers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleWillSleep()
                }
            }
        )
        observers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleDidWake()
                }
            }
        )
    }

    func stop() {
        wakeTask?.cancel()
        wakeTask = nil
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    func handleWillSleep() {
        wakeTask?.cancel()
        onWillSleep?()
    }

    func handleDidWake() {
        wakeTask?.cancel()
        let delay = wakeDelay
        wakeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else {
                return
            }
            self?.onDidWake?()
        }
    }
}
