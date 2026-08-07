// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import AppKit
import Foundation

@MainActor
extension AppModel {
    var filteredPlugins: [PluginCatalogEntry] {
        pluginCatalog.document.entries.filter { entry in
            let compatibilityMatches: Bool
            switch pluginCompatibilityFilter {
            case .all:
                compatibilityMatches = true
            case .compatible:
                compatibilityMatches = entry.compatibility == .compatible
            case .incompatible:
                compatibilityMatches = entry.compatibility == .incompatible
            case .blocked:
                compatibilityMatches = entry.compatibility == .blocked
            }
            let manufacturerMatches =
                pluginManufacturerFilter == "All Manufacturers"
                || entry.manufacturer == pluginManufacturerFilter
            let searchMatches =
                pluginSearchText.isEmpty
                || entry.name.localizedCaseInsensitiveContains(pluginSearchText)
                || entry.manufacturer.localizedCaseInsensitiveContains(pluginSearchText)
            return compatibilityMatches && manufacturerMatches && searchMatches
        }
    }

    var pluginManufacturers: [String] {
        ["All Manufacturers"]
            + Set(pluginCatalog.document.entries.map(\.manufacturer)).sorted()
    }

    func restoreSavedSession() {
        guard !persistenceBlocksRouting else {
            return
        }
        do {
            guard let persisted = try sessionStore.load(id: settings.lastSessionID) else {
                sessionWorkflow = .notLoaded
                cancelStartRoutingAtLaunch()
                isOnboardingPresented = true
                onboardingStep = .welcome
                return
            }
            loadedSession = persisted
            isOnboardingPresented = false
            guard settings.restoreLastSession else {
                sessionWorkflow = .restoreSkipped
                cancelStartRoutingAtLaunch()
                return
            }
            beginRestore(persisted)
        } catch {
            cancelStartRoutingAtLaunch()
            sessionWorkflow = .incomplete(error.localizedDescription)
            lastError =
                "The saved session could not be validated. Routing remains stopped. \(error.localizedDescription)"
        }
    }

    func retrySessionRestore() {
        requestRecoveryOperation(.retrySessionRestore)
    }

    func rescanAndRetrySessionRestore() {
        requestRecoveryOperation(.rescanAndRetrySessionRestore)
    }

    func removeUnavailablePluginsFromSession() {
        requestRecoveryOperation(.removeUnavailablePlugins)
    }

    func startWithoutUnavailablePlugins() {
        requestRecoveryOperation(.startWithoutUnavailablePlugins)
    }

    func requestAddPlugin(_ entry: PluginCatalogEntry) {
        guard canAddPlugin else {
            return
        }
        guard entry.compatibility == .compatible else {
            lastError = "This plug-in is not compatible with the v0.1 stereo chain."
            return
        }
        guard !blockedPluginFingerprints.contains(entry.fingerprint) else {
            lastError =
                "This exact plug-in fingerprint is blocked after repeated load crashes."
            return
        }
        if entry.signatureKind == .adHoc,
            !approvedAdHocFingerprints.contains(entry.fingerprint)
        {
            lastError =
                "Approve this exact ad-hoc plug-in fingerprint before adding it to the chain."
            return
        }
        requestAudioOperation(.addPlugin(entry.fingerprint))
    }

    func approveAdHocPluginAndAdd(_ entry: PluginCatalogEntry) {
        guard
            canAddPlugin,
            settings.pluginPolicy.allowAdHocSignedPlugins,
            entry.signatureKind == .adHoc
        else {
            lastError = "Ad-hoc signed plug-ins are disabled in Settings."
            return
        }
        approvedAdHocFingerprints.insert(entry.fingerprint)
        requestAudioOperation(.addPlugin(entry.fingerprint))
    }

    func requestRemovePlugin(_ slotID: UUID) {
        guard canEditPluginChain else {
            return
        }
        requestAudioOperation(.removePlugin(slotID))
    }

    func requestMovePlugin(_ slotID: UUID, to index: Int) {
        guard canEditPluginChain else {
            return
        }
        requestAudioOperation(.movePlugin(slotID, index))
    }

