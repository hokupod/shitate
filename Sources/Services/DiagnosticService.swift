// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import CryptoKit
import Darwin
import Foundation

struct DiagnosticRedactor: Sendable {
    static let maximumTextBytes = 4_096

    let homePath: String

    init(homePath: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.homePath = homePath
    }

    func uidHash(_ uid: String) -> String {
        guard !uid.isEmpty else {
            return "none"
        }
        let scoped = Data("dev.hokupod.shitate/diagnostics/v1\u{0}\(uid)".utf8)
        return SHA256.hash(data: scoped).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func redact(_ value: String, knownUIDs: [String] = []) -> String {
        var result = value
        if !homePath.isEmpty {
            result = result.replacingOccurrences(of: homePath, with: "~")
        }
        for uid in knownUIDs.filter({ !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(
                of: uid,
                with: "uidHash=\(uidHash(uid))"
            )
        }
        result = result.unicodeScalars.map { scalar in
            if scalar.value == 9 || scalar.value == 10 || scalar.value >= 32 {
                return Character(String(scalar))
            }
            return "�"
        }.reduce(into: "") { $0.append($1) }

        let forbiddenMarkers = [
            "plugin state", "plugin-state", "audio sample", "audio-like", "clipboard",
            "meeting app", "communication app",
        ]
        for marker in forbiddenMarkers {
            result = result.replacingOccurrences(
                of: marker,
                with: "[redacted]",
                options: [.caseInsensitive]
            )
        }
        return boundedUTF8(result, maximumBytes: Self.maximumTextBytes)
    }

    private func boundedUTF8(_ value: String, maximumBytes: Int) -> String {
        guard value.utf8.count > maximumBytes else {
            return value
        }
        var result = ""
        for character in value {
            let next = result + String(character)
            guard next.utf8.count <= maximumBytes - 3 else {
                break
            }
            result = next
        }
        return result + "…"
    }
}

struct DiagnosticsPluginRecord: Equatable, Sendable {
    var name: String
    var version: String
    var fingerprint: String
    var status: String
}

struct DiagnosticsSnapshot: Equatable, Sendable {
    var appVersion: String
    var commit: String
    var operatingSystem: String
    var architecture: String
    var juceVersion: String
    var state: String
    var inputName: String
    var inputUID: String
    var inputChannel: Int
    var outputName: String
    var outputUID: String
    var sampleRate: Double
    var bufferFrames: Int
    var xrunCount: Int
    var plugins: [DiagnosticsPluginRecord]
    var lastError: String?
}

enum DiagnosticsReportBuilder {
    static let maximumReportBytes = 64 * 1024

    static func build(
        _ snapshot: DiagnosticsSnapshot,
        redactor: DiagnosticRedactor
    ) -> String {
        let uids = [snapshot.inputUID, snapshot.outputUID]
        var lines = [
            "Shi-tate \(redactor.redact(snapshot.appVersion)) (commit \(redactor.redact(snapshot.commit)))",
            "\(redactor.redact(snapshot.operatingSystem)) / \(redactor.redact(snapshot.architecture))",
            "JUCE \(redactor.redact(snapshot.juceVersion))",
            "State: \(redactor.redact(snapshot.state))",
            "Input: \(redactor.redact(snapshot.inputName, knownUIDs: uids)), channel \(snapshot.inputChannel + 1), uidHash=\(redactor.uidHash(snapshot.inputUID))",
            "Output: \(redactor.redact(snapshot.outputName, knownUIDs: uids)), uidHash=\(redactor.uidHash(snapshot.outputUID))",
            "Format: \(Int(snapshot.sampleRate)) Hz / \(snapshot.bufferFrames) frames",
            "XRuns: \(snapshot.xrunCount)",
            "Plugins:",
        ]
        if snapshot.plugins.isEmpty {
            lines.append("  none")
        } else {
            for (index, plugin) in snapshot.plugins.prefix(SessionDocument.maximumSlots)
                .enumerated()
            {
                let fingerprint = String(plugin.fingerprint.prefix(12))
                lines.append(
                    "  \(index + 1). \(redactor.redact(plugin.name)) \(redactor.redact(plugin.version)), fingerprint=\(fingerprint), status=\(redactor.redact(plugin.status))"
                )
            }
        }
        lines.append(
            "Last error: \(redactor.redact(snapshot.lastError ?? "none", knownUIDs: uids))"
        )
        let report = lines.joined(separator: "\n") + "\n"
        return boundedReport(report)
    }

    private static func boundedReport(_ report: String) -> String {
        guard report.utf8.count > maximumReportBytes else {
            return report
        }
        let data = Data(report.utf8.prefix(maximumReportBytes - 16))
        return (String(data: data, encoding: .utf8) ?? "") + "\n[truncated]\n"
    }
}

enum BuildMetadata {
    static var commit: String {
        Bundle.main.object(forInfoDictionaryKey: "ShitateCommit") as? String ?? "unknown"
    }

    static var architecture: String {
        #if arch(arm64)
            "arm64"
        #else
            "unsupported"
        #endif
    }
}

final class LocalLogService: @unchecked Sendable {
    static let maximumFileBytes = 5 * 1024 * 1024
    static let retainedGenerations = 3

    let currentLogURL: URL

    private let logsDirectory: URL
    private let maximumFileBytes: Int
    private let retainedGenerations: Int
    private let redactor: DiagnosticRedactor
    private let queue = DispatchQueue(label: "dev.hokupod.shitate.local-log", qos: .utility)
    private let now: @Sendable () -> Date

    init(
        paths: ApplicationPaths,
        maximumFileBytes: Int = LocalLogService.maximumFileBytes,
        retainedGenerations: Int = LocalLogService.retainedGenerations,
        redactor: DiagnosticRedactor = DiagnosticRedactor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        logsDirectory = paths.logsDirectory
        currentLogURL = paths.logsDirectory.appendingPathComponent("shitate.log")
        self.maximumFileBytes = maximumFileBytes
        self.retainedGenerations = retainedGenerations
        self.redactor = redactor
        self.now = now
    }

    func log(
        _ event: String,
        fields: [String: String] = [:],
        knownUIDs: [String] = []
    ) {
        let redactor = self.redactor
        let timestamp = ISO8601DateFormatter().string(from: now())
        let safeEvent = redactor.redact(event, knownUIDs: knownUIDs)
        let safeFields = fields.sorted(by: { $0.key < $1.key }).map { key, value in
            "\(redactor.redact(key))=\(redactor.redact(value, knownUIDs: knownUIDs))"
        }
        let line = ([timestamp, safeEvent] + safeFields).joined(separator: " ") + "\n"
        queue.async { [weak self] in
            self?.append(Data(line.utf8))
        }
    }

    func flush() {
        queue.sync {}
    }

    private func append(_ data: Data) {
        do {
            try SecureDirectory.prepare(logsDirectory)
            let bounded = Data(data.prefix(maximumFileBytes))
            let currentSize = try regularFileSize(currentLogURL)
            if currentSize + bounded.count > maximumFileBytes {
                try rotate()
            }
            try appendSecurely(bounded, to: currentLogURL)
        } catch {
            // Logging is diagnostic-only; audio safety state never depends on a log write.
        }
    }

    private func rotate() throws {
        guard retainedGenerations > 0 else {
            try unlinkIfPresent(currentLogURL)
            return
        }
        try unlinkIfPresent(generationURL(retainedGenerations))
        if retainedGenerations > 1 {
            for generation in stride(from: retainedGenerations - 1, through: 1, by: -1) {
                try renameIfPresent(
                    generationURL(generation),
                    to: generationURL(generation + 1)
                )
            }
        }
        try renameIfPresent(currentLogURL, to: generationURL(1))
    }

    private func generationURL(_ generation: Int) -> URL {
        logsDirectory.appendingPathComponent("shitate.log.\(generation)")
    }

    private func regularFileSize(_ url: URL) throws -> Int {
        var status = stat()
        let result = url.path.withCString { Darwin.lstat($0, &status) }
        if result != 0 {
            if errno == ENOENT {
                return 0
            }
            throw PersistenceStoreError.unsafeFile
        }
        guard
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_uid == getuid(),
            status.st_nlink == 1,
            (status.st_mode & 0o077) == 0
        else {
            throw PersistenceStoreError.unsafeFile
        }
        return Int(status.st_size)
    }

    private func appendSecurely(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else {
            throw PersistenceStoreError.unsafeFile
        }
        defer { _ = Darwin.close(descriptor) }
        var status = stat()
        guard
            Darwin.fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_uid == getuid(),
            status.st_nlink == 1,
            Darwin.fchmod(descriptor, mode_t(0o600)) == 0
        else {
            throw PersistenceStoreError.unsafeFile
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                return
            }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw PersistenceStoreError.unsafeFile
                }
                offset += count
            }
        }
    }

    private func unlinkIfPresent(_ url: URL) throws {
        if Darwin.unlink(url.path) != 0, errno != ENOENT {
            throw PersistenceStoreError.unsafeFile
        }
    }

    private func renameIfPresent(_ source: URL, to destination: URL) throws {
        if Darwin.rename(source.path, destination.path) != 0, errno != ENOENT {
            throw PersistenceStoreError.unsafeFile
        }
    }
}
