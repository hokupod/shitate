// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import CryptoKit
import Darwin
import Foundation

enum PluginCatalogSignatureKind: String, Codable, Sendable {
    case apple
    case developerID
    case adHoc
}

enum PluginCatalogCompatibility: String, Codable, Sendable {
    case compatible
    case incompatible
    case blocked
}

struct PluginCatalogEntry: Codable, Equatable, Identifiable, Sendable {
    let fingerprint: String
    let bundlePath: String
    let classUID: String
    let name: String
    let manufacturer: String
    let version: String
    let codeDirectoryHash: String
    let teamIdentifier: String
    let signatureKind: PluginCatalogSignatureKind
    let architectures: [String]
    let inputChannels: Int
    let outputChannels: Int
    let latencySamples: Int
    let hasEditor: Bool
    let compatibility: PluginCatalogCompatibility
    let reason: String?
    let bundleModificationTime: Int64
    let scannerProtocol: Int
    let compatibleAppVersion: String
    let lastScannedAt: String

    var id: String { fingerprint }
}

struct PluginCatalogDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let currentScannerProtocolVersion = 1
    static let currentCompatibleAppVersion = "0.1"

    let schemaVersion: Int
    let scannerProtocolVersion: Int
    let entries: [PluginCatalogEntry]

    init(
        schemaVersion: Int = currentSchemaVersion,
        scannerProtocolVersion: Int = currentScannerProtocolVersion,
        entries: [PluginCatalogEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.scannerProtocolVersion = scannerProtocolVersion
        self.entries = entries
    }
}

enum PluginCatalogFingerprint {
    private static let domain = "shitate-plugin-fingerprint-v1"

    static func make(
        bundlePath: String,
        classUID: String,
        codeDirectoryHash: String,
        architecture: String
    ) -> String? {
        var identity = Data()
        for field in [domain, bundlePath, classUID, codeDirectoryHash, architecture] {
            let bytes = Array(field.utf8)
            guard var length = UInt32(exactly: bytes.count)?.bigEndian else {
                return nil
            }
            withUnsafeBytes(of: &length) { identity.append(contentsOf: $0) }
            identity.append(contentsOf: bytes)
        }
        return SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }
}

enum PluginCatalogStoreError: Error, Equatable {
    case fileTooLarge
    case unsafeFile
    case invalidJSON
    case unsupportedSchema(Int)
    case unsupportedScannerProtocol(Int)
    case duplicateFingerprint(String)
    case invalidEntry(String)
}

struct PluginCatalogStore {
    static let maximumFileBytes = 4 * 1024 * 1024

    let fileURL: URL

    func load() throws -> PluginCatalogDocument {
        guard let data = try readSecureCatalogFile() else {
            return PluginCatalogDocument()
        }
        let document: PluginCatalogDocument
        do {
            document = try JSONDecoder().decode(PluginCatalogDocument.self, from: data)
        } catch {
            throw PluginCatalogStoreError.invalidJSON
        }
        try validate(document, requireCurrentAppVersion: false)
        return document
    }

    func save(_ document: PluginCatalogDocument) throws {
        try validate(document, requireCurrentAppVersion: true)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumFileBytes else {
            throw PluginCatalogStoreError.fileTooLarge
        }
        try AtomicFileWriter.write(data, to: fileURL)
    }

    private func readSecureCatalogFile() throws -> Data? {
        let descriptor = Darwin.open(
            fileURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw PluginCatalogStoreError.unsafeFile
        }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_uid == getuid(),
            status.st_nlink == 1,
            (status.st_mode & 0o777) == 0o600,
            status.st_size >= 0
        else {
            throw PluginCatalogStoreError.unsafeFile
        }
        guard status.st_size <= off_t(Self.maximumFileBytes) else {
            throw PluginCatalogStoreError.fileTooLarge
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                guard data.count + count <= Self.maximumFileBytes else {
                    throw PluginCatalogStoreError.fileTooLarge
                }
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw PluginCatalogStoreError.unsafeFile
        }

        var finalStatus = stat()
        guard fstat(descriptor, &finalStatus) == 0,
            finalStatus.st_dev == status.st_dev,
            finalStatus.st_ino == status.st_ino,
            finalStatus.st_size == off_t(data.count),
            finalStatus.st_mtimespec.tv_sec == status.st_mtimespec.tv_sec,
            finalStatus.st_mtimespec.tv_nsec == status.st_mtimespec.tv_nsec
        else {
            throw PluginCatalogStoreError.unsafeFile
        }
        return data
    }

