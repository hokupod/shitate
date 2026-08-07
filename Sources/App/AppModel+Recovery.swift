// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Foundation

enum RecoveryControlError: Error, LocalizedError, Equatable {
    case blockedPlugin(String)
    case blockedPluginStateInvalid
    case wakeValidation(String)

    var errorDescription: String? {
        switch self {
        case .blockedPlugin(let name):
            "\(name) is blocked after repeated load crashes. Explicitly unblock it before loading."
        case .blockedPluginStateInvalid:
            "The blocked plug-in state must be repaired before any plug-in can load."
        case .wakeValidation(let message):
            message
        }
    }
}

enum WakeRecoveryDecision: Equatable, Sendable {
    case restart
    case remainStopped
}

enum WakeRecoveryPolicy {
    static func decide(
        wasRoutingBeforeSleep: Bool,
        resumeAfterWake: Bool,
        environmentReady: Bool,
        sessionReady: Bool,
        pluginsValidated: Bool
    ) -> WakeRecoveryDecision {
        guard
            wasRoutingBeforeSleep,
            resumeAfterWake,
            environmentReady,
            sessionReady,
            pluginsValidated
        else {
            return .remainStopped
        }
        return .restart
    }
}

enum DeviceResetDecision: Equatable, Sendable {
    case attemptOnce
    case remainStopped
}

enum DeviceResetPolicy {
    static func decide(
        issue: BlockingIssue,
        resetAlreadyAttempted: Bool,
        configuredBufferFrames: Int
    ) -> DeviceResetDecision {
        guard !resetAlreadyAttempted else {
            return .remainStopped
        }
        switch issue {
        case .unsupportedSampleRate:
            return .attemptOnce
        case .unsupportedBufferSize:
            return [128, 256, 512].contains(configuredBufferFrames)
                ? .attemptOnce : .remainStopped
        case .inputDeviceMissing, .outputDeviceMissing, .aggregateDeviceCreationFailed,
            .engineStartFailed, .unexpectedEngineState:
            return .remainStopped
        }
    }
}

@MainActor
extension AppModel {
    var safeModeReason: SafeModeReason? {
        guard case .safeMode(let reason) = state else {
            return nil
        }
        return reason
    }

    func enterSafeMode(_ reason: SafeModeReason) {
        cancelStartRoutingAtLaunch()
        startRoutingAtLaunchPending = false
        pendingAudioOperation = nil
        operationAfterStop = nil
        resumeAfterOperation = false
        bridge.setMasterMuted(true)
        if isRoutingActive {
            bridge.stop()
        }
        configuredOutputTarget = nil
        cancelPreviewSession()
        isMuted = false
        state = .safeMode(reason)
        localLogService.log("safeModeEntered", fields: ["reason": "\(reason)"])

        do {
            loadedSession = try sessionStore.load(id: settings.lastSessionID)
            sessionWorkflow =
                loadedSession == nil ? .notLoaded : .incomplete(safeModeMessage(reason))
        } catch {
            loadedSession = nil
            sessionWorkflow = .incomplete(error.localizedDescription)
            lastError = "The saved session could not be inspected safely."
        }
    }

    @discardableResult
    func recordRunOperation(
        _ operation: String,
        loadingPlugin: LoadingPluginDocument? = nil,
        routingWasActive: Bool? = nil
    ) -> Bool {
        do {
            try runStateService.recordOperation(
                operation,
                loadingPlugin: loadingPlugin,
                routingWasActive: routingWasActive
            )
            return true
        } catch {
            bridge.setMasterMuted(true)
            bridge.stop()
            configuredOutputTarget = nil
            cancelPreviewSession()
            persistenceBlocksRouting = true
            lastError = error.localizedDescription
            state = .safeMode(.runStateWriteFailed)
            return false
        }
    }

