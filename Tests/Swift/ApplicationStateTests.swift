// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import XCTest

final class ApplicationStateTests: XCTestCase {
    func testEnvironmentTransitionsCoverPhaseOneRequirements() {
        XCTAssertEqual(
            ApplicationStateReducer.reduce(.booting, .beginEnvironmentCheck),
            .checkingEnvironment
        )
        XCTAssertEqual(
            ApplicationStateReducer.reduce(
                .checkingEnvironment,
                .environmentChecked(.blackHoleMissing)
            ),
            .needsBlackHole
        )
        XCTAssertEqual(
            ApplicationStateReducer.reduce(
                .checkingEnvironment,
                .environmentChecked(.microphonePermissionMissing)
            ),
            .needsMicrophonePermission
        )
        XCTAssertEqual(
            ApplicationStateReducer.reduce(
                .checkingEnvironment,
                .environmentChecked(.audioConfigurationMissing)
            ),
            .needsAudioConfiguration
        )
        XCTAssertEqual(
            ApplicationStateReducer.reduce(.checkingEnvironment, .environmentChecked(.ready)),
            .readyStopped
        )
    }

    func testStartStopAndMuteTransitionsAreIdempotent() {
        let starting = ApplicationStateReducer.reduce(.readyStopped, .startRequested)
        XCTAssertEqual(starting, .starting)
        XCTAssertEqual(ApplicationStateReducer.reduce(starting, .startRequested), .starting)
        XCTAssertEqual(ApplicationStateReducer.reduce(starting, .engineConfigured), .starting)

        let running = ApplicationStateReducer.reduce(starting, .engineStarted)
        XCTAssertEqual(running, .running)
        XCTAssertEqual(ApplicationStateReducer.reduce(running, .engineStarted), .running)
        XCTAssertEqual(ApplicationStateReducer.reduce(running, .muteChanged(true)), .muted)
        XCTAssertEqual(ApplicationStateReducer.reduce(starting, .muteChanged(true)), .muted)
        XCTAssertEqual(ApplicationStateReducer.reduce(.muted, .muteChanged(true)), .muted)
        XCTAssertEqual(ApplicationStateReducer.reduce(.muted, .muteChanged(false)), .running)
        XCTAssertEqual(ApplicationStateReducer.reduce(.muted, .engineStarted), .running)

        let stopping = ApplicationStateReducer.reduce(running, .stopRequested)
        XCTAssertEqual(stopping, .stopping)
        XCTAssertEqual(ApplicationStateReducer.reduce(stopping, .stopRequested), .stopping)
        XCTAssertEqual(
            ApplicationStateReducer.reduce(stopping, .engineStopped),
            .readyStopped
        )
        XCTAssertEqual(
            ApplicationStateReducer.reduce(stopping, .engineConfigured),
            .readyStopped
        )
        XCTAssertEqual(
            ApplicationStateReducer.reduce(.readyStopped, .stopRequested),
            .readyStopped
        )
    }

    func testInvalidatingEventsNeverSelectFallbackState() {
        XCTAssertEqual(
            ApplicationStateReducer.reduce(.running, .inputDeviceRemoved),
            .blocked(.inputDeviceMissing)
        )
        XCTAssertEqual(
            ApplicationStateReducer.reduce(.running, .blackHoleRemoved),
            .needsBlackHole
        )
        XCTAssertEqual(
            ApplicationStateReducer.reduce(.running, .microphonePermissionLost),
            .needsMicrophonePermission
        )
        XCTAssertEqual(ApplicationStateReducer.reduce(.muted, .sleep), .stopping)
    }

    func testUnexpectedCallbacksBlockRouting() {
        XCTAssertEqual(
            ApplicationStateReducer.reduce(.readyStopped, .engineStarted),
            .blocked(.unexpectedEngineState)
        )
        XCTAssertEqual(
            ApplicationStateReducer.reduce(.running, .engineStopped),
            .blocked(.unexpectedEngineState)
        )
        XCTAssertEqual(
            ApplicationStateReducer.reduce(.starting, .engineStopped),
            .blocked(.unexpectedEngineState)
        )
    }

    func testGenericBlockedStatusPreservesSpecificRecoveryGuidance() {
        XCTAssertEqual(
            ApplicationStateReducer.reduce(.needsBlackHole, .engineBlocked),
            .needsBlackHole
        )
        XCTAssertEqual(
            ApplicationStateReducer.reduce(.needsMicrophonePermission, .engineBlocked),
            .needsMicrophonePermission
        )
        XCTAssertEqual(
            ApplicationStateReducer.reduce(.blocked(.inputDeviceMissing), .engineBlocked),
            .blocked(.inputDeviceMissing)
        )
        XCTAssertEqual(
            ApplicationStateReducer.reduce(.running, .engineBlocked),
            .blocked(.engineStartFailed)
        )
    }
}
