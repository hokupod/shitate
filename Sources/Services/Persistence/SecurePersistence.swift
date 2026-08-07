// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Darwin
import Foundation

enum PersistenceStoreError: Error, Equatable {
    case invalidIdentifier(String)
    case invalidDocument(String)
    case invalidJSON
    case unsupportedSchema(Int)
    case fileTooLarge
    case unsafeFile
    case unsafeDirectory
}

struct ApplicationPaths: Equatable, Sendable {
    let applicationSupportDirectory: URL
    let logsDirectory: URL

    static var live: ApplicationPaths {
        let supportRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let logsRoot = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Logs", isDirectory: true)
        return ApplicationPaths(
            applicationSupportDirectory: supportRoot.appendingPathComponent(
                "dev.hokupod.shitate",
                isDirectory: true
            ),
            logsDirectory: logsRoot.appendingPathComponent("Shitate", isDirectory: true)
        )
    }

    var settingsURL: URL {
        applicationSupportDirectory.appendingPathComponent("settings.json")
    }

    var blockedPluginsURL: URL {
        applicationSupportDirectory.appendingPathComponent("blocked-plugins.json")
    }

    var runStateURL: URL {
        applicationSupportDirectory.appendingPathComponent("run-state.json")
    }

    var scanFoldersURL: URL {
        applicationSupportDirectory.appendingPathComponent("scan-folders.json")
    }

    var sessionsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("sessions", isDirectory: true)
    }

    func sessionDirectory(id: String) throws -> URL {
        try PersistenceIdentifier.validateSessionID(id)
        return sessionsDirectory.appendingPathComponent(id, isDirectory: true)
    }
}

enum PersistenceIdentifier {
    static func validateSessionID(_ value: String) throws {
        guard
            !value.isEmpty,
            value.utf8.count <= 64,
            let first = value.utf8.first,
            isASCIIAlphanumeric(first),
            value.utf8.allSatisfy({ isASCIIAlphanumeric($0) || $0 == 45 || $0 == 95 })
        else {
            throw PersistenceStoreError.invalidIdentifier(value)
        }
    }

    private static func isASCIIAlphanumeric(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value)
    }
}

enum SecureDirectory {
    static func prepare(_ directoryURL: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PersistenceStoreError.unsafeDirectory
        }

        let descriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw PersistenceStoreError.unsafeDirectory
        }
        defer { _ = Darwin.close(descriptor) }

        var status = stat()
        guard
            Darwin.fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFDIR,
            status.st_uid == getuid(),
            Darwin.fchmod(descriptor, mode_t(0o700)) == 0
        else {
            throw PersistenceStoreError.unsafeDirectory
        }
    }

    static func validate(_ directoryURL: URL) throws {
        let descriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw PersistenceStoreError.unsafeDirectory
        }
        defer { _ = Darwin.close(descriptor) }

        var status = stat()
        guard
            Darwin.fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFDIR,
            status.st_uid == getuid(),
            (status.st_mode & 0o077) == 0
        else {
            throw PersistenceStoreError.unsafeDirectory
        }
    }
}

enum SecureFileReader {
    static func read(_ fileURL: URL, maximumBytes: Int) throws -> Data? {
        let descriptor = fileURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return nil
            }
            throw PersistenceStoreError.unsafeFile
        }
        defer { _ = Darwin.close(descriptor) }

        var initialStatus = stat()
        guard
            Darwin.fstat(descriptor, &initialStatus) == 0,
            (initialStatus.st_mode & S_IFMT) == S_IFREG,
            initialStatus.st_uid == getuid(),
            initialStatus.st_nlink == 1,
            (initialStatus.st_mode & 0o777) == 0o600,
            initialStatus.st_size >= 0
        else {
            throw PersistenceStoreError.unsafeFile
        }
        guard initialStatus.st_size <= off_t(maximumBytes) else {
            throw PersistenceStoreError.fileTooLarge
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, maximumBytes))
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                guard data.count + count <= maximumBytes else {
                    throw PersistenceStoreError.fileTooLarge
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
            throw PersistenceStoreError.unsafeFile
        }

        var finalStatus = stat()
        guard
            Darwin.fstat(descriptor, &finalStatus) == 0,
            finalStatus.st_dev == initialStatus.st_dev,
            finalStatus.st_ino == initialStatus.st_ino,
            finalStatus.st_size == off_t(data.count),
            finalStatus.st_mtimespec.tv_sec == initialStatus.st_mtimespec.tv_sec,
            finalStatus.st_mtimespec.tv_nsec == initialStatus.st_mtimespec.tv_nsec
        else {
            throw PersistenceStoreError.unsafeFile
        }
        return data
    }
}

