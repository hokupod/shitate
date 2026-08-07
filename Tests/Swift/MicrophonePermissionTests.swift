// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import XCTest

@MainActor
private final class MockMicrophonePermissionProvider: MicrophonePermissionProviding {
    var status: MicrophonePermissionStatus
    var grantsRequest = false
    var requestCount = 0
    var settingsOpenCount = 0

    init(status: MicrophonePermissionStatus) {
        self.status = status
    }

    func requestAccess() async -> Bool {
        requestCount += 1
        status = grantsRequest ? .authorized : .denied
        return grantsRequest
    }

    func openSystemSettings() {
        settingsOpenCount += 1
    }
}

@MainActor
final class MicrophonePermissionTests: XCTestCase {
    func testUndeterminedPermissionChangesOnlyAfterExplicitRequest() async {
        let provider = MockMicrophonePermissionProvider(status: .undetermined)
        provider.grantsRequest = true
        let flow = MicrophonePermissionFlow(provider: provider)

        XCTAssertEqual(flow.status, .undetermined)
        XCTAssertEqual(provider.requestCount, 0)
        let result = await flow.request()
        XCTAssertEqual(result, .authorized)
        XCTAssertEqual(provider.requestCount, 1)
    }

    func testDeniedPermissionDoesNotPromptAgainAutomatically() async {
        let provider = MockMicrophonePermissionProvider(status: .denied)
        let flow = MicrophonePermissionFlow(provider: provider)

        let result = await flow.request()
        XCTAssertEqual(result, .denied)
        XCTAssertEqual(provider.requestCount, 0)
        flow.openSystemSettings()
        XCTAssertEqual(provider.settingsOpenCount, 1)
    }

    func testAuthorizedPermissionDoesNotPrompt() async {
        let provider = MockMicrophonePermissionProvider(status: .authorized)
        let flow = MicrophonePermissionFlow(provider: provider)

        let result = await flow.request()
        XCTAssertEqual(result, .authorized)
        XCTAssertEqual(provider.requestCount, 0)
    }
}
