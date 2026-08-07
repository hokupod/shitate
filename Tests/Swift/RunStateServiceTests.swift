// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Darwin
import XCTest

@MainActor
final class RunStateServiceTests: XCTestCase {
    func testCleanShutdownDoesNotEnterSafeMode() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        var now = date(0)
        var uptime: TimeInterval = 100
        let first = fixture.service(now: { now }, uptime: { uptime })
        XCTAssertFalse(try first.beginRun().entersSafeMode)
        now = date(8)
        uptime = 108
        try first.markClean(routingWasActive: false)

        now = date(20)
        let second = fixture.service(now: { now }, uptime: { 200 })
        let decision = try second.beginRun()
        XCTAssertFalse(decision.entersSafeMode)
        XCTAssertEqual(decision.history.last?.durationSeconds, 8)
        XCTAssertEqual(decision.history.last?.abnormalExit, false)
    }

    func testDirtyShutdownAndInterruptedLoadEnterSafeMode() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fingerprint = String(repeating: "a", count: 64)

        var now = date(0)
        let first = fixture.service(now: { now }, uptime: { 10 })
        _ = try first.beginRun()
        try first.recordOperation(
            "loadingPlugin",
            loadingPlugin: LoadingPluginDocument(
                slotID: UUID(),
                pluginFingerprint: fingerprint,
                pluginName: "Crash Test"
            )
        )

        now = date(5)
        let second = fixture.service(now: { now }, uptime: { 20 })
        let decision = try second.beginRun()
        XCTAssertEqual(decision.safeModeReason, .pluginLoadInterrupted("Crash Test"))
        XCTAssertEqual(decision.suspectPlugin?.pluginFingerprint, fingerprint)
        XCTAssertEqual(decision.history.last?.lastOperation, "loadingPlugin")
    }

    func testThreeRepeatedPluginCrashesBlockExactFingerprint() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fingerprint = String(repeating: "b", count: 64)
        var now = date(0)

        for index in 0..<3 {
            let service = fixture.service(now: { now }, uptime: { TimeInterval(index * 10) })
            _ = try service.beginRun()
            try service.recordOperation(
                "loadingPlugin",
                loadingPlugin: LoadingPluginDocument(
                    slotID: UUID(),
                    pluginFingerprint: fingerprint,
                    pluginName: "Repeated Crash"
                )
            )
            now = date(TimeInterval((index + 1) * 5))
        }

        let fourth = fixture.service(now: { now }, uptime: { 50 })
        let decision = try fourth.beginRun()
        XCTAssertEqual(decision.safeModeReason, .repeatedPluginCrash("Repeated Crash"))
        XCTAssertEqual(decision.blockedFingerprints, [fingerprint])
        XCTAssertEqual(
            try fixture.auxiliaryStore.loadBlockedPlugins().fingerprints,
            [fingerprint]
        )
    }

    func testChangedFingerprintTriggersRapidLoopWithoutBlocking() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var now = date(0)
        let digits = Array("abcdef")

        for index in 0..<3 {
            let service = fixture.service(now: { now }, uptime: { TimeInterval(index) })
            _ = try service.beginRun()
            try service.recordOperation(
                "loadingPlugin",
                loadingPlugin: LoadingPluginDocument(
                    slotID: UUID(),
                    pluginFingerprint: String(repeating: digits[index], count: 64),
                    pluginName: "Changing Plug-in"
                )
            )
            now = date(TimeInterval((index + 1) * 5))
        }

        let decision = try fixture.service(now: { now }, uptime: { 40 }).beginRun()
        XCTAssertEqual(decision.safeModeReason, .rapidCrashLoop)
        XCTAssertTrue(decision.blockedFingerprints.isEmpty)
    }

    func testSlowDirtyRunsDoNotBecomeRapidCrashLoop() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var now = date(0)

        for index in 0..<3 {
            let service = fixture.service(now: { now }, uptime: { TimeInterval(index) })
            _ = try service.beginRun()
            now = now.addingTimeInterval(45)
        }

        let decision = try fixture.service(now: { now }, uptime: { 200 }).beginRun()
        XCTAssertEqual(decision.safeModeReason, .previousRunUnclean)
        XCTAssertTrue(decision.history.suffix(3).allSatisfy { $0.durationSeconds == 45 })
    }

    func testClockReversalFailsSafeAndRetainsEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var now = date(100)
        let first = fixture.service(now: { now }, uptime: { 10 })
        _ = try first.beginRun()
        try first.recordOperation("scan")

        now = date(50)
        let decision = try fixture.service(now: { now }, uptime: { 20 }).beginRun()
        XCTAssertEqual(decision.safeModeReason, .clockReversal)
        XCTAssertEqual(decision.history.last?.clockReversed, true)
        XCTAssertEqual(decision.history.last?.durationSeconds, 0)
    }

    func testFutureSchemaFailsSafeBeforeReplacingCurrentRunState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try SecureDirectory.prepare(fixture.paths.applicationSupportDirectory)
        let future = Data("{\"schemaVersion\":999}".utf8)
        try AtomicFileWriter.write(future, to: fixture.paths.runStateURL)

        let decision = try fixture.service(now: { Self.date(0) }, uptime: { 1 }).beginRun()
        XCTAssertEqual(decision.safeModeReason, .runStateInvalid)
        XCTAssertEqual(
            try PersistenceCoding.schemaVersion(
                in: XCTUnwrap(
                    try SecureFileReader.read(
                        fixture.paths.runStateURL,
                        maximumBytes: RunStateStore.maximumFileBytes
                    )
                )
            ),
            RunStateDocument.currentSchemaVersion
        )
    }

    func testInvalidBlockedPluginStateFailsClosedUntilExplicitRepair() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try SecureDirectory.prepare(fixture.paths.applicationSupportDirectory)
        try AtomicFileWriter.write(
            Data("{\"schemaVersion\":999,\"fingerprints\":[\"lost\"]}".utf8),
            to: fixture.paths.blockedPluginsURL
        )

        var now = date(0)
        var uptime: TimeInterval = 10
        let service = fixture.service(now: { now }, uptime: { uptime })
        let decision = try service.beginRun()
        XCTAssertEqual(decision.safeModeReason, .runStateInvalid)
        XCTAssertTrue(decision.blockedPluginStateInvalid)
        XCTAssertTrue(decision.blockedFingerprints.isEmpty)
        XCTAssertThrowsError(try service.setBlocked([])) { error in
            XCTAssertEqual(error as? RunStateServiceError, .blockedPluginStateInvalid)
        }

        let quarantine = try XCTUnwrap(service.repairBlockedPluginState())
        XCTAssertFalse(service.blockedPluginStateInvalid)
        XCTAssertEqual(try permissions(quarantine), 0o600)
        XCTAssertEqual(try fixture.auxiliaryStore.loadBlockedPlugins(), .empty)

        now = date(5)
        uptime = 15
        try service.markClean(routingWasActive: false)
        now = date(10)
        let next = try fixture.service(now: { now }, uptime: { 20 }).beginRun()
        XCTAssertFalse(next.blockedPluginStateInvalid)
        XCTAssertFalse(next.entersSafeMode)
    }

    func testMalformedBlockedPluginStateCannotBeSilentlyOverwritten() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try SecureDirectory.prepare(fixture.paths.applicationSupportDirectory)
        try AtomicFileWriter.write(
            Data("not-json".utf8),
            to: fixture.paths.blockedPluginsURL
        )

        let service = fixture.service(now: { Self.date(0) }, uptime: { 1 })
        let decision = try service.beginRun()
        XCTAssertTrue(decision.blockedPluginStateInvalid)
        XCTAssertThrowsError(try service.setBlocked([String(repeating: "a", count: 64)]))
        XCTAssertEqual(
            try String(
                decoding: XCTUnwrap(
                    SecureFileReader.read(
                        fixture.paths.blockedPluginsURL,
                        maximumBytes: AuxiliaryPersistenceStore.maximumFileBytes
                    )
                ),
                as: UTF8.self
            ),
            "not-json"
        )
    }

    func testAtomicWriteFailurePreventsRunStart() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let failingStore = RunStateStore(paths: fixture.paths) { _, _ in
            throw TestFailure.injected
        }
        let service = RunStateService(
            paths: fixture.paths,
            store: failingStore,
            auxiliaryStore: fixture.auxiliaryStore,
            now: { Self.date(0) },
            uptime: { 1 }
        )

        XCTAssertThrowsError(try service.beginRun())
        XCTAssertNil(service.currentState)
    }

    private static func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_786_080_000 + offset)
    }

    private func date(_ offset: TimeInterval) -> Date {
        Self.date(offset)
    }

    private func permissions(_ url: URL) throws -> mode_t {
        var status = stat()
        XCTAssertEqual(url.path.withCString { Darwin.lstat($0, &status) }, 0)
        return status.st_mode & 0o777
    }
}

private enum TestFailure: Error {
    case injected
}

private struct Fixture {
    let root: URL
    let paths: ApplicationPaths
    let auxiliaryStore: AuxiliaryPersistenceStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shitate-run-state-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        paths = ApplicationPaths(
            applicationSupportDirectory: root.appendingPathComponent("support", isDirectory: true),
            logsDirectory: root.appendingPathComponent("logs", isDirectory: true)
        )
        auxiliaryStore = AuxiliaryPersistenceStore(paths: paths)
    }

    @MainActor
    func service(
        now: @escaping () -> Date,
        uptime: @escaping () -> TimeInterval
    ) -> RunStateService {
        RunStateService(
            paths: paths,
            auxiliaryStore: auxiliaryStore,
            now: now,
            uptime: uptime
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
