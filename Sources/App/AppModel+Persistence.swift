// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Foundation

@MainActor
extension AppModel {
    var onboardingReadiness: OnboardingReadiness {
        OnboardingReadiness(
            hasBlackHole: blackHoleUID != nil && state != .needsBlackHole,
            hasMicrophonePermission: hasMicrophonePermission,
            hasAudioSelection: selectedInput != nil && !selectedInputChannels.isEmpty,
            audioIsValid: state == .readyStopped
        )
    }

    func loadUserState() {
        do {
            settings = try settingsStore.load()
            applyPersistedAudioSettings()
            additionalPluginFolders = try auxiliaryStore.loadScanFolders().folders
            persistenceBlocksRouting = false
        } catch {
            blockRoutingAfterPersistenceFailure(
                "Saved settings could not be validated. Routing remains stopped. \(error.localizedDescription)"
            )
        }
    }

    func configureSystemPreferences() {
        guard !persistenceBlocksRouting else {
            return
        }
        if !launchAtLoginService.setEnabled(settings.launchAtLogin) {
            lastError = "Launch at Login could not be updated."
        }
        configureGlobalHotKey()
    }

    func persistSettings() {
        do {
            try settingsStore.save(settings)
        } catch {
            blockRoutingAfterPersistenceFailure(
                "Settings could not be saved. Routing remains stopped. \(error.localizedDescription)"
            )
        }
    }

    private func blockRoutingAfterPersistenceFailure(_ message: String) {
        bridge.setMasterMuted(true)
        bridge.stop()
        configuredOutputTarget = nil
        cancelPreviewSession()
        persistenceBlocksRouting = true
        lastError = message
        apply(.engineFailed(.unexpectedEngineState))
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard launchAtLoginService.setEnabled(enabled) else {
            lastError = launchAtLoginService.lastError ?? "Launch at Login could not be updated."
            return
        }
        settings.launchAtLogin = enabled
        persistSettings()
    }

    func setStartRoutingAtLaunch(_ enabled: Bool) {
        settings.startRoutingAtLaunch = enabled
        persistSettings()
    }

    func setRestoreLastSession(_ enabled: Bool) {
        settings.restoreLastSession = enabled
        persistSettings()
    }

    func setGlobalMuteShortcutEnabled(_ enabled: Bool) {
        settings.globalMuteShortcutEnabled = enabled
        configureGlobalHotKey()
        persistSettings()
    }

    func setAllowAdHocSignedPlugins(_ enabled: Bool) {
        settings.pluginPolicy.allowAdHocSignedPlugins = enabled
        approvedAdHocFingerprints = PluginApprovalAuthority.approvedAdHocFingerprints(
            allowAdHocSignedPlugins: enabled,
            entries: pluginCatalog.document.entries
        )
        persistSettings()
    }

    func advanceOnboarding() {
        let next = OnboardingFlow.next(
            after: onboardingStep,
            readiness: onboardingReadiness
        )
        guard next != onboardingStep else {
            onboardingError = onboardingBlockedMessage
            return
        }
        onboardingError = nil
        onboardingStep = next
    }

    func returnToPreviousOnboardingStep() {
        guard onboardingStep.rawValue > OnboardingStep.welcome.rawValue,
            let previous = OnboardingStep(rawValue: onboardingStep.rawValue - 1)
        else {
            return
        }
        onboardingError = nil
        onboardingStep = previous
    }

    func finishOnboarding() {
        saveCurrentSession { [weak self] success in
            guard let self else {
                return
            }
            if success {
                onboardingStep = .complete
                isOnboardingPresented = false
                selectedSection = .dashboard
            } else {
                onboardingError =
                    "The default session could not be saved. Routing remains stopped."
            }
        }
    }

    private func applyPersistedAudioSettings() {
        selectedInputUID =
            settings.audio.inputDeviceUID.isEmpty
            ? nil : settings.audio.inputDeviceUID
        selectedInputChannel = settings.audio.inputChannelIndex
        routingMode =
            settings.audio.mode == .automaticPrivateAggregate
            ? .automaticPrivateAggregate : .manualAggregate
        manualOutputChannelStart = settings.audio.manualOutputChannelStart
        bufferFrames = settings.audio.bufferFrames
        blackHoleUID =
            settings.audio.outputDeviceUID.isEmpty
            ? nil : settings.audio.outputDeviceUID
    }

    private func configureGlobalHotKey() {
        globalHotKeyService.setEnabled(settings.globalMuteShortcutEnabled) { [weak self] in
            self?.toggleMute()
        }
    }

    private var onboardingBlockedMessage: String {
        switch onboardingStep {
        case .blackHoleCheck, .installGuide:
            "BlackHole 2ch must be available before setup can continue."
        case .microphonePermission:
            "Allow microphone access before setup can continue."
        case .audioSelection, .audioValidation:
            "Choose and apply a supported 48 kHz audio configuration."
        default:
            "Complete this step before continuing."
        }
    }
}
