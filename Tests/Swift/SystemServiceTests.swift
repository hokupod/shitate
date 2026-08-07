// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import XCTest

final class SystemServiceTests: XCTestCase {
    @MainActor
    func testLaunchAtLoginUpdatesOnlyAfterBackendSuccess() {
        let state = LaunchBackendState()
        let service = LaunchAtLoginService(
            backend: LaunchAtLoginBackend(
                isEnabled: { state.enabled },
                setEnabled: { enabled in
                    if state.shouldFail {
                        throw SystemServiceTestError.expected
                    }
                    state.updateCount += 1
                    state.enabled = enabled
                }
            )
        )

        XCTAssertTrue(service.setEnabled(true))
        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(state.updateCount, 1)
        XCTAssertTrue(service.setEnabled(true))
        XCTAssertEqual(state.updateCount, 1)
        state.shouldFail = true
        XCTAssertFalse(service.setEnabled(false))
        XCTAssertTrue(service.isEnabled)
        XCTAssertNotNil(service.lastError)
    }

    @MainActor
    func testGlobalHotKeyRegistersConflictAndUnregisters() {
        let backend = FakeGlobalHotKeyBackend()
        let service = GlobalHotKeyService(backend: backend)
        var invocationCount = 0

        XCTAssertTrue(service.setEnabled(true) { invocationCount += 1 })
        XCTAssertTrue(service.isRegistered)
        backend.invoke()
        XCTAssertEqual(invocationCount, 1)

        backend.shouldFail = true
        XCTAssertFalse(service.setEnabled(true) {})
        XCTAssertFalse(service.isRegistered)
        XCTAssertNotNil(service.warning)

        service.unregister()
        XCTAssertGreaterThanOrEqual(backend.unregisterCount, 2)
    }

    func testSingleInstanceLockIsExclusiveAndReleasable() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("instance.lock")
        let first = SingleInstanceGuard(lockURL: lockURL)
        let second = SingleInstanceGuard(lockURL: lockURL)

        XCTAssertTrue(try first.acquire())
        XCTAssertFalse(try second.acquire())
        first.release()
        XCTAssertTrue(try second.acquire())
    }

    func testSingleInstanceRejectsSymlinkLock() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let lockURL = directory.appendingPathComponent("instance.lock")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: lockURL.path,
            withDestinationPath: target.path
        )

        XCTAssertThrowsError(try SingleInstanceGuard(lockURL: lockURL).acquire())
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shitate-system-service-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}

private final class LaunchBackendState {
    var enabled = false
    var shouldFail = false
    var updateCount = 0
}

@MainActor
private final class FakeGlobalHotKeyBackend: GlobalHotKeyBackend {
    var shouldFail = false
    var unregisterCount = 0
    private var action: (() -> Void)?

    func register(action: @escaping () -> Void) throws {
        if shouldFail {
            throw GlobalHotKeyError.registrationConflict(-1)
        }
        self.action = action
    }

    func unregister() {
        unregisterCount += 1
        action = nil
    }

    func invoke() {
        action?()
    }
}

private enum SystemServiceTestError: Error {
    case expected
}