enum PersistenceCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw PersistenceStoreError.invalidDocument("encoding failed")
        }
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw PersistenceStoreError.invalidJSON
        }
    }

    static func schemaVersion(in data: Data) throws -> Int {
        struct Envelope: Decodable {
            let schemaVersion: Int
        }
        return try decode(Envelope.self, from: data).schemaVersion
    }
}

struct SettingsStore {
    static let maximumFileBytes = 1024 * 1024

    let paths: ApplicationPaths
    var now: () -> Date
    var writer: (Data, URL) throws -> Void

    init(
        paths: ApplicationPaths,
        now: @escaping () -> Date = Date.init,
        writer: @escaping (Data, URL) throws -> Void = AtomicFileWriter.write
    ) {
        self.paths = paths
        self.now = now
        self.writer = writer
    }

    func load() throws -> SettingsDocument {
        guard
            let data = try SecureFileReader.read(
                paths.settingsURL,
                maximumBytes: Self.maximumFileBytes
            )
        else {
            return .defaults
        }

        switch try PersistenceCoding.schemaVersion(in: data) {
        case SettingsDocument.currentSchemaVersion:
            let document = try PersistenceCoding.decode(SettingsDocument.self, from: data)
            try validate(document)
            return document
        case 0:
            return try migrateV0(data)
        case let version:
            throw PersistenceStoreError.unsupportedSchema(version)
        }
    }

    func save(_ document: SettingsDocument) throws {
        try validate(document)
        try SecureDirectory.prepare(paths.applicationSupportDirectory)
        let data = try PersistenceCoding.encode(document)
        guard data.count <= Self.maximumFileBytes else {
            throw PersistenceStoreError.fileTooLarge
        }
        try writer(data, paths.settingsURL)
    }

    private func migrateV0(_ data: Data) throws -> SettingsDocument {
        let legacy = try PersistenceCoding.decode(LegacySettingsDocumentV0.self, from: data)
        let backupURL = paths.settingsURL.appendingPathExtension(
            "backup-\(backupTimestamp(now()))-\(UUID().uuidString)"
        )
        try writer(data, backupURL)

        let migrated = SettingsDocument(
            schemaVersion: SettingsDocument.currentSchemaVersion,
            launchAtLogin: legacy.launchAtLogin,
            startRoutingAtLaunch: legacy.startRoutingAtLaunch,
            restoreLastSession: legacy.restoreLastSession,
            resumeAfterWake: false,
            globalMuteShortcutEnabled: legacy.globalMuteShortcutEnabled,
            audio: legacy.audio,
            pluginPolicy: legacy.pluginPolicy,
            lastSessionID: legacy.lastSessionID
        )
        try save(migrated)
        return migrated
    }

    private func validate(_ document: SettingsDocument) throws {
        guard document.schemaVersion == SettingsDocument.currentSchemaVersion else {
            throw PersistenceStoreError.unsupportedSchema(document.schemaVersion)
        }
        try PersistenceIdentifier.validateSessionID(document.lastSessionID)
        guard
            document.audio.inputChannelIndex >= 0,
            document.audio.manualOutputChannelStart >= 0,
            abs(document.audio.sampleRate - 48_000) < 0.5,
            [128, 256, 512].contains(document.audio.bufferFrames),
            validField(document.audio.inputDeviceUID),
            validField(document.audio.inputDeviceName),
            validField(document.audio.outputDeviceUID),
            validField(document.audio.outputDeviceName)
        else {
            throw PersistenceStoreError.invalidDocument("invalid settings")
        }
    }

