// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Darwin
import Foundation

enum SessionSaveStage: Equatable {
    case wrotePluginState(UUID)
    case wroteManifest
    case willPublish
    case published
    case syncedParentDirectory
}

struct SessionStore {
    static let maximumManifestBytes = 4 * 1024 * 1024
    static let maximumPluginStateBytes = 32 * 1024 * 1024
    static let maximumTotalPluginStateBytes = 128 * 1024 * 1024

    let paths: ApplicationPaths
    var faultInjector: ((SessionSaveStage) throws -> Void)?

    init(
        paths: ApplicationPaths,
        faultInjector: ((SessionSaveStage) throws -> Void)? = nil
    ) {
        self.paths = paths
        self.faultInjector = faultInjector
    }

    func load(id: String) throws -> PersistedSession? {
        let sessionDirectory = try paths.sessionDirectory(id: id)
        guard try directoryExists(sessionDirectory) else {
            return nil
        }
        try SecureDirectory.validate(sessionDirectory)

        let manifestURL = sessionDirectory.appendingPathComponent("session.json")
        guard
            let manifestData = try SecureFileReader.read(
                manifestURL,
                maximumBytes: Self.maximumManifestBytes
            )
        else {
            throw PersistenceStoreError.invalidDocument("session manifest is missing")
        }
        let version = try PersistenceCoding.schemaVersion(in: manifestData)
        guard version == SessionDocument.currentSchemaVersion else {
            throw PersistenceStoreError.unsupportedSchema(version)
        }
        let document = try PersistenceCoding.decode(SessionDocument.self, from: manifestData)
        try validate(document, expectedID: id)

        let stateDirectory = sessionDirectory.appendingPathComponent(
            "plugin-states",
            isDirectory: true
        )
        if !document.slots.isEmpty {
            try SecureDirectory.validate(stateDirectory)
        }

        var states: [UUID: Data] = [:]
        var totalBytes = 0
        for slot in document.slots {
            let stateURL = sessionDirectory.appendingPathComponent(slot.stateFile)
            guard
                let data = try SecureFileReader.read(
                    stateURL,
                    maximumBytes: Self.maximumPluginStateBytes
                )
            else {
                throw PersistenceStoreError.invalidDocument(
                    "plug-in state is missing for \(slot.slotID.uuidString)"
                )
            }
            totalBytes += data.count
            guard totalBytes <= Self.maximumTotalPluginStateBytes else {
                throw PersistenceStoreError.fileTooLarge
            }
            states[slot.slotID] = data
        }
        return PersistedSession(document: document, pluginStates: states)
    }

    func save(_ session: PersistedSession) throws {
        try validate(session.document, expectedID: session.document.id)
        let slotIDs = Set(session.document.slots.map(\.slotID))
        guard Set(session.pluginStates.keys) == slotIDs else {
            throw PersistenceStoreError.invalidDocument("plug-in state set does not match slots")
        }

        var totalStateBytes = 0
        for data in session.pluginStates.values {
            guard data.count <= Self.maximumPluginStateBytes else {
                throw PersistenceStoreError.fileTooLarge
            }
            totalStateBytes += data.count
            guard totalStateBytes <= Self.maximumTotalPluginStateBytes else {
                throw PersistenceStoreError.fileTooLarge
            }
        }

        try SecureDirectory.prepare(paths.applicationSupportDirectory)
        try SecureDirectory.prepare(paths.sessionsDirectory)

        let stageName =
            ".session-\(session.document.id)-stage-\(UUID().uuidString)"
        let stageDirectory = paths.sessionsDirectory.appendingPathComponent(
            stageName,
            isDirectory: true
        )
        let stateDirectory = stageDirectory.appendingPathComponent(
            "plugin-states",
            isDirectory: true
        )
        try SecureDirectory.prepare(stageDirectory)
        try SecureDirectory.prepare(stateDirectory)

        var published = false
        var oldSessionAtStagePath = false
        defer {
            if !published || oldSessionAtStagePath {
                try? FileManager.default.removeItem(at: stageDirectory)
            }
        }

        for slot in session.document.slots.sorted(by: { $0.order < $1.order }) {
            guard let data = session.pluginStates[slot.slotID] else {
                throw PersistenceStoreError.invalidDocument("plug-in state is missing")
            }
            let stateURL = stageDirectory.appendingPathComponent(slot.stateFile)
            try AtomicFileWriter.write(data, to: stateURL)
            try faultInjector?(.wrotePluginState(slot.slotID))
        }

        let manifestData = try PersistenceCoding.encode(session.document)
        guard manifestData.count <= Self.maximumManifestBytes else {
            throw PersistenceStoreError.fileTooLarge
        }
        try AtomicFileWriter.write(
            manifestData,
            to: stageDirectory.appendingPathComponent("session.json")
        )
        try faultInjector?(.wroteManifest)
        try faultInjector?(.willPublish)

        oldSessionAtStagePath = try publish(
            stageName: stageName,
            sessionID: session.document.id
        )
        published = true
        try faultInjector?(.published)
        try faultInjector?(.syncedParentDirectory)
    }

