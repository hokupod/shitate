// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Foundation
import Observation
import ServiceManagement

@MainActor
struct LaunchAtLoginBackend {
    var isEnabled: () -> Bool
    var setEnabled: (Bool) throws -> Void

    static let live = LaunchAtLoginBackend(
        isEnabled: { SMAppService.mainApp.status == .enabled },
        setEnabled: { enabled in
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
    )
}

@MainActor
@Observable
final class LaunchAtLoginService {
    private let backend: LaunchAtLoginBackend

    private(set) var isEnabled = false
    private(set) var lastError: String?

    init(backend: LaunchAtLoginBackend = .live) {
        self.backend = backend
        refresh()
    }

    func refresh() {
        isEnabled = backend.isEnabled()
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        refresh()
        guard isEnabled != enabled else {
            lastError = nil
            return true
        }
        do {
            try backend.setEnabled(enabled)
            refresh()
            lastError = nil
            return isEnabled == enabled
        } catch {
            refresh()
            lastError = error.localizedDescription
            return false
        }
    }
}