    func beginTrackedPluginLoad(
        slotID: UUID,
        fingerprint: String,
        name: String
    ) throws {
        guard !blockedPluginStateInvalid else {
            throw RecoveryControlError.blockedPluginStateInvalid
        }
        guard !blockedPluginFingerprints.contains(fingerprint) else {
            throw RecoveryControlError.blockedPlugin(name)
        }
        let loading = LoadingPluginDocument(
            slotID: slotID,
            pluginFingerprint: fingerprint,
            pluginName: name
        )
        guard
            recordRunOperation(
                "loadingPlugin",
                loadingPlugin: loading,
                routingWasActive: isRoutingActive
            )
        else {
            throw RunStateServiceError.persistence("write-before-load failed")
        }
        localLogService.log(
            "pluginLoadStarted",
            fields: [
                "name": name,
                "fingerprint": String(fingerprint.prefix(12)),
            ]
        )
    }

    @discardableResult
    func finishTrackedPluginLoad() -> Bool {
        do {
            try runStateService.finishPluginLoad(routingWasActive: isRoutingActive)
            localLogService.log("pluginLoadFinished")
            return true
        } catch {
            bridge.setMasterMuted(true)
            bridge.stop()
            configuredOutputTarget = nil
            cancelPreviewSession()
            persistenceBlocksRouting = true
            lastError = error.localizedDescription
            state = .safeMode(.runStateWriteFailed)
            return false
        }
    }

    func setResumeAfterWake(_ enabled: Bool) {
        settings.resumeAfterWake = enabled
        persistSettings()
    }