    private func validField(_ value: String) -> Bool {
        value.utf8.count <= 4_096 && !value.contains("\0")
    }

    private func backupTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date).replacingOccurrences(of: ":", with: "-")
    }
}

private struct LegacySettingsDocumentV0: Codable {
    let schemaVersion: Int
    let launchAtLogin: Bool
    let startRoutingAtLaunch: Bool
    let restoreLastSession: Bool
    let globalMuteShortcutEnabled: Bool
    let audio: PersistedAudioSettings
    let pluginPolicy: PluginPolicySettings
    let lastSessionID: String
}

struct RunStateStore {
    static let maximumFileBytes = 1024 * 1024

    let paths: ApplicationPaths
    var writer: (Data, URL) throws -> Void

    init(
        paths: ApplicationPaths,
        writer: @escaping (Data, URL) throws -> Void = AtomicFileWriter.write
    ) {
        self.paths = paths
        self.writer = writer
    }

    func load() throws -> RunStateDocument? {
        guard
            let data = try SecureFileReader.read(
                paths.runStateURL,
                maximumBytes: Self.maximumFileBytes
            )
        else {
            return nil
        }
        let version = try PersistenceCoding.schemaVersion(in: data)
        guard version == RunStateDocument.currentSchemaVersion else {
            throw PersistenceStoreError.unsupportedSchema(version)
        }
        let document = try PersistenceCoding.decode(RunStateDocument.self, from: data)
        guard
            ISO8601DateFormatter().date(from: document.startedAt) != nil,
            ISO8601DateFormatter().date(from: document.updatedAt) != nil,
            document.endedAt.map { ISO8601DateFormatter().date(from: $0) != nil } ?? true,
            document.processUptimeSeconds >= 0,
            document.processUptimeSeconds.isFinite,
            document.lastOperation.utf8.count <= 128,
            document.loadingPlugin?.pluginFingerprint.utf8.count ?? 0 <= 256,
            document.loadingPlugin?.pluginName.utf8.count ?? 0 <= 1_024,
            document.history.count <= RunStateDocument.maximumHistoryRecords,
            document.history.allSatisfy(validateHistoryRecord)
        else {
            throw PersistenceStoreError.invalidDocument("invalid run state")
        }
        return document
    }

    func save(_ document: RunStateDocument) throws {
        guard document.schemaVersion == RunStateDocument.currentSchemaVersion else {
            throw PersistenceStoreError.unsupportedSchema(document.schemaVersion)
        }
        try SecureDirectory.prepare(paths.applicationSupportDirectory)
        let data = try PersistenceCoding.encode(document)
        guard data.count <= Self.maximumFileBytes else {
            throw PersistenceStoreError.fileTooLarge
        }
        try writer(data, paths.runStateURL)
    }

    private func validateHistoryRecord(_ record: RunHistoryRecord) -> Bool {
        ISO8601DateFormatter().date(from: record.startedAt) != nil
            && ISO8601DateFormatter().date(from: record.observedAt) != nil
            && record.durationSeconds >= 0
            && record.durationSeconds.isFinite
            && record.lastOperation.utf8.count <= 128
            && (record.loadingPlugin?.pluginFingerprint.utf8.count ?? 0) <= 256
            && (record.loadingPlugin?.pluginName.utf8.count ?? 0) <= 1_024
    }
}

struct AuxiliaryPersistenceStore {
    static let maximumFileBytes = 1024 * 1024

    let paths: ApplicationPaths

