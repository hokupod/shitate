// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import XCTest

final class ApplicationStateTests: XCTestCase {
    func testEnvironmentTransitionsCoverPhaseOneRequirements() throws {
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.booting, .beginEnvironmentCheck),
            .checkingEnvironment
        )
        for (readiness, expected) in environmentCases {
            XCTAssertEqual(
                try ApplicationStateReducer.reduce(
                    .checkingEnvironment,
                    .environmentChecked(readiness)
                ),
                expected
            )
        }
    }

    func testStartStopAndMuteTransitionsAreIdempotent() throws {
        let starting = try ApplicationStateReducer.reduce(.readyStopped, .startRequested)
        XCTAssertEqual(starting, .starting)
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(starting, .startRequested),
            .starting
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(starting, .engineConfigured),
            .starting
        )

        let running = try ApplicationStateReducer.reduce(starting, .engineStarted)
        XCTAssertEqual(running, .running)
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(running, .engineStarted),
            .running
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(running, .muteChanged(true)),
            .muted
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.muted, .muteChanged(true)),
            .muted
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.muted, .muteChanged(false)),
            .running
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.muted, .engineStarted),
            .muted
        )

        let stopping = try ApplicationStateReducer.reduce(running, .stopRequested)
        XCTAssertEqual(stopping, .stopping)
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(stopping, .stopRequested),
            .stopping
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(stopping, .engineStopped),
            .readyStopped
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.readyStopped, .stopRequested),
            .readyStopped
        )
    }

    func testInvalidatingEventsNeverSelectFallbackState() throws {
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.running, .inputDeviceRemoved),
            .blocked(.inputDeviceMissing)
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.running, .blackHoleRemoved),
            .needsBlackHole
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.running, .microphonePermissionLost),
            .needsMicrophonePermission
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.muted, .sleep),
            .stopping
        )
    }

    func testUnexpectedStopFailsClosed() throws {
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.running, .engineStopped),
            .blocked(.unexpectedEngineState)
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.starting, .engineStopped),
            .blocked(.unexpectedEngineState)
        )
    }

    func testStaleCompletionIsTypedAndLeavesStateToCaller() {
        assertTransitionError(
            .staleCompletion(state: .readyStopped, event: .engineStarted),
            state: .readyStopped,
            event: .engineStarted
        )
        assertTransitionError(
            .staleCompletion(
                state: .needsBlackHole,
                event: .environmentChecked(.ready)
            ),
            state: .needsBlackHole,
            event: .environmentChecked(.ready)
        )
    }

    func testImpossibleTransitionIsTyped() {
        assertTransitionError(
            .invalid(state: .needsBlackHole, event: .startRequested),
            state: .needsBlackHole,
            event: .startRequested
        )
        assertTransitionError(
            .invalid(state: .readyStopped, event: .muteChanged(true)),
            state: .readyStopped,
            event: .muteChanged(true)
        )
    }

    func testEveryStateEventPairReturnsAStateOrTypedError() {
        for state in representativeStates {
            for event in representativeEvents {
                do {
                    _ = try ApplicationStateReducer.reduce(state, event)
                } catch is ApplicationTransitionError {
                    continue
                } catch {
                    XCTFail("Unexpected error for \(state), \(event): \(error)")
                }
            }
        }
    }

    func testGenericBlockedStatusPreservesSpecificRecoveryGuidance() throws {
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.needsBlackHole, .engineBlocked),
            .needsBlackHole
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.needsMicrophonePermission, .engineBlocked),
            .needsMicrophonePermission
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(
                .blocked(.inputDeviceMissing),
                .engineBlocked
            ),
            .blocked(.inputDeviceMissing)
        )
        XCTAssertEqual(
            try ApplicationStateReducer.reduce(.running, .engineBlocked),
            .blocked(.engineStartFailed)
        )
    }

    private var environmentCases: [(EnvironmentReadiness, ApplicationState)] {
        [
            (.blackHoleMissing, .needsBlackHole),
            (.microphonePermissionMissing, .needsMicrophonePermission),
            (.audioConfigurationMissing, .needsAudioConfiguration),
            (.ready, .readyStopped),
        ]
    }

    private var representativeStates: [ApplicationState] {
        [
            .booting,
            .safeMode(.previousRunUnclean),
            .checkingEnvironment,
            .needsBlackHole,
            .needsMicrophonePermission,
            .needsAudioConfiguration,
            .readyStopped,
            .starting,
            .running,
            .muted,
            .stopping,
            .recovering,
            .blocked(.engineStartFailed),
            .fatal(.bridge("test")),
        ]
    }

    private var representativeEvents: [ApplicationEvent] {
        [
            .beginEnvironmentCheck,
            .environmentChecked(.ready),
            .audioConfigurationInvalid,
            .startRequested,
            .engineConfigured,
            .engineStarted,
            .engineBlocked,
            .engineFailed(.engineStartFailed),
            .stopRequested,
            .engineStopped,
            .muteChanged(true),
            .muteChanged(false),
            .inputDeviceRemoved,
            .blackHoleRemoved,
            .microphonePermissionLost,
            .sleep,
            .recoveryStarted,
            .recoveryCompleted,
            .fatal(.bridge("test")),
        ]
    }

    private func assertTransitionError(
        _ expected: ApplicationTransitionError,
        state: ApplicationState,
        event: ApplicationEvent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ApplicationStateReducer.reduce(state, event),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? ApplicationTransitionError, expected, file: file, line: line)
        }
    }
}
