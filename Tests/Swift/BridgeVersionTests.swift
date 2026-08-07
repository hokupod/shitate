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
}
