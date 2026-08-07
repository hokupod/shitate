// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import AppKit
import XCTest

@MainActor
final class WorkspaceEventServiceTests: XCTestCase {
    func testSleepNotificationIsDeliveredImmediately() {
        let center = NotificationCenter()
        let service = WorkspaceEventService(notificationCenter: center, wakeDelay: .zero)
        var sleepCount = 0
        service.onWillSleep = {
            sleepCount += 1
        }
        service.start()

        center.post(name: NSWorkspace.willSleepNotification, object: nil)

        XCTAssertEqual(sleepCount, 1)
        service.stop()
    }

    func testWakeDeliveryWaitsForConfiguredDelay() async {
        let service = WorkspaceEventService(
            notificationCenter: NotificationCenter(),
            wakeDelay: .milliseconds(10)
        )
        var wakeCount = 0
        service.onDidWake = {
            wakeCount += 1
        }

        service.handleDidWake()
        XCTAssertEqual(wakeCount, 0)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(wakeCount, 1)
        service.stop()
    }

    func testSleepCancelsPendingWake() async {
        let service = WorkspaceEventService(
            notificationCenter: NotificationCenter(),
            wakeDelay: .milliseconds(10)
        )
        var wakeCount = 0
        service.onDidWake = {
            wakeCount += 1
        }

        service.handleDidWake()
        service.handleWillSleep()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(wakeCount, 0)
        service.stop()
    }

    func testProductionWakeDelayIsOneSecond() {
        XCTAssertEqual(WorkspaceEventService.defaultWakeDelay, .seconds(1))
    }
}