    func requestSaveSession() {
        guard canEditPluginChain else {
            return
        }
        requestAudioOperation(.saveSession)
    }

    func confirmPendingAudioOperation() {
        guard let pendingAudioOperation else {
            return
        }
        self.pendingAudioOperation = nil
        resumeAfterOperation = isRoutingActive
        if isRoutingActive {
            operationAfterStop = pendingAudioOperation
            stopRouting()
        } else {
            execute(pendingAudioOperation)
        }
    }

    func cancelPendingAudioOperation() {
        pendingAudioOperation = nil
    }

    func performOperationAfterStopIfNeeded() {
        guard let operationAfterStop else {
            return
        }
        self.operationAfterStop = nil
        execute(operationAfterStop)
    }

    func setPluginBypassed(_ slotID: UUID, bypassed: Bool) {
        guard canEditPluginChain else {
            return
        }
        requestAudioOperation(.setPluginBypassed(slotID, bypassed))
    }

    func setAllPluginsBypassed(_ bypassed: Bool) {
        guard canEditPluginChain else {
            return
        }
        requestAudioOperation(.setAllPluginsBypassed(bypassed))
    }

    func openPluginEditor(_ slotID: UUID) {
        guard canEditPluginChain else {
            return
        }
        do {
            try bridge.openEditorForPluginSlot(with: slotID)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restoreSavedSessionFromSafeMode() {
        guard let persisted = loadedSession, let originalReason = safeModeReason else {
            return
        }
        guard recordRunOperation("safeModeRestore", routingWasActive: false) else {
            return
        }
        apply(.recoveryStarted)
        restoreStrictSession(persisted) { [weak self] success in
            guard let self else {
                return
            }
            if success {
                apply(.recoveryCompleted)
                refreshEnvironment()
                return
            }
            clearRuntimeSlots { [weak self] _ in
                self?.enterSafeMode(originalReason)
            }
        }
    }

    @discardableResult
    func rescanPlugins() -> Bool {
        do {
            let result = try pluginCatalog.refreshDiscoveredBundles(
                inAdditionalFolders: additionalPluginFolders,
                approvedAdHocFingerprints: approvedAdHocFingerprints
            )
            pluginCatalogError =
                result.failedBundlePaths.isEmpty
                ? nil
                : "Some VST3 plug-ins failed validation and remain unavailable."
            return true
        } catch {
            pluginCatalogError = "The plug-in scan failed safely. \(error.localizedDescription)"
            return false
        }
    }

    func rescanPlugin(_ entry: PluginCatalogEntry) {
        do {
            let approved =
                approvedAdHocFingerprints.contains(entry.fingerprint)
                ? Set([entry.fingerprint]) : []
            try pluginCatalog.rescanBundle(
                at: entry.bundlePath,
                approvedAdHocFingerprints: approved
            )
            pluginCatalogError = nil
        } catch {
            pluginCatalogError = "\(entry.name) failed validation and remains unavailable."
        }
    }

    func addPluginFolder(_ url: URL) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !additionalPluginFolders.contains(path) else {
            return
        }
        let candidate = additionalPluginFolders + [path]
        do {
            let validated = try bridgePluginFolders(candidate)
            try auxiliaryStore.saveScanFolders(
                ScanFoldersDocument(schemaVersion: 1, folders: validated)
            )
            additionalPluginFolders = validated
            rescanPlugins()
        } catch {
            pluginCatalogError = "The selected VST3 folder is not allowed."
        }
    }

    func removePluginFolder(_ path: String) {
        let candidate = additionalPluginFolders.filter { $0 != path }
        do {
            try auxiliaryStore.saveScanFolders(
                ScanFoldersDocument(schemaVersion: 1, folders: candidate)
            )
            additionalPluginFolders = candidate
            rescanPlugins()
        } catch {
            pluginCatalogError = "The VST3 folder list could not be saved."
        }
    }

    func saveCurrentSession(
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard beginSessionSave() else {
            completion(false)
            return
        }
        sessionWorkflow = .saving
        refreshPluginSlots()
        let slots = pluginSlots
        capturePluginStates(slots: slots, index: 0, states: [:]) { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .failure(let error):
                sessionWorkflow = .incomplete(error.localizedDescription)
                lastError = "Plug-in state could not be saved. Routing remains stopped."
                recordSessionSaveFinished(success: false)
                completion(false)
                continueTerminationIfPossible()
            case .success(let states):
                do {
                    let session = try makePersistedSession(slots: slots, states: states)
                    try sessionStore.save(session)
                    loadedSession = session
                    sessionWorkflow = .complete
                    ephemeralReducedChain = false
                    recordSessionSaveFinished(success: true)
                    completion(true)
                    continueTerminationIfPossible()
                } catch {
                    persistenceBlocksRouting = true
                    sessionWorkflow = .incomplete(error.localizedDescription)
                    lastError =
                        "The session could not be published atomically. Routing remains stopped."
                    recordSessionSaveFinished(success: false)
                    completion(false)
                    continueTerminationIfPossible()
                }
            }
        }
    }

