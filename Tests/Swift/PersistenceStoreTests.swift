// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import XCTest

final class PersistenceStoreTests: XCTestCase {
    func testSettingsRoundTripAndFailClosedDefaults() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = SettingsStore(paths: fixture.paths)

        XCTAssertEqual(try store.load(), .defaults)
        var settings = SettingsDocument.defaults
        settings.launchAtLogin = true
        settings.audio.inputDeviceUID = "input-uid"
        settings.audio.inputDeviceName = "Studio Mic"
        settings.audio.outputDeviceUID = "blackhole-uid"
        try store.save(settings)

        XCTAssertEqual(try store.load(), settings)
        XCTAssertFalse(try store.load().resumeAfterWake)
        XCTAssertEqual(try permissions(fixture.paths.settingsURL), 0o600)
    }

    func testSettingsRejectFutureSchemaAndPersistExplicitWakePreference() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try SecureDirectory.prepare(fixture.paths.applicationSupportDirectory)
        let future = Data("{\"schemaVersion\":99}".utf8)
        try AtomicFileWriter.write(future, to: fixture.paths.settingsURL)

        XCTAssertThrowsError(try SettingsStore(paths: fixture.paths).load()) { error in
            XCTAssertEqual(error as? PersistenceStoreError, .unsupportedSchema(99))
        }

        var optedIn = SettingsDocument.defaults
        optedIn.resumeAfterWake = true
        try SettingsStore(paths: fixture.paths).save(optedIn)
        XCTAssertTrue(try SettingsStore(paths: fixture.paths).load().resumeAfterWake)
    }

    func testSettingsMigrationCreatesBackupBeforePublishingV1() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeLegacySettings(
            to: fixture.paths.settingsURL, support: fixture.paths.applicationSupportDirectory)
        let store = SettingsStore(
            paths: fixture.paths,
            now: { Date(timeIntervalSince1970: 1_786_032_000) }
        )

        let migrated = try store.load()

        XCTAssertEqual(migrated.schemaVersion, 1)
        XCTAssertFalse(migrated.resumeAfterWake)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.applicationSupportDirectory.path
        )
        XCTAssertEqual(names.filter { $0.hasPrefix("settings.json.backup-") }.count, 1)
        XCTAssertEqual(try SettingsStore(paths: fixture.paths).load(), migrated)
    }

    func testFailedMigrationPreservesOriginalDocument() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try writeLegacySettings(
            to: fixture.paths.settingsURL, support: fixture.paths.applicationSupportDirectory)
        var writeCount = 0
        let store = SettingsStore(
            paths: fixture.paths,
            writer: { data, url in
                writeCount += 1
                if writeCount == 2 {
                    throw InjectedPersistenceFailure.expected
                }
                try AtomicFileWriter.write(data, to: url)
            }
        )

        XCTAssertThrowsError(try store.load())
        let original = try XCTUnwrap(
            try SecureFileReader.read(
                fixture.paths.settingsURL,
                maximumBytes: SettingsStore.maximumFileBytes
            )
        )
        XCTAssertEqual(try PersistenceCoding.schemaVersion(in: original), 0)
    }

    func testRunStateAndAuxiliaryDocumentsRoundTrip() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runStore = RunStateStore(paths: fixture.paths)
        let runState = RunStateDocument(
            schemaVersion: RunStateDocument.currentSchemaVersion,
            runID: UUID(),
            cleanShutdown: false,
            startedAt: "2026-08-07T00:00:00Z",
            updatedAt: "2026-08-07T00:00:00Z",
            endedAt: nil,
            processUptimeSeconds: 0,
            lastOperation: "launch",
            loadingPlugin: nil,
            routingWasActive: false,
            history: []
        )
        try runStore.save(runState)
        XCTAssertEqual(try runStore.load(), runState)

        let auxiliary = AuxiliaryPersistenceStore(paths: fixture.paths)
        let blocked = BlockedPluginsDocument(
            schemaVersion: 1, fingerprints: [String(repeating: "a", count: 64)])
        let folders = ScanFoldersDocument(
            schemaVersion: 1, folders: ["/Library/Audio/Plug-Ins/VST3"])
        try auxiliary.saveBlockedPlugins(blocked)
        try auxiliary.saveScanFolders(folders)
        XCTAssertEqual(try auxiliary.loadBlockedPlugins(), blocked)
        XCTAssertEqual(try auxiliary.loadScanFolders(), folders)
    }

    func testAuxiliaryDocumentsRejectDuplicatesAndTraversal() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = AuxiliaryPersistenceStore(paths: fixture.paths)
        let fingerprint = String(repeating: "a", count: 64)

        XCTAssertThrowsError(
            try store.saveBlockedPlugins(
                BlockedPluginsDocument(
                    schemaVersion: 1,
                    fingerprints: [fingerprint, fingerprint]
                )
            )
        )
        XCTAssertThrowsError(
            try store.saveScanFolders(
                ScanFoldersDocument(schemaVersion: 1, folders: ["/tmp/../etc"])
            )
        )
    }

    private func makeFixture() throws -> (root: URL, paths: ApplicationPaths) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shitate-persistence-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return (
            root,
            ApplicationPaths(
                applicationSupportDirectory: root.appendingPathComponent(
                    "support", isDirectory: true),
                logsDirectory: root.appendingPathComponent("logs", isDirectory: true)
            )
        )
    }

    private func writeLegacySettings(to url: URL, support: URL) throws {
        try SecureDirectory.prepare(support)
        let object: [String: Any] = [
            "schemaVersion": 0,
            "launchAtLogin": false,
            "startRoutingAtLaunch": false,
            "restoreLastSession": true,
            "globalMuteShortcutEnabled": true,
            "audio": [
                "mode": "automaticPrivateAggregate",
                "inputDeviceUID": "",
                "inputDeviceName": "",
                "inputChannelIndex": 0,
                "outputDeviceUID": "",
                "outputDeviceName": "BlackHole 2ch",
                "manualOutputChannelStart": 0,
                "sampleRate": 48_000,
                "bufferFrames": 256,
            ],
            "pluginPolicy": ["allowAdHocSignedPlugins": false],
            "lastSessionID": "default",
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try AtomicFileWriter.write(data, to: url)
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private enum InjectedPersistenceFailure: Error {
    case expected
}