    func unblockSafeModeSuspect() {
        guard !blockedPluginStateInvalid else {
            lastError = RecoveryControlError.blockedPluginStateInvalid.localizedDescription
            return
        }
        guard let fingerprint = safeModeSuspect?.pluginFingerprint else {
            return
        }
        var next = blockedPluginFingerprints
        next.remove(fingerprint)
        do {
            try runStateService.setBlocked(next)
            blockedPluginFingerprints = next
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func repairBlockedPluginState() {
        guard safeModeReason != nil, blockedPluginStateInvalid else {
            return
        }
        do {
            let quarantineURL = try runStateService.repairBlockedPluginState()
            blockedPluginFingerprints = []
            blockedPluginStateInvalid = false
            lastError =
                quarantineURL == nil
                ? "The missing block list was recreated safely."
                : "The invalid block list was quarantined and recreated safely."
            localLogService.log("blockedPluginStateRepaired")
        } catch {
            lastError = error.localizedDescription
        }
    }

    func rescanSafeModeSuspect() {
        guard
            let fingerprint = safeModeSuspect?.pluginFingerprint,
            let entry = pluginCatalog.document.entries.first(where: {
                $0.fingerprint == fingerprint
            })
        else {
            lastError = "The suspect plug-in is no longer present in the validated catalog."
            return
        }
        rescanPlugin(entry)
    }

    func removeSafeModeSuspectFromSession() {
        guard let persisted = loadedSession, let fingerprint = safeModeSuspect?.pluginFingerprint
        else {
            return
        }
        let retained = persisted.document.slots
            .filter { $0.pluginFingerprint != fingerprint }
            .map(\.slotID)
        let reduced = SessionRecoveryPlanner.reducedSession(
            from: persisted,
            retaining: retained,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        do {
            try sessionStore.save(reduced)
            loadedSession = reduced
            lastError = nil
        } catch {
            lastError = "The suspect plug-in could not be removed atomically."
        }
    }

    func resetSessionFromSafeMode() {
        guard !blockedPluginStateInvalid else {
            lastError = RecoveryControlError.blockedPluginStateInvalid.localizedDescription
            return
        }
        let document = SessionDocument(
            schemaVersion: SessionDocument.currentSchemaVersion,
            id: settings.lastSessionID,
            name: "Default",
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            slots: []
        )
        let empty = PersistedSession(document: document, pluginStates: [:])
        do {
            try sessionStore.save(empty)
            loadedSession = empty
            continueFromSafeModeWithEmptyChain()
        } catch {
            lastError = "The session could not be reset atomically."
        }
    }

    func continueFromSafeModeWithEmptyChain() {
        guard
            safeModeReason != nil,
            !persistenceBlocksRouting,
            !blockedPluginStateInvalid
        else {
            if blockedPluginStateInvalid {
                lastError = RecoveryControlError.blockedPluginStateInvalid.localizedDescription
            }
            return
        }
        guard recordRunOperation("safeModeEmptyChain", routingWasActive: false) else {
            return
        }
        ephemeralReducedChain = true
        failedRestoreSlotIDs.removeAll()
        pluginSlots = []
        sessionWorkflow = .complete
        lastError = nil
        refreshEnvironment()
    }

    func recoverAfterWake() {
        guard !wakeRecoveryInProgress, safeModeReason == nil else {
            return
        }
        wakeRecoveryInProgress = true
        defer { wakeRecoveryInProgress = false }

        let wasRouting = routingBeforeSleep
        routingBeforeSleep = false
        cancelStartRoutingAtLaunch()
        guard recordRunOperation("wakeRevalidation", routingWasActive: false) else {
            return
        }

        let pluginsValidated: Bool
        do {
            try validateSavedPluginFingerprintsForWake()
            pluginsValidated = true
        } catch {
            lastError = error.localizedDescription
            apply(.engineFailed(.unexpectedEngineState))
            return
        }

        refreshEnvironment()
        let decision = WakeRecoveryPolicy.decide(
            wasRoutingBeforeSleep: wasRouting,
            resumeAfterWake: settings.resumeAfterWake,
            environmentReady: state == .readyStopped,
            sessionReady: canStartRouting,
            pluginsValidated: pluginsValidated
        )
        if decision == .restart {
            startRouting()
        }
    }

    func failClosedForDeviceEvent(_ event: ApplicationEvent, message: String) {
        pendingAudioOperation = nil
        operationAfterStop = nil
        resumeAfterOperation = false
        bridge.setMasterMuted(true)
        bridge.stop()
        configuredOutputTarget = nil
        cancelPreviewSession()
        isMuted = false
        lastError = message
        apply(event)
        _ = recordRunOperation("deviceRecoveryBlocked", routingWasActive: false)
    }

    func attemptOneDeviceReset(issue: BlockingIssue, wasRouting: Bool) {
        let decision = DeviceResetPolicy.decide(
            issue: issue,
            resetAlreadyAttempted: deviceRecoveryAttempted,
            configuredBufferFrames: bufferFrames
        )
        guard decision == .attemptOnce else {
            apply(.engineFailed(issue))
            return
        }
        deviceRecoveryAttempted = true
        apply(.engineFailed(issue))
        refreshEnvironment(preserveDeviceRecoveryAttempt: true)
        if state == .readyStopped, wasRouting, canStartRouting {
            startRouting()
        }
    }

    private func validateSavedPluginFingerprintsForWake() throws {
        guard !blockedPluginStateInvalid else {
            throw RecoveryControlError.blockedPluginStateInvalid
        }
        for slot in pluginSlots {
            guard !blockedPluginFingerprints.contains(slot.fingerprint) else {
                throw RecoveryControlError.blockedPlugin(slot.name)
            }
            _ = try pluginCatalog.runtimeDescriptor(
                fingerprint: slot.fingerprint,
                approvedAdHocFingerprints: approvedAdHocFingerprints
            )
        }
    }

    private func safeModeMessage(_ reason: SafeModeReason) -> String {
        switch reason {
        case .previousRunUnclean:
            "The previous run did not shut down cleanly."
        case .pluginLoadInterrupted(let name):
            "The previous run ended while loading \(name)."
        case .rapidCrashLoop:
            "Three consecutive runs ended within 30 seconds."
        case .repeatedPluginCrash(let name):
            "\(name) caused three consecutive interrupted loads and is blocked."
        case .clockReversal:
            "The system clock moved backwards; crash evidence was retained."
        case .runStateInvalid:
            "Run-state data is corrupt or from an unsupported future schema."
        case .runStateWriteFailed:
            "Run-state could not be written before a safety-sensitive operation."
        case .stateMigrationFailed:
            "Saved state could not be migrated safely."
        }
    }
}