    func refreshPluginSlots() {
        pluginSlots = bridge.pluginSlots().map { slot in
            PluginSlotPresentation(
                id: slot.slotID,
                fingerprint: slot.fingerprint,
                name: slot.name,
                manufacturer: slot.manufacturer,
                version: slot.version,
                isBypassed: slot.isBypassed,
                isFaulted: slot.isFaulted,
                latencySamples: slot.latencySamples,
                hasEditor: slot.hasEditor
            )
        }
    }

    private func requestAudioOperation(_ operation: PendingAudioOperation) {
        guard !isPluginOperationInFlight else {
            return
        }
        if isRoutingActive {
            pendingAudioOperation = operation
        } else {
            resumeAfterOperation = false
            execute(operation)
        }
    }

    private func requestRecoveryOperation(_ operation: PendingAudioOperation) {
        guard canRecoverSession else {
            return
        }
        if isRoutingActive {
            pendingAudioOperation = operation
        } else {
            resumeAfterOperation = false
            execute(operation)
        }
    }

    private func execute(_ operation: PendingAudioOperation) {
        guard !isPluginOperationInFlight else {
            return
        }
        isPluginOperationInFlight = true
        switch operation {
        case .saveSession:
            saveCurrentSession { [weak self] success in
                self?.finishAudioOperation(success: success)
            }
            return
        case .retrySessionRestore, .rescanAndRetrySessionRestore,
            .removeUnavailablePlugins, .startWithoutUnavailablePlugins:
            performRecovery(operation)
            return
        case .addPlugin, .removePlugin, .movePlugin, .setPluginBypassed,
            .setAllPluginsBypassed:
            break
        }

        saveCurrentSession { [weak self] saved in
            guard let self else {
                return
            }
            guard saved else {
                finishAudioOperation(success: false)
                return
            }
            performMutation(operation)
        }
    }

