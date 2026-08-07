// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Darwin
import Foundation
import XCTest

final class PluginCatalogStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shitate-catalog-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testAtomicRoundTripUsesOwnerOnlyPermissions() throws {
        let store = PluginCatalogStore(
            fileURL: temporaryDirectory.appendingPathComponent("plugin-catalog.json")
        )
        let document = PluginCatalogDocument(entries: [validEntry()])

        try store.save(document)

        XCTAssertEqual(try store.load(), document)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        let temporaryFiles = try FileManager.default.contentsOfDirectory(
            atPath: temporaryDirectory.path
        ).filter { $0.contains(".tmp-") }
        XCTAssertTrue(temporaryFiles.isEmpty)
    }

    func testMissingCatalogLoadsAsEmptySchemaOneDocument() throws {
        let store = PluginCatalogStore(
            fileURL: temporaryDirectory.appendingPathComponent("missing.json")
        )
        XCTAssertEqual(try store.load(), PluginCatalogDocument())
    }

    func testCorruptJSONFailsClosed() throws {
        let url = temporaryDirectory.appendingPathComponent("plugin-catalog.json")
        try Data("{".utf8).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)

        XCTAssertThrowsError(try PluginCatalogStore(fileURL: url).load()) { error in
            XCTAssertEqual(error as? PluginCatalogStoreError, .invalidJSON)
        }
    }

    func testLoadRejectsSymlinkAndFIFOBeforeReading() throws {
        let target = temporaryDirectory.appendingPathComponent("target.json")
        try JSONEncoder().encode(PluginCatalogDocument()).write(to: target)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        let symlink = temporaryDirectory.appendingPathComponent("symlink.json")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        XCTAssertThrowsError(try PluginCatalogStore(fileURL: symlink).load()) { error in
            XCTAssertEqual(error as? PluginCatalogStoreError, .unsafeFile)
        }

        let fifo = temporaryDirectory.appendingPathComponent("catalog.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try PluginCatalogStore(fileURL: fifo).load()) { error in
            XCTAssertEqual(error as? PluginCatalogStoreError, .unsafeFile)
        }
    }

    func testFutureSchemaAndProtocolFailClosed() {
        let store = PluginCatalogStore(
            fileURL: temporaryDirectory.appendingPathComponent("plugin-catalog.json")
        )
        XCTAssertThrowsError(
            try store.save(PluginCatalogDocument(schemaVersion: 2))
        ) { error in
            XCTAssertEqual(error as? PluginCatalogStoreError, .unsupportedSchema(2))
        }
        XCTAssertThrowsError(
            try store.save(PluginCatalogDocument(scannerProtocolVersion: 2))
        ) { error in
            XCTAssertEqual(
                error as? PluginCatalogStoreError,
                .unsupportedScannerProtocol(2)
            )
        }
    }

    func testDuplicateFingerprintFailsWithoutReplacingExistingCatalog() throws {
        let store = PluginCatalogStore(
            fileURL: temporaryDirectory.appendingPathComponent("plugin-catalog.json")
        )
        let original = PluginCatalogDocument(entries: [validEntry()])
        try store.save(original)

        XCTAssertThrowsError(
            try store.save(PluginCatalogDocument(entries: [validEntry(), validEntry()]))
        ) { error in
            XCTAssertEqual(
                error as? PluginCatalogStoreError,
                .duplicateFingerprint(validEntry().fingerprint)
            )
        }
        XCTAssertEqual(try store.load(), original)
    }

    func testFingerprintMustMatchEveryPersistedIdentityField() {
        let store = PluginCatalogStore(
            fileURL: temporaryDirectory.appendingPathComponent("plugin-catalog.json")
        )
        XCTAssertThrowsError(
            try store.save(
                PluginCatalogDocument(
                    entries: [validEntry(fingerprint: String(repeating: "a", count: 64))]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? PluginCatalogStoreError,
                .invalidEntry(String(repeating: "a", count: 64))
            )
        }
    }

    func testSaveRejectsEntryForDifferentAppVersion() {
        let store = PluginCatalogStore(
            fileURL: temporaryDirectory.appendingPathComponent("plugin-catalog.json")
        )
        let entry = validEntry(compatibleAppVersion: "0.2")

        XCTAssertThrowsError(
            try store.save(PluginCatalogDocument(entries: [entry]))
        ) { error in
            XCTAssertEqual(
                error as? PluginCatalogStoreError,
                .invalidEntry(entry.fingerprint)
            )
        }
    }

    func testLoadAcceptsStructurallyValidEntryForOlderAppVersion() throws {
        let url = temporaryDirectory.appendingPathComponent("plugin-catalog.json")
        let document = PluginCatalogDocument(
            entries: [validEntry(compatibleAppVersion: "0.0")]
        )
        try JSONEncoder().encode(document).write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)

        XCTAssertEqual(try PluginCatalogStore(fileURL: url).load(), document)
    }

    func testEntriesCannotExceedScannerProtocolValueDomains() {
        let store = PluginCatalogStore(
            fileURL: temporaryDirectory.appendingPathComponent("plugin-catalog.json")
        )
        let invalidEntries = [
            validEntry(name: String(repeating: "é", count: 257)),
            validEntry(inputChannels: 65),
            validEntry(latencySamples: 10_000_001),
            validEntry(architectures: ["arm64", "mips"]),
        ]

        for entry in invalidEntries {
            XCTAssertThrowsError(
                try store.save(PluginCatalogDocument(entries: [entry]))
            ) { error in
                XCTAssertEqual(
                    error as? PluginCatalogStoreError,
                    .invalidEntry(entry.fingerprint)
                )
            }
        }
    }

    private func validEntry(
        fingerprint: String? = nil,
        compatibleAppVersion: String = PluginCatalogDocument.currentCompatibleAppVersion,
        name: String = "Gain",
        inputChannels: Int = 2,
        latencySamples: Int = 0,
        architectures: [String] = ["arm64"]
    ) -> PluginCatalogEntry {
        let bundlePath = "/Library/Audio/Plug-Ins/VST3/Gain.vst3"
        let classUID = "1234abcd1234abcd1234abcd1234abcd"
        let codeDirectoryHash = String(repeating: "b", count: 40)
        return PluginCatalogEntry(
            fingerprint: fingerprint
                ?? PluginCatalogFingerprint.make(
                    bundlePath: bundlePath,
                    classUID: classUID,
                    codeDirectoryHash: codeDirectoryHash,
                    architecture: "arm64"
                )!,
            bundlePath: bundlePath,
            classUID: classUID,
            name: name,
            manufacturer: "Shi-tate Tests",
            version: "1.0.0",
            codeDirectoryHash: codeDirectoryHash,
            teamIdentifier: "TEAMID",
            signatureKind: .developerID,
            architectures: architectures,
            inputChannels: inputChannels,
            outputChannels: 2,
            latencySamples: latencySamples,
            hasEditor: false,
            compatibility: .compatible,
            reason: nil,
            bundleModificationTime: 100,
            scannerProtocol: 1,
            compatibleAppVersion: compatibleAppVersion,
            lastScannedAt: "2026-08-07T00:00:00Z"
        )
    }
}
