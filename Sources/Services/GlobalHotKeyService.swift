// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Carbon
import Foundation
import Observation

enum GlobalHotKeyError: Error, Equatable {
    case registrationConflict(OSStatus)
}

@MainActor
protocol GlobalHotKeyBackend: AnyObject {
    func register(action: @escaping () -> Void) throws
    func unregister()
}

@MainActor
final class CarbonGlobalHotKeyBackend: GlobalHotKeyBackend {
    private static let signature: OSType = 0x5368_6974

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var action: (() -> Void)?

    func register(action: @escaping () -> Void) throws {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let backend = Unmanaged<CarbonGlobalHotKeyBackend>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                MainActor.assumeIsolated {
                    backend.invoke()
                }
                return noErr
            },
            1,
            &eventType,
            context,
            &eventHandler
        )
        guard handlerStatus == noErr else {
            self.action = nil
            throw GlobalHotKeyError.registrationConflict(handlerStatus)
        }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let hotKeyStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_M),
            UInt32(controlKey | shiftKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard hotKeyStatus == noErr else {
            unregister()
            throw GlobalHotKeyError.registrationConflict(hotKeyStatus)
        }
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        hotKey = nil
        eventHandler = nil
        action = nil
    }

    private func invoke() {
        action?()
    }
}

@MainActor
@Observable
final class GlobalHotKeyService {
    private let backend: any GlobalHotKeyBackend

    private(set) var isRegistered = false
    private(set) var warning: String?

    init(backend: any GlobalHotKeyBackend = CarbonGlobalHotKeyBackend()) {
        self.backend = backend
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, action: @escaping () -> Void) -> Bool {
        backend.unregister()
        isRegistered = false
        warning = nil
        guard enabled else {
            return true
        }
        do {
            try backend.register(action: action)
            isRegistered = true
            return true
        } catch {
            warning =
                "Control-Shift-M is already in use. Use the Mute button until the conflict is resolved."
            return false
        }
    }

    func unregister() {
        backend.unregister()
        isRegistered = false
    }
}