    func loadBlockedPlugins() throws -> BlockedPluginsDocument {
        try load(
            BlockedPluginsDocument.self,
            from: paths.blockedPluginsURL,
            default: .empty,
            currentSchema: BlockedPluginsDocument.currentSchemaVersion
        )
    }

    func saveBlockedPlugins(_ document: BlockedPluginsDocument) throws {
        guard
            document.schemaVersion == BlockedPluginsDocument.currentSchemaVersion,
            document.fingerprints.count <= 4_096,
            Set(document.fingerprints).count == document.fingerprints.count,
            document.fingerprints.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 })
        else {
            throw PersistenceStoreError.invalidDocument("invalid blocked plug-ins")
        }
        try save(document, to: paths.blockedPluginsURL)
    }

    @discardableResult
    func repairBlockedPlugins() throws -> URL? {
        try SecureDirectory.prepare(paths.applicationSupportDirectory)
        let source = paths.blockedPluginsURL
        var status = stat()
        let result = source.path.withCString { Darwin.lstat($0, &status) }
        if result != 0 {
            guard errno == ENOENT else {
                throw PersistenceStoreError.unsafeFile
            }
            try saveBlockedPlugins(.empty)
            return nil
        }
        guard
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_uid == getuid(),
            status.st_nlink == 1
        else {
            throw PersistenceStoreError.unsafeFile
        }

        let quarantine = source.appendingPathExtension(
            "quarantine-\(UUID().uuidString.lowercased())"
        )
        guard Darwin.rename(source.path, quarantine.path) == 0 else {
            throw PersistenceStoreError.unsafeFile
        }
        guard Darwin.chmod(quarantine.path, mode_t(0o600)) == 0 else {
            _ = Darwin.rename(quarantine.path, source.path)
            throw PersistenceStoreError.unsafeFile
        }
        do {
            try saveBlockedPlugins(.empty)
        } catch {
            _ = Darwin.unlink(source.path)
            _ = Darwin.rename(quarantine.path, source.path)
            throw error
        }
        return quarantine
    }

    func loadScanFolders() throws -> ScanFoldersDocument {
        let document = try load(
            ScanFoldersDocument.self,
            from: paths.scanFoldersURL,
            default: .empty,
            currentSchema: ScanFoldersDocument.currentSchemaVersion
        )
        try validateScanFolders(document)
        return document
    }

    func saveScanFolders(_ document: ScanFoldersDocument) throws {
        try validateScanFolders(document)
        try save(document, to: paths.scanFoldersURL)
    }

    private func load<T: Decodable>(
        _ type: T.Type,
        from fileURL: URL,
        default defaultValue: T,
        currentSchema: Int
    ) throws -> T {
        guard let data = try SecureFileReader.read(fileURL, maximumBytes: Self.maximumFileBytes)
        else {
            return defaultValue
        }
        let version = try PersistenceCoding.schemaVersion(in: data)
        guard version == currentSchema else {
            throw PersistenceStoreError.unsupportedSchema(version)
        }
        return try PersistenceCoding.decode(type, from: data)
    }

    private func save<T: Encodable>(_ document: T, to fileURL: URL) throws {
        try SecureDirectory.prepare(paths.applicationSupportDirectory)
        let data = try PersistenceCoding.encode(document)
        guard data.count <= Self.maximumFileBytes else {
            throw PersistenceStoreError.fileTooLarge
        }
        try AtomicFileWriter.write(data, to: fileURL)
    }

    private func validateScanFolders(_ document: ScanFoldersDocument) throws {
        guard
            document.schemaVersion == ScanFoldersDocument.currentSchemaVersion,
            document.folders.count <= 64,
            Set(document.folders).count == document.folders.count,
            document.folders.allSatisfy({ folder in
                let url = URL(fileURLWithPath: folder).standardizedFileURL
                return folder.hasPrefix("/")
                    && folder == url.path
                    && folder.utf8.count <= 4_096
                    && !folder.contains("\0")
            })
        else {
            throw PersistenceStoreError.invalidDocument("invalid scan folders")
        }
    }
}
