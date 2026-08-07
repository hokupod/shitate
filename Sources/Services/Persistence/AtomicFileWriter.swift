// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Darwin
import Foundation

enum AtomicFileWriterError: Error, Equatable {
    case invalidDestination
    case unsafeDestination
    case posix(operation: String, code: Int32)
}

enum AtomicWriteStage: CaseIterable, Equatable {
    case openedParentDirectory
    case createdTemporaryFile
    case wroteData
    case syncedData
    case closedTemporaryFile
    case publishedFile
    case syncedParentDirectory
}

enum AtomicFileWriter {
    static func write(_ data: Data, to destinationURL: URL) throws {
        try write(data, to: destinationURL, faultInjector: nil)
    }

    static func write(
        _ data: Data,
        to destinationURL: URL,
        faultInjector: ((AtomicWriteStage) throws -> Void)?
    ) throws {
        let destinationName = destinationURL.lastPathComponent
        guard
            destinationURL.isFileURL,
            !destinationName.isEmpty,
            destinationName != ".",
            destinationName != "..",
            !destinationName.contains("/")
        else {
            throw AtomicFileWriterError.invalidDestination
        }

        let directoryURL = destinationURL.deletingLastPathComponent()
        let directoryDescriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            throw posixError("open parent directory")
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        var directoryStatus = stat()
        guard
            Darwin.fstat(directoryDescriptor, &directoryStatus) == 0,
            (directoryStatus.st_mode & S_IFMT) == S_IFDIR,
            directoryStatus.st_uid == getuid()
        else {
            throw AtomicFileWriterError.unsafeDestination
        }
        try faultInjector?(.openedParentDirectory)
        try validateExistingDestination(
            named: destinationName,
            directoryDescriptor: directoryDescriptor
        )

        let temporaryName = ".\(destinationName).tmp-\(UUID().uuidString)"
        var fileDescriptor = temporaryName.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard fileDescriptor >= 0 else {
            throw posixError("open temporary file")
        }

        var removeTemporaryFile = true
        defer {
            if fileDescriptor >= 0 {
                _ = Darwin.close(fileDescriptor)
            }
            if removeTemporaryFile {
                temporaryName.withCString {
                    _ = Darwin.unlinkat(directoryDescriptor, $0, 0)
                }
            }
        }

        try faultInjector?(.createdTemporaryFile)
        guard Darwin.fchmod(fileDescriptor, mode_t(0o600)) == 0 else {
            throw posixError("set temporary file permissions")
        }
        try writeAll(data, to: fileDescriptor)
        try faultInjector?(.wroteData)
        guard Darwin.fsync(fileDescriptor) == 0 else {
            throw posixError("sync temporary file")
        }
        try faultInjector?(.syncedData)

        let closeStatus = Darwin.close(fileDescriptor)
        fileDescriptor = -1
        guard closeStatus == 0 else {
            throw posixError("close temporary file")
        }
        try faultInjector?(.closedTemporaryFile)

        let renameStatus = temporaryName.withCString { temporaryPath in
            destinationName.withCString { destinationPath in
                Darwin.renameat(
                    directoryDescriptor,
                    temporaryPath,
                    directoryDescriptor,
                    destinationPath
                )
            }
        }
        guard renameStatus == 0 else {
            throw posixError("publish destination file")
        }
        removeTemporaryFile = false
        try faultInjector?(.publishedFile)

        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw posixError("sync parent directory")
        }
        try faultInjector?(.syncedParentDirectory)
    }

    private static func validateExistingDestination(
        named destinationName: String,
        directoryDescriptor: Int32
    ) throws {
        var destinationStatus = stat()
        let status = destinationName.withCString {
            Darwin.fstatat(
                directoryDescriptor,
                $0,
                &destinationStatus,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if status != 0 {
            guard errno == ENOENT else {
                throw posixError("inspect destination file")
            }
            return
        }
        guard
            (destinationStatus.st_mode & S_IFMT) == S_IFREG,
            destinationStatus.st_uid == getuid(),
            destinationStatus.st_nlink == 1
        else {
            throw AtomicFileWriterError.unsafeDestination
        }
    }

    private static func writeAll(_ data: Data, to fileDescriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                return
            }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw posixError("write temporary file")
                }
                if written == 0 {
                    throw AtomicFileWriterError.posix(
                        operation: "write temporary file",
                        code: EIO
                    )
                }
                offset += written
            }
        }
    }

    private static func posixError(_ operation: String) -> AtomicFileWriterError {
        AtomicFileWriterError.posix(operation: operation, code: errno)
    }
}