    private func performMutation(_ operation: PendingAudioOperation) {
        switch operation {
        case .addPlugin(let fingerprint):
            do {
                guard
                    let entry = pluginCatalog.document.entries.first(where: {
                        $0.fingerprint == fingerprint
                    })
                else {
                    throw PluginSessionError.catalogEntryMissing(fingerprint)
                }
                let descriptor = try pluginCatalog.runtimeDescriptor(
                    fingerprint: fingerprint,
                    approvedAdHocFingerprints: approvedAdHocFingerprints
                )
                let slotID = UUID()
                try beginTrackedPluginLoad(
                    slotID: slotID,
                    fingerprint: fingerprint,
                    name: entry.name
                )
                bridge.add(
                    descriptor,
                    slotID: slotID,
                    state: nil
                ) { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self else {
                            return
                        }
                        guard finishTrackedPluginLoad() else {
                            completeMutation(
                                error: RunStateServiceError.persistence(
                                    "plug-in load completion could not be recorded"
                                )
                            )
                            return
                        }
                        completeMutation(error: error)
                    }
                }
            } catch {
                completeMutation(error: error)
            }
        case .removePlugin(let slotID):
            bridge.removePluginSlot(with: slotID) { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.completeMutation(error: error)
                }
            }
        case .movePlugin(let slotID, let index):
            bridge.movePluginSlot(with: slotID, to: index) { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.completeMutation(error: error)
                }
            }
        case .setPluginBypassed(let slotID, let bypassed):
            do {
                try bridge.setPluginSlotWith(slotID, bypassed: bypassed)
                completeMutation(error: nil)
            } catch {
                completeMutation(error: error)
            }
        case .setAllPluginsBypassed(let bypassed):
            setAllPluginsBypassedTransactionally(bypassed)
        case .saveSession, .retrySessionRestore, .rescanAndRetrySessionRestore,
            .removeUnavailablePlugins, .startWithoutUnavailablePlugins:
            finishAudioOperation(success: false)
        }
    }

    private func setAllPluginsBypassedTransactionally(_ bypassed: Bool) {
        let previous = Dictionary(
            uniqueKeysWithValues: pluginSlots.map { ($0.id, $0.isBypassed) }
        )
        var changed: [UUID] = []
        do {
            for slot in pluginSlots where slot.isBypassed != bypassed {
                try bridge.setPluginSlotWith(slot.id, bypassed: bypassed)
                changed.append(slot.id)
            }
            completeMutation(error: nil)
        } catch {
            for slotID in changed.reversed() {
                if let original = previous[slotID] {
                    try? bridge.setPluginSlotWith(slotID, bypassed: original)
                }
            }
            completeMutation(error: error)
        }
    }

    private func completeMutation(error: Error?) {
        if let error {
            lastError = error.localizedDescription
            refreshPluginSlots()
            finishAudioOperation(success: false)
            return
        }
        refreshPluginSlots()
        saveCurrentSession { [weak self] success in
            self?.finishAudioOperation(success: success)
        }
    }

    private func finishAudioOperation(success: Bool) {
        isPluginOperationInFlight = false
        let shouldResume = success && resumeAfterOperation
        resumeAfterOperation = false
        if shouldResume, canStartRouting {
            startRouting()
        }
        continueTerminationIfPossible()
    }

    func handleEngineStoppedWorkflow() {
        let hadPendingOperation = operationAfterStop != nil
        performOperationAfterStopIfNeeded()
        if !hadPendingOperation,
            !terminationIsPending,
            sessionWorkflow == .complete,
            !ephemeralReducedChain,
            !isPluginOperationInFlight
        {
            execute(.saveSession)
        }
        continueTerminationIfPossible()
    }

    private func performRecovery(_ operation: PendingAudioOperation) {
        guard let persisted = loadedSession else {
            sessionWorkflow = .notLoaded
            finishAudioOperation(success: false)
            return
        }
        clearRuntimeSlots { [weak self] removalError in
            guard let self else {
                return
            }
            if let removalError {
                let message =
                    "The current runtime chain could not be cleared. "
                    + removalError.localizedDescription
                handleRestoreFailure(
                    slotID: nil,
                    message: message
                )
                finishAudioOperation(success: false)
                return
            }

            switch operation {
            case .retrySessionRestore:
                restoreStrictSession(persisted) { [weak self] success in
                    self?.finishAudioOperation(success: success)
                }
            case .rescanAndRetrySessionRestore:
                guard rescanPlugins() else {
                    handleRestoreFailure(
                        slotID: nil,
                        message: "The plug-in rescan failed."
                    )
                    finishAudioOperation(success: false)
                    return
                }
                restoreStrictSession(persisted) { [weak self] success in
                    self?.finishAudioOperation(success: success)
                }
            case .removeUnavailablePlugins, .startWithoutUnavailablePlugins:
                sessionWorkflow = .restoring
                failedRestoreSlotIDs.removeAll()
                restoreAvailableSlots(
                    in: persisted,
                    index: 0,
                    restoredSlotIDs: [],
                    failures: [:]
                ) { [weak self] restoredSlotIDs, failures, blockingError in
                    guard let self else {
                        return
                    }
                    if let blockingError {
                        handleRestoreFailure(
                            slotID: nil,
                            message: blockingError.localizedDescription
                        )
                        finishAudioOperation(success: false)
                    } else {
                        finishBestEffortRecovery(
                            operation,
                            persisted: persisted,
                            restoredSlotIDs: restoredSlotIDs,
                            failures: failures
                        )
                    }
                }
            case .addPlugin, .removePlugin, .movePlugin, .setPluginBypassed,
                .setAllPluginsBypassed, .saveSession:
                finishAudioOperation(success: false)
            }
        }
    }

    private func beginRestore(_ persisted: PersistedSession) {
        restoreStrictSession(persisted) { [weak self] success in
            guard let self else {
                return
            }
            if success {
                attemptStartRoutingAtLaunch()
            }
            continueTerminationIfPossible()
        }
    }

    private func restoreStrictSession(
        _ persisted: PersistedSession,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        sessionWorkflow = .restoring
        ephemeralReducedChain = false
        failedRestoreSlotIDs.removeAll()
        restoreStrictSlot(in: persisted, index: 0, completion: completion)
    }

    private func restoreStrictSlot(
        in persisted: PersistedSession,
        index: Int,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard index < persisted.document.slots.count else {
            refreshPluginSlots()
            failedRestoreSlotIDs.removeAll()
            sessionWorkflow = .complete
            completion(true)
            return
        }
        let slot = persisted.document.slots[index]
        guard let state = persisted.pluginStates[slot.slotID] else {
            handleRestoreFailure(
                slotID: slot.slotID,
                message: "State data is missing for \(slot.name)."
            )
            completion(false)
            return
        }
        do {
            let descriptor = try pluginCatalog.runtimeDescriptor(
                fingerprint: slot.pluginFingerprint,
                approvedAdHocFingerprints: approvedAdHocFingerprints
            )
            try beginTrackedPluginLoad(
                slotID: slot.slotID,
                fingerprint: slot.pluginFingerprint,
                name: slot.name
            )
            bridge.add(
                descriptor,
                slotID: slot.slotID,
                state: state
            ) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    guard finishTrackedPluginLoad() else {
                        completion(false)
                        return
                    }
                    if let error {
                        handleRestoreFailure(
                            slotID: slot.slotID,
                            message: error.localizedDescription
                        )
                        completion(false)
                        return
                    }
                    if slot.bypassed {
                        do {
                            try bridge.setPluginSlotWith(slot.slotID, bypassed: true)
                        } catch {
                            removeSlotAfterBypassFailure(
                                slot,
                                bypassError: error,
                                completion: completion
                            )
                            return
                        }
                    }
                    restoreStrictSlot(
                        in: persisted,
                        index: index + 1,
                        completion: completion
                    )
                }
            }
        } catch {
            handleRestoreFailure(slotID: slot.slotID, message: error.localizedDescription)
            completion(false)
        }
    }

    private func restoreAvailableSlots(
        in persisted: PersistedSession,
        index: Int,
        restoredSlotIDs: [UUID],
        failures: [UUID: String],
        completion:
            @escaping @MainActor @Sendable (
                [UUID],
                [UUID: String],
                Error?
            ) -> Void
    ) {
        guard index < persisted.document.slots.count else {
            refreshPluginSlots()
            completion(restoredSlotIDs, failures, nil)
            return
        }
        let slot = persisted.document.slots[index]
        guard let state = persisted.pluginStates[slot.slotID] else {
            var nextFailures = failures
            nextFailures[slot.slotID] = "State data is missing for \(slot.name)."
            restoreAvailableSlots(
                in: persisted,
                index: index + 1,
                restoredSlotIDs: restoredSlotIDs,
                failures: nextFailures,
                completion: completion
            )
            return
        }

        do {
            let descriptor = try pluginCatalog.runtimeDescriptor(
                fingerprint: slot.pluginFingerprint,
                approvedAdHocFingerprints: approvedAdHocFingerprints
            )
            try beginTrackedPluginLoad(
                slotID: slot.slotID,
                fingerprint: slot.pluginFingerprint,
                name: slot.name
            )
            bridge.add(descriptor, slotID: slot.slotID, state: state) { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    guard finishTrackedPluginLoad() else {
                        completion(
                            restoredSlotIDs,
                            failures,
                            RunStateServiceError.persistence(
                                "plug-in load completion could not be recorded"
                            )
                        )
                        return
                    }
                    if let error {
                        var nextFailures = failures
                        nextFailures[slot.slotID] = error.localizedDescription
                        restoreAvailableSlots(
                            in: persisted,
                            index: index + 1,
                            restoredSlotIDs: restoredSlotIDs,
                            failures: nextFailures,
                            completion: completion
                        )
                        return
                    }
                    if slot.bypassed {
                        do {
                            try bridge.setPluginSlotWith(slot.slotID, bypassed: true)
                        } catch {
                            removeBestEffortSlotAfterBypassFailure(
                                slot,
                                bypassError: error,
                                persisted: persisted,
                                nextIndex: index + 1,
                                restoredSlotIDs: restoredSlotIDs,
                                failures: failures,
                                completion: completion
                            )
                            return
                        }
                    }
                    restoreAvailableSlots(
                        in: persisted,
                        index: index + 1,
                        restoredSlotIDs: restoredSlotIDs + [slot.slotID],
                        failures: failures,
                        completion: completion
                    )
                }
            }
        } catch {
            var nextFailures = failures
            nextFailures[slot.slotID] = error.localizedDescription
            restoreAvailableSlots(
                in: persisted,
                index: index + 1,
                restoredSlotIDs: restoredSlotIDs,
                failures: nextFailures,
                completion: completion
            )
        }
    }

    private func removeSlotAfterBypassFailure(
        _ slot: SessionSlotDocument,
        bypassError: Error,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let bypassMessage = bypassError.localizedDescription
        bridge.removePluginSlot(with: slot.slotID) { [weak self] removalError in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                let message: String
                if let removalError {
                    message =
                        "The saved bypass state failed and the active slot could not be removed. "
                        + removalError.localizedDescription
                } else {
                    message = "The saved bypass state could not be restored. \(bypassMessage)"
                }
                handleRestoreFailure(slotID: slot.slotID, message: message)
                completion(false)
            }
        }
    }

    private func removeBestEffortSlotAfterBypassFailure(
        _ slot: SessionSlotDocument,
        bypassError: Error,
        persisted: PersistedSession,
        nextIndex: Int,
        restoredSlotIDs: [UUID],
        failures: [UUID: String],
        completion:
            @escaping @MainActor @Sendable (
                [UUID],
                [UUID: String],
                Error?
            ) -> Void
    ) {
        let bypassMessage = bypassError.localizedDescription
        bridge.removePluginSlot(with: slot.slotID) { [weak self] removalError in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                if let removalError {
                    let message =
                        "The failed bypass slot could not be removed. "
                        + removalError.localizedDescription
                    completion(
                        restoredSlotIDs,
                        failures,
                        PluginSessionError.bridge(message)
                    )
                    return
                }
                var nextFailures = failures
                nextFailures[slot.slotID] =
                    "The saved bypass state could not be restored. \(bypassMessage)"
                restoreAvailableSlots(
                    in: persisted,
                    index: nextIndex,
                    restoredSlotIDs: restoredSlotIDs,
                    failures: nextFailures,
                    completion: completion
                )
            }
        }
    }

    private func finishBestEffortRecovery(
        _ operation: PendingAudioOperation,
        persisted: PersistedSession,
        restoredSlotIDs: [UUID],
        failures: [UUID: String]
    ) {
        failedRestoreSlotIDs = Set(failures.keys)
        let reduced = SessionRecoveryPlanner.reducedSession(
            from: persisted,
            retaining: restoredSlotIDs,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )

        if operation == .removeUnavailablePlugins {
            do {
                try sessionStore.save(reduced)
                loadedSession = reduced
                failedRestoreSlotIDs.removeAll()
                sessionWorkflow = .complete
                ephemeralReducedChain = false
                lastError = nil
                finishAudioOperation(success: true)
            } catch {
                persistenceBlocksRouting = true
                handleRestoreFailure(
                    slotID: nil,
                    message: "The reduced session could not be published atomically."
                )
                finishAudioOperation(success: false)
            }
            return
        }

        let omittedCount = failures.count
        ephemeralReducedChain = omittedCount > 0
        sessionWorkflow =
            omittedCount == 0
            ? .complete
            : .incomplete(
                "A temporary chain uses \(restoredSlotIDs.count) of \(persisted.document.slots.count) saved plug-ins. The saved session is unchanged."
            )
        lastError =
            omittedCount == 0
            ? nil
            : "The temporary chain omitted \(omittedCount) unavailable plug-in(s)."
        isPluginOperationInFlight = false
        resumeAfterOperation = false
        if canStartRouting {
            startRouting()
        }
        continueTerminationIfPossible()
    }

    private func handleRestoreFailure(slotID: UUID?, message: String) {
        cancelStartRoutingAtLaunch()
        if let slotID {
            failedRestoreSlotIDs.insert(slotID)
        }
        refreshPluginSlots()
        sessionWorkflow = .incomplete(message)
        lastError =
            "The saved chain is incomplete. Routing remains stopped until you choose a recovery action."
        continueTerminationIfPossible()
    }

    private func clearRuntimeSlots(
        completion: @escaping @MainActor @Sendable (Error?) -> Void
    ) {
        let identifiers = bridge.pluginSlots().map(\.slotID)
        removeRuntimeSlot(identifiers, index: 0, completion: completion)
    }

    private func removeRuntimeSlot(
        _ identifiers: [UUID],
        index: Int,
        completion: @escaping @MainActor @Sendable (Error?) -> Void
    ) {
        guard index < identifiers.count else {
            refreshPluginSlots()
            completion(nil)
            return
        }
        bridge.removePluginSlot(with: identifiers[index]) { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                if let error {
                    refreshPluginSlots()
                    completion(error)
                    return
                }
                removeRuntimeSlot(
                    identifiers,
                    index: index + 1,
                    completion: completion
                )
            }
        }
    }

    private func capturePluginStates(
        slots: [PluginSlotPresentation],
        index: Int,
        states: [UUID: Data],
        completion:
            @escaping @MainActor @Sendable (
                Result<[UUID: Data], PluginSessionError>
            ) -> Void
    ) {
        guard index < slots.count else {
            completion(.success(states))
            return
        }
        let slot = slots[index]
        bridge.saveStateForPluginSlot(with: slot.id) { [weak self] data, error in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                if let error {
                    completion(.failure(.bridge(error.localizedDescription)))
                    return
                }
                guard let data else {
                    completion(.failure(.missingState(slot.id)))
                    return
                }
                var next = states
                next[slot.id] = data
                capturePluginStates(
                    slots: slots,
                    index: index + 1,
                    states: next,
                    completion: completion
                )
            }
        }
    }

    private func makePersistedSession(
        slots: [PluginSlotPresentation],
        states: [UUID: Data]
    ) throws -> PersistedSession {
        let entries = Dictionary(
            uniqueKeysWithValues: pluginCatalog.document.entries.map { ($0.fingerprint, $0) }
        )
        let documents = try slots.enumerated().map { index, slot in
            guard let entry = entries[slot.fingerprint] else {
                throw PluginSessionError.catalogEntryMissing(slot.fingerprint)
            }
            return SessionSlotDocument(
                slotID: slot.id,
                order: index,
                pluginFingerprint: slot.fingerprint,
                bundlePath: entry.bundlePath,
                classUID: entry.classUID,
                name: slot.name,
                manufacturer: slot.manufacturer,
                version: slot.version,
                bypassed: slot.isBypassed,
                stateFile: SessionSlotDocument.stateFile(for: slot.id)
            )
        }
        let document = SessionDocument(
            schemaVersion: 1,
            id: settings.lastSessionID,
            name: loadedSession?.document.name ?? "Default",
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            slots: documents
        )
        return PersistedSession(document: document, pluginStates: states)
    }

    private func bridgePluginFolders(_ folders: [String]) throws -> [String] {
        try pluginCatalog.validatedAdditionalFolders(folders)
    }
}

private enum PluginSessionError: Error, LocalizedError, Sendable {
    case missingState(UUID)
    case catalogEntryMissing(String)
    case bridge(String)

    var errorDescription: String? {
        switch self {
        case .missingState:
            "A plug-in returned no state data."
        case .catalogEntryMissing:
            "A runtime plug-in no longer has a validated catalog entry."
        case .bridge(let message):
            message
        }
    }
}
