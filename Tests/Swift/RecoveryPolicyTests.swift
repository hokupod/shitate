// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import XCTest

final class RecoveryPolicyTests: XCTestCase {
    func testWakeRestartRequiresEveryExplicitCondition() {
        XCTAssertEqual(
            WakeRecoveryPolicy.decide(
                wasRoutingBeforeSleep: true,
                resumeAfterWake: true,
                environmentReady: true,
                sessionReady: true,
                pluginsValidated: true
            ),
            .restart
        )

        for missingCondition in 0..<5 {
            var conditions = [true, true, true, true, true]
            conditions[missingCondition] = false
            XCTAssertEqual(
                WakeRecoveryPolicy.decide(
                    wasRoutingBeforeSleep: conditions[0],
                    resumeAfterWake: conditions[1],
                    environmentReady: conditions[2],
                    sessionReady: conditions[3],
                    pluginsValidated: conditions[4]
                ),
                .remainStopped
            )
        }
    }

    func testWakeDefaultIsFailClosed() {
        XCTAssertFalse(SettingsDocument.defaults.resumeAfterWake)
        XCTAssertEqual(
            WakeRecoveryPolicy.decide(
                wasRoutingBeforeSleep: true,
                resumeAfterWake: SettingsDocument.defaults.resumeAfterWake,
                environmentReady: true,
                sessionReady: true,
                pluginsValidated: true
            ),
            .remainStopped
        )
    }

    func testFormatResetIsAttemptedOnlyOnceForSupportedConfiguration() {
        XCTAssertEqual(
            DeviceResetPolicy.decide(
                issue: .unsupportedSampleRate,
                resetAlreadyAttempted: false,
                configuredBufferFrames: 256
            ),
            .attemptOnce
        )
        XCTAssertEqual(
            DeviceResetPolicy.decide(
                issue: .unsupportedBufferSize,
                resetAlreadyAttempted: false,
                configuredBufferFrames: 512
            ),
            .attemptOnce
        )
        XCTAssertEqual(
            DeviceResetPolicy.decide(
                issue: .unsupportedBufferSize,
                resetAlreadyAttempted: false,
                configuredBufferFrames: 64
            ),
            .remainStopped
        )
        XCTAssertEqual(
            DeviceResetPolicy.decide(
                issue: .unsupportedSampleRate,
                resetAlreadyAttempted: true,
                configuredBufferFrames: 256
            ),
            .remainStopped
        )
    }

    func testDeviceLossNeverUsesResetFallback() {
        for issue in [
            BlockingIssue.inputDeviceMissing,
            .outputDeviceMissing,
            .aggregateDeviceCreationFailed,
            .engineStartFailed,
            .unexpectedEngineState,
        ] {
            XCTAssertEqual(
                DeviceResetPolicy.decide(
                    issue: issue,
                    resetAlreadyAttempted: false,
                    configuredBufferFrames: 256
                ),
                .remainStopped
            )
        }
    }

    func testDisconnectAndSleepEventsFailClosedAcrossInFlightStates() throws {
        let activeStates: [ApplicationState] = [
            .starting, .running, .muted, .stopping, .recovering,
        ]
        for state in activeStates {
            XCTAssertEqual(
                try ApplicationStateReducer.reduce(state, .inputDeviceRemoved),
                .blocked(.inputDeviceMissing)
            )
            XCTAssertEqual(
                try ApplicationStateReducer.reduce(state, .blackHoleRemoved),
                .needsBlackHole
            )
        }
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.running, .sleep),
            .stopping
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.recovering, .sleep),
            .recovering
        )
    }
}
