// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import XCTest

final class SessionStoreTests: XCTestCase {
    func testSessionRoundTripPublishesStatesBeforeManifest() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstID = UUID()
        let secondID = UUID()
        let session = PersistedSession(
            document: makeDocument(slotIDs: [firstID, secondID]),
            pluginStates: [
                firstID: Data("first-state".utf8),
                secondID: Data("second-state".utf8),
            ]
        )
        var observed: [SessionSaveStage] = []
        let store = SessionStore(paths: fixture.paths) { observed.append($0) }

        try store.save(session)

        XCTAssertEqual(try store.load(id: "default"), session)
        XCTAssertEqual(
            observed,
            [
                .wrotePluginState(firstID),
                .wrotePluginState(secondID),
                .wroteManifest,
                .willPublish,
                .published,
                .syncedParentDirectory,
            ]
        )
        let sessionDirectory = try fixture.paths.sessionDirectory(id: "default")
        XCTAssertEqual(
            try permissions(sessionDirectory.appendingPathComponent("session.json")),
            0o600
        )
        XCTAssertEqual(
            try permissions(
                sessionDirectory.appendingPathComponent(
                    SessionSlotDocument.stateFile(for: firstID)
                )
            ),
            0o600
        )
    }

    func testFailedPublicationKeepsPreviousGenerationComplete() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let slotID = UUID()
        let original = PersistedSession(
            document: makeDocument(slotIDs: [slotID]),
            pluginStates: [slotID: Data("original".utf8)]
        )
        try SessionStore(paths: fixture.paths).save(original)

        var changedDocument = original.document
        changedDocument.updatedAt = "2026-08-07T00:01:00Z"
        let changed = PersistedSession(
            document: changedDocument,
            pluginStates: [slotID: Data("changed".utf8)]
        )
        let failingStore = SessionStore(paths: fixture.paths) { stage in
            if stage == .willPublish {
                throw InjectedSessionFailure.expected
            }
        }

        XCTAssertThrowsError(try failingStore.save(changed))
        XCTAssertEqual(try SessionStore(paths: fixture.paths).load(id: "default"), original)
    }

    func testSuccessfulReplacementRemovesOrphanedStateFiles() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let retainedID = UUID()
        let removedID = UUID()
        let store = SessionStore(paths: fixture.paths)
        try store.save(
            PersistedSession(
                document: makeDocument(slotIDs: [retainedID, removedID]),
                pluginStates: [
                    retainedID: Data("one".utf8),
                    removedID: Data("two".utf8),
                ]
            )
        )
        let replacement = PersistedSession(
            document: makeDocument(slotIDs: [retainedID], updatedAt: "2026-08-07T00:02:00Z"),
            pluginStates: [retainedID: Data("updated".utf8)]
        )

        try store.save(replacement)

        XCTAssertEqual(try store.load(id: "default"), replacement)
        let stateDirectory = try fixture.paths.sessionDirectory(id: "default")
            .appendingPathComponent("plugin-states", isDirectory: true)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: stateDirectory.path),
            ["\(retainedID.uuidString).bin"]
        )
    }

    func testEmptyPassthroughSessionIsValid() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let session = PersistedSession(
            document: makeDocument(slotIDs: []),
            pluginStates: [:]
        )
        let store = SessionStore(paths: fixture.paths)

        try store.save(session)

        XCTAssertEqual(try store.load(id: "default"), session)
    }

    func testSessionPathTraversalAndStateTraversalAreRejected() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = SessionStore(paths: fixture.paths)

        XCTAssertThrowsError(try store.load(id: "../outside")) { error in
            XCTAssertEqual(
                error as? PersistenceStoreError,
                .invalidIdentifier("../outside")
            )
        }

        let slotID = UUID()
        var document = makeDocument(slotIDs: [slotID])
        document.slots[0].stateFile = "../outside.bin"
        XCTAssertThrowsError(
            try store.save(
                PersistedSession(
                    document: document,
                    pluginStates: [slotID: Data()]
                )
            )
        )
    }

    func testSymlinkSessionDirectoryIsRejectedWithoutTouchingTarget() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try SecureDirectory.prepare(fixture.paths.applicationSupportDirectory)
        try SecureDirectory.prepare(fixture.paths.sessionsDirectory)
        let target = fixture.root.appendingPathComponent("target", isDirectory: true)
        try SecureDirectory.prepare(target)
        let sentinel = target.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        let sessionDirectory = try fixture.paths.sessionDirectory(id: "default")
        try FileManager.default.createSymbolicLink(
            atPath: sessionDirectory.path,
            withDestinationPath: target.path
        )

        let store = SessionStore(paths: fixture.paths)
        XCTAssertThrowsError(try store.load(id: "default"))
        XCTAssertThrowsError(
            try store.save(
                PersistedSession(
                    document: makeDocument(slotIDs: []),
                    pluginStates: [:]
                )
            )
        )
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
    }

    private func makeDocument(
        slotIDs: [UUID],
        updatedAt: String = "2026-08-07T00:00:00Z"
    ) -> SessionDocument {
        SessionDocument(
            schemaVersion: 1,
            id: "default",
            name: "Default",
            updatedAt: updatedAt,
            slots: slotIDs.enumerated().map { index, slotID in
                SessionSlotDocument(
                    slotID: slotID,
                    order: index,
                    pluginFingerprint: String(repeating: "a", count: 64),
                    bundlePath: "/Library/Audio/Plug-Ins/VST3/Test.vst3",
                    classUID: "0123456789abcdef",
                    name: "Test Plug-in",
                    manufacturer: "Shi-tate Tests",
                    version: "1.0.0",
                    bypassed: false,
                    stateFile: SessionSlotDocument.stateFile(for: slotID)
                )
            }
        )
    }

    private func makeFixture() throws -> (root: URL, paths: ApplicationPaths) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shitate-session-tests-\(UUID().uuidString)",
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

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private enum InjectedSessionFailure: Error {
    case expected
}