    private func validate(
        _ document: PluginCatalogDocument,
        requireCurrentAppVersion: Bool
    ) throws {
        guard document.schemaVersion == PluginCatalogDocument.currentSchemaVersion else {
            throw PluginCatalogStoreError.unsupportedSchema(document.schemaVersion)
        }
        guard
            document.scannerProtocolVersion
                == PluginCatalogDocument.currentScannerProtocolVersion
        else {
            throw PluginCatalogStoreError.unsupportedScannerProtocol(
                document.scannerProtocolVersion
            )
        }

        var fingerprints = Set<String>()
        let dateFormatter = ISO8601DateFormatter()
        for entry in document.entries {
            guard fingerprints.insert(entry.fingerprint).inserted else {
                throw PluginCatalogStoreError.duplicateFingerprint(entry.fingerprint)
            }
            let expectedFingerprint = PluginCatalogFingerprint.make(
                bundlePath: entry.bundlePath,
                classUID: entry.classUID,
                codeDirectoryHash: entry.codeDirectoryHash,
                architecture: "arm64"
            )
            guard isHex(entry.fingerprint, length: 64),
                entry.fingerprint.lowercased() == expectedFingerprint,
                isCanonicalAbsolutePath(entry.bundlePath),
                entry.bundlePath.utf8.count <= 4096,
                isHex(entry.classUID, length: 32),
                isHex(entry.codeDirectoryHash, lengths: 40...128),
                !entry.name.isEmpty,
                entry.name.utf8.count <= 512,
                entry.manufacturer.utf8.count <= 512,
                entry.version.utf8.count <= 512,
                entry.teamIdentifier.utf8.count <= 512,
                entry.architectures.contains("arm64"),
                entry.architectures.count <= 8,
                entry.architectures.allSatisfy({ $0 == "arm64" || $0 == "x86_64" }),
                Set(entry.architectures).count == entry.architectures.count,
                (0...64).contains(entry.inputChannels),
                (0...64).contains(entry.outputChannels),
                (0...10_000_000).contains(entry.latencySamples),
                entry.bundleModificationTime >= 0,
                entry.scannerProtocol == document.scannerProtocolVersion,
                entry.compatibleAppVersion.range(
                    of: #"^[0-9]+\.[0-9]+$"#,
                    options: .regularExpression
                ) != nil,
                !requireCurrentAppVersion
                    || entry.compatibleAppVersion
                        == PluginCatalogDocument.currentCompatibleAppVersion,
                dateFormatter.date(from: entry.lastScannedAt) != nil
            else {
                throw PluginCatalogStoreError.invalidEntry(entry.fingerprint)
            }
            switch entry.compatibility {
            case .compatible:
                guard entry.inputChannels == 2, entry.outputChannels == 2,
                    entry.reason == nil
                else {
                    throw PluginCatalogStoreError.invalidEntry(entry.fingerprint)
                }
            case .incompatible, .blocked:
                guard let reason = entry.reason, !reason.isEmpty,
                    reason.utf8.count <= 512
                else {
                    throw PluginCatalogStoreError.invalidEntry(entry.fingerprint)
                }
            }
        }
    }

    private func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            return false
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    private func isHex(_ value: String, length: Int) -> Bool {
        isHex(value, lengths: length...length)
    }

    private func isHex(_ value: String, lengths: ClosedRange<Int>) -> Bool {
        lengths.contains(value.count)
            && value.range(of: #"^[0-9A-Fa-f]+$"#, options: .regularExpression) != nil
    }
}
