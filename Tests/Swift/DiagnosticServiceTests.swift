// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Darwin
import XCTest

final class DiagnosticServiceTests: XCTestCase {
    func testRedactorRemovesHomeUIDControlsAndForbiddenPayloadMarkers() {
        let redactor = DiagnosticRedactor(homePath: "/Users/private-person")
        let uid = "CoreAudio-raw-uid-123"
        let value =
            "/Users/private-person/file\u{0} \(uid) plugin state audio samples clipboard meeting app"

        let redacted = redactor.redact(value, knownUIDs: [uid])

        XCTAssertFalse(redacted.contains("/Users/private-person"))
        XCTAssertFalse(redacted.contains(uid))
        XCTAssertFalse(redacted.contains("\u{0}"))
        XCTAssertFalse(redacted.localizedCaseInsensitiveContains("plugin state"))
        XCTAssertFalse(redacted.localizedCaseInsensitiveContains("audio samples"))
        XCTAssertFalse(redacted.localizedCaseInsensitiveContains("clipboard"))
        XCTAssertTrue(redacted.contains("~"))
        XCTAssertTrue(redacted.contains("uidHash="))
        XCTAssertLessThanOrEqual(redacted.utf8.count, DiagnosticRedactor.maximumTextBytes)
    }

    func testUIDHashIsStableScopedAndDoesNotRevealRawUID() {
        let redactor = DiagnosticRedactor(homePath: "/tmp/home")
        let first = redactor.uidHash("device-one")
        XCTAssertEqual(first, redactor.uidHash("device-one"))
        XCTAssertNotEqual(first, redactor.uidHash("device-two"))
        XCTAssertFalse(first.contains("device-one"))
        XCTAssertEqual(first.count, 16)
    }

    func testReportIsBoundedStructuredAndContainsNoForbiddenRawValues() {
        let home = "/Users/private-person"
        let inputUID = "input-private-uid"
        let outputUID = "output-private-uid"
        let report = DiagnosticsReportBuilder.build(
            DiagnosticsSnapshot(
                appVersion: "0.1.0",
                commit: String(repeating: "a", count: 40),
                operatingSystem: "macOS test",
                architecture: "arm64",
                juceVersion: "9.0.0",
                state: "Stopped",
                inputName: "\(home)/Studio Mic",
                inputUID: inputUID,
                inputChannel: 0,
                outputName: "BlackHole 2ch",
                outputUID: outputUID,
                sampleRate: 48_000,
                bufferFrames: 256,
                xrunCount: 0,
                plugins: [
                    DiagnosticsPluginRecord(
                        name: "Compressor",
                        version: "1.2.3",
                        fingerprint: String(repeating: "b", count: 64),
                        status: "ok"
                    )
                ],
                lastError: "plugin state at \(home) for \(inputUID)"
            ),
            redactor: DiagnosticRedactor(homePath: home)
        )

        XCTAssertFalse(report.contains(home))
        XCTAssertFalse(report.contains(inputUID))
        XCTAssertFalse(report.contains(outputUID))
        XCTAssertFalse(report.localizedCaseInsensitiveContains("plugin state"))
        XCTAssertTrue(report.contains("fingerprint=bbbbbbbbbbbb"))
        XCTAssertFalse(report.contains(String(repeating: "b", count: 64)))
        XCTAssertLessThanOrEqual(report.utf8.count, DiagnosticsReportBuilder.maximumReportBytes)
    }

    func testLocalLogsRotateAtBoundAndRetainExactlyThreeGenerations() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let home = "/Users/private-person"
        let uid = "private-device-uid"
        let logger = LocalLogService(
            paths: fixture.paths,
            maximumFileBytes: 256,
            retainedGenerations: 3,
            redactor: DiagnosticRedactor(homePath: home),
            now: { Date(timeIntervalSince1970: 1_786_080_000) }
        )

        for index in 0..<30 {
            logger.log(
                "testEvent",
                fields: [
                    "index": "\(index)",
                    "value": "\(home) \(uid) \(String(repeating: "x", count: 80))",
                ],
                knownUIDs: [uid]
            )
        }
        logger.flush()

        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.logsDirectory.path)
        XCTAssertTrue(names.contains("shitate.log"))
        XCTAssertTrue(names.contains("shitate.log.1"))
        XCTAssertTrue(names.contains("shitate.log.2"))
        XCTAssertTrue(names.contains("shitate.log.3"))
        XCTAssertFalse(names.contains("shitate.log.4"))
        for name in names {
            let url = fixture.paths.logsDirectory.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            let text = String(decoding: data, as: UTF8.self)
            XCTAssertLessThanOrEqual(data.count, 256)
            XCTAssertFalse(text.contains(home))
            XCTAssertFalse(text.contains(uid))
            XCTAssertEqual(try permissions(url), 0o600)
        }
    }

    private func permissions(_ url: URL) throws -> mode_t {
        var status = stat()
        XCTAssertEqual(url.path.withCString { Darwin.lstat($0, &status) }, 0)
        return status.st_mode & 0o777
    }
}

private struct Fixture {
    let root: URL
    let paths: ApplicationPaths

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shitate-diagnostics-tests-\(UUID().uuidString)",
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
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
