// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import XCTest

final class AudioEnvironmentTests: XCTestCase {
    private func blackHole(uid: String) -> AudioDevice {
        AudioDevice(
            id: uid,
            displayName: "BlackHole 2ch",
            outputChannelNames: ["Left", "Right"]
        )
    }

    func testBlackHoleMissingPresentAndReplacedUID() {
        XCTAssertEqual(
            AudioEnvironment.blackHoleAvailability(outputDevices: [], savedUID: nil),
            .missing
        )
        XCTAssertEqual(
            AudioEnvironment.blackHoleAvailability(
                outputDevices: [blackHole(uid: "blackhole-a")],
                savedUID: nil
            ),
            .available(uid: "blackhole-a")
        )
        XCTAssertEqual(
            AudioEnvironment.blackHoleAvailability(
                outputDevices: [blackHole(uid: "blackhole-a")],
                savedUID: "blackhole-a"
            ),
            .available(uid: "blackhole-a")
        )
        XCTAssertEqual(
            AudioEnvironment.blackHoleAvailability(
                outputDevices: [blackHole(uid: "blackhole-b")],
                savedUID: "blackhole-a"
            ),
            .identityChanged
        )
    }

    func testBlackHoleDetectionNeverFallsBackByDisplaySimilarity() {
        let speaker = AudioDevice(
            id: "speaker",
            displayName: "BlackHole 2ch Backup",
            outputChannelNames: ["Left", "Right"]
        )
        XCTAssertEqual(
            AudioEnvironment.blackHoleAvailability(outputDevices: [speaker], savedUID: nil),
            .missing
        )
    }

    func testDuplicateUnsavedBlackHoleDevicesRequireExplicitResolution() {
        XCTAssertEqual(
            AudioEnvironment.blackHoleAvailability(
                outputDevices: [blackHole(uid: "a"), blackHole(uid: "b")],
                savedUID: nil
            ),
            .ambiguous
        )
    }

    func testBufferPreferenceIsDeterministic() {
        let input = AudioDevice(
            id: "input",
            displayName: "Microphone",
            inputChannelNames: ["Mic"],
            allowedBufferFrames: [128, 256, 512]
        )
        let output = blackHole(uid: "output")
        XCTAssertEqual(AudioEnvironment.preferredBuffer(input: input, output: output), 256)
    }
}
