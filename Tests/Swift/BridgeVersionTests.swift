// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Foundation
import XCTest

final class BridgeVersionTests: XCTestCase {
    func testBridgeReturnsDisplayVersion() {
        let bridge = STAudioEngineBridge()
        XCTAssertEqual(bridge.displayVersion, "0.1.0-dev")
        XCTAssertNotNil(bridge.audioDevices())
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
