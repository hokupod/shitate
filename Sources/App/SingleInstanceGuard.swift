// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Darwin
import Foundation

enum SingleInstanceGuardError: Error, Equatable {
    case unsafeLockFile
    case posix(Int32)
}

final class SingleInstanceGuard {
    private let lockURL: URL
    private var descriptor: Int32 = -1

    init(
        lockURL: URL = ApplicationPaths.live.applicationSupportDirectory.appendingPathComponent(
            "instance.lock")
    ) {
        self.lockURL = lockURL
    }

    deinit {
        release()
    }

    func acquire() throws -> Bool {
        if descriptor >= 0 {
            return true
        }
        try SecureDirectory.prepare(lockURL.deletingLastPathComponent())
        let opened = lockURL.path.withCString {
            Darwin.open(
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK | O_NONBLOCK,
                mode_t(0o600)
            )
        }
        guard opened >= 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN {
                return false
            }
            throw SingleInstanceGuardError.posix(errno)
        }

        var status = stat()
        guard
            Darwin.fstat(opened, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_uid == getuid(),
            status.st_nlink == 1,
            Darwin.fchmod(opened, mode_t(0o600)) == 0
        else {
            _ = Darwin.close(opened)
            throw SingleInstanceGuardError.unsafeLockFile
        }

        descriptor = opened
        return true
    }

    func release() {
        guard descriptor >= 0 else {
            return
        }
        _ = Darwin.close(descriptor)
        descriptor = -1
    }
}
