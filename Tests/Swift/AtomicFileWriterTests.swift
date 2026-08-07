// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Darwin
import XCTest

final class AtomicFileWriterTests: XCTestCase {
    func testWritePublishesCompleteMode0600File() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("settings.json")
        let expected = Data("complete".utf8)

        try AtomicFileWriter.write(expected, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), expected)
        XCTAssertEqual(try permissions(destination), 0o600)
    }

    func testFailureBeforePublicationPreservesPreviousFileAndRemovesTemporaryFile() throws {
        for stage in AtomicWriteStage.allCases
        where stage != .publishedFile
            && stage != .syncedParentDirectory
        {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let destination = directory.appendingPathComponent("session.json")
            try AtomicFileWriter.write(Data("previous".utf8), to: destination)

            XCTAssertThrowsError(
                try AtomicFileWriter.write(
                    Data("replacement".utf8),
                    to: destination,
                    faultInjector: { currentStage in
                        if currentStage == stage {
                            throw InjectedFailure.expected
                        }
                    }
                ),
                "stage: \(stage)"
            )

            XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertFalse(names.contains(where: { $0.contains(".tmp-") }))
        }
    }

    func testExistingSymlinkIsRejectedWithoutTouchingTarget() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        let destination = directory.appendingPathComponent("settings.json")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            atPath: destination.path,
            withDestinationPath: target.path
        )

        XCTAssertThrowsError(
            try AtomicFileWriter.write(Data("replacement".utf8), to: destination)
        ) { error in
            XCTAssertEqual(error as? AtomicFileWriterError, .unsafeDestination)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("target".utf8))
    }

    func testSymlinkParentIsRejected() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let actual = directory.appendingPathComponent("actual", isDirectory: true)
        let linked = directory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: linked.path,
            withDestinationPath: actual.path
        )

        XCTAssertThrowsError(
            try AtomicFileWriter.write(
                Data("value".utf8),
                to: linked.appendingPathComponent("settings.json")
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: actual.appendingPathComponent("settings.json").path
            )
        )
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shitate-atomic-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private enum InjectedFailure: Error {
    case expected
}