    private func validate(_ document: SessionDocument, expectedID: String) throws {
        guard document.schemaVersion == SessionDocument.currentSchemaVersion else {
            throw PersistenceStoreError.unsupportedSchema(document.schemaVersion)
        }
        try PersistenceIdentifier.validateSessionID(document.id)
        guard
            document.id == expectedID,
            !document.name.isEmpty,
            document.name.utf8.count <= 256,
            ISO8601DateFormatter().date(from: document.updatedAt) != nil,
            document.slots.count <= SessionDocument.maximumSlots
        else {
            throw PersistenceStoreError.invalidDocument("invalid session metadata")
        }

        var slotIDs = Set<UUID>()
        for (expectedOrder, slot) in document.slots.enumerated() {
            let standardizedBundlePath = URL(fileURLWithPath: slot.bundlePath).standardizedFileURL
                .path
            guard
                slot.order == expectedOrder,
                slotIDs.insert(slot.slotID).inserted,
                slot.pluginFingerprint.utf8.count == 64,
                slot.pluginFingerprint.utf8.allSatisfy(isLowercaseHex),
                slot.bundlePath.hasPrefix("/"),
                standardizedBundlePath == slot.bundlePath,
                slot.bundlePath.utf8.count <= 4_096,
                !slot.bundlePath.contains("\0"),
                !slot.classUID.isEmpty,
                slot.classUID.utf8.count <= 256,
                !slot.name.isEmpty,
                slot.name.utf8.count <= 1_024,
                slot.manufacturer.utf8.count <= 1_024,
                slot.version.utf8.count <= 256,
                slot.stateFile == SessionSlotDocument.stateFile(for: slot.slotID)
            else {
                throw PersistenceStoreError.invalidDocument("invalid session slot")
            }
        }
    }

    private func directoryExists(_ directoryURL: URL) throws -> Bool {
        var status = stat()
        let result = directoryURL.path.withCString { Darwin.lstat($0, &status) }
        if result != 0 {
            if errno == ENOENT {
                return false
            }
            throw PersistenceStoreError.unsafeDirectory
        }
        guard
            (status.st_mode & S_IFMT) == S_IFDIR,
            status.st_uid == getuid(),
            (status.st_mode & 0o077) == 0
        else {
            throw PersistenceStoreError.unsafeDirectory
        }
        return true
    }

    private func publish(stageName: String, sessionID: String) throws -> Bool {
        let directoryDescriptor = paths.sessionsDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            throw PersistenceStoreError.unsafeDirectory
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        var existingStatus = stat()
        let existingResult = sessionID.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &existingStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        let sessionExists: Bool
        if existingResult == 0 {
            guard
                (existingStatus.st_mode & S_IFMT) == S_IFDIR,
                existingStatus.st_uid == getuid(),
                (existingStatus.st_mode & 0o077) == 0
            else {
                throw PersistenceStoreError.unsafeDirectory
            }
            sessionExists = true
        } else if errno == ENOENT {
            sessionExists = false
        } else {
            throw PersistenceStoreError.unsafeDirectory
        }

        let publishStatus: Int32
        if sessionExists {
            publishStatus = stageName.withCString { stagePath in
                sessionID.withCString { destinationPath in
                    Darwin.renameatx_np(
                        directoryDescriptor,
                        stagePath,
                        directoryDescriptor,
                        destinationPath,
                        UInt32(RENAME_SWAP)
                    )
                }
            }
        } else {
            publishStatus = stageName.withCString { stagePath in
                sessionID.withCString { destinationPath in
                    Darwin.renameat(
                        directoryDescriptor,
                        stagePath,
                        directoryDescriptor,
                        destinationPath
                    )
                }
            }
        }
        guard publishStatus == 0 else {
            throw AtomicFileWriterError.posix(
                operation: "publish session directory",
                code: errno
            )
        }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw AtomicFileWriterError.posix(
                operation: "sync sessions directory",
                code: errno
            )
        }
        return sessionExists
    }

    private func isLowercaseHex(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (97...102).contains(value)
    }
}
