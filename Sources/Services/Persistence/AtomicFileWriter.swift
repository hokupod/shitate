// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Darwin
import Foundation

enum AtomicFileWriterError: Error, Equatable {
    case invalidDestination
    case posix(operation: String, code: Int32)
}

enum AtomicFileWriter {
    static func write(_ data: Data, to destinationURL: URL) throws {
        guard destinationURL.isFileURL, !destinationURL.lastPathComponent.isEmpty else {
            throw AtomicFileWriterError.invalidDestination
        }

        let directoryURL = destinationURL.deletingLastPathComponent()
        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)",
            isDirectory: false
        )
        var fileDescriptor = temporaryURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
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
                temporaryURL.path.withCString { _ = Darwin.unlink($0) }
            }
        }

        guard Darwin.fchmod(fileDescriptor, mode_t(0o600)) == 0 else {
            throw posixError("set temporary file permissions")
        }
        try writeAll(data, to: fileDescriptor)
        guard Darwin.fsync(fileDescriptor) == 0 else {
            throw posixError("sync temporary file")
        }
        guard Darwin.close(fileDescriptor) == 0 else {
            fileDescriptor = -1
            throw posixError("close temporary file")
        }
        fileDescriptor = -1

        let renameStatus = temporaryURL.path.withCString { temporaryPath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(temporaryPath, destinationPath)
            }
        }
        guard renameStatus == 0 else {
            throw posixError("publish destination file")
        }
        removeTemporaryFile = false

        let directoryDescriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            throw posixError("open parent directory")
        }
        defer { _ = Darwin.close(directoryDescriptor) }
        guard Darwin.fsync(directoryDescriptor) == 0 else {
            throw posixError("sync parent directory")
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
                    throw AtomicFileWriterError.posix(operation: "write temporary file", code: EIO)
                }
                offset += written
            }
        }
    }

    private static func posixError(_ operation: String) -> AtomicFileWriterError {
        AtomicFileWriterError.posix(operation: operation, code: errno)
    }
}
