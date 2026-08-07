// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Foundation
import XCTest

final class BridgeVersionTests: XCTestCase {
    func testBridgeReturnsDisplayVersion() {
        let bridge = STAudioEngineBridge()
        XCTAssertEqual(bridge.displayVersion, "0.2.0-dev")
        XCTAssertNotNil(bridge.audioDevices())
        _ = bridge.defaultOutputDevice()
    }

    func testLegacyAudioDeviceInitializerRemainsAvailable() {
        let device = STAudioDeviceInfo(
            uid: "legacy-device",
            displayName: "Legacy Device",
            inputChannelNames: [],
            outputChannelNames: ["Left", "Right"],
            sampleRates: [48_000],
            allowedBufferFrames: [256],
            minimumBufferFrames: 128,
            maximumBufferFrames: 512,
            alive: true,
            aggregate: false
        )

        XCTAssertEqual(device.uid, "legacy-device")
        XCTAssertFalse(device.isPhysical)
    }

    func testBridgeMapsCppExceptionToNSError() {
        let bridge = STAudioEngineBridge()

        XCTAssertThrowsError(try bridge.exerciseExceptionForTesting()) { error in
            let error = error as NSError
            XCTAssertEqual(error.domain, STBridgeErrorDomain)
            XCTAssertEqual(error.code, STBridgeError.Code.cppException.rawValue)
            XCTAssertEqual(error.localizedDescription, "bridge exception mapping test")
        }
    }

    func testPluginBridgeExposesStandardPathsAndRejectsRelativeFolders() throws {
        let bridge = STPluginBridge()

        XCTAssertTrue(
            bridge.standardSearchPaths.contains("/Library/Audio/Plug-Ins/VST3")
        )
        XCTAssertThrowsError(try bridge.validatedAdditionalFolders(["relative/VST3"])) {
            error in
            let error = error as NSError
            XCTAssertEqual(error.domain, STBridgeErrorDomain)
            XCTAssertEqual(
                error.code,
                STBridgeError.Code.invalidPluginFolder.rawValue
            )
        }
    }

    func testRuntimeBridgeStartsEmptyAndMapsStableSlotErrors() {
        let bridge = STAudioEngineBridge()

        XCTAssertTrue(bridge.pluginSlots().isEmpty)
        XCTAssertEqual(bridge.diagnostics().pluginLatencySamples, 0)
        XCTAssertEqual(bridge.diagnostics().aggregateLatencySamples, 0)
        XCTAssertEqual(
            STBridgeError.Code.pluginMutationAppliedRestartFailed.rawValue,
            315
        )
        XCTAssertEqual(STBridgeError.Code.previewOutputUnavailable.rawValue, 111)
        XCTAssertEqual(STBridgeError.Code.previewOutputChanged.rawValue, 112)
        XCTAssertEqual(STAudioOutputTarget.systemPreview.rawValue, 1)
    }

    func testStoppedRuntimeMutationCompletesOnMainQueue() {
        let bridge = STAudioEngineBridge()
        let completion = expectation(description: "runtime mutation completion")

        bridge.removePluginSlot(with: UUID()) { error in
            XCTAssertTrue(Thread.isMainThread)
            let error = error as NSError?
            XCTAssertEqual(error?.domain, STBridgeErrorDomain)
            XCTAssertEqual(
                error?.code,
                STBridgeError.Code.pluginSlotNotFound.rawValue
            )
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
    }
}
