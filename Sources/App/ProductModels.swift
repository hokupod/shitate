// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Foundation

enum ProductSection: String, CaseIterable, Identifiable {
    case dashboard
    case chain
    case plugins
    case diagnostics
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .chain: "Chain"
        case .plugins: "Plug-ins"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .dashboard: "waveform"
        case .chain: "point.3.connected.trianglepath.dotted"
        case .plugins: "puzzlepiece.extension"
        case .diagnostics: "stethoscope"
        case .about: "info.circle"
        }
    }
}

struct ApplicationStatePresentation: Equatable {
    let title: String
    let detail: String
    let symbol: String
    let outputIsStopped: Bool
    let nextAction: String?

    init(state: ApplicationState) {
        switch state {
        case .booting, .checkingEnvironment:
            self.init(
                title: "Checking Audio",
                detail: "Shi-tate is validating the saved audio path. Output remains silent.",
                symbol: "waveform.circle",
                outputIsStopped: true,
                nextAction: nil
            )
        case .safeMode:
            self.init(
                title: "Safe Mode",
                detail:
                    "The previous run did not finish cleanly. Routing and plug-in loading are stopped.",
                symbol: "exclamationmark.shield",
                outputIsStopped: true,
                nextAction: "Review recovery details before continuing."
            )
        case .needsBlackHole:
            self.init(
                title: "BlackHole Required",
                detail:
                    "BlackHole 2ch is unavailable or changed. No alternate output was selected.",
                symbol: "exclamationmark.triangle",
                outputIsStopped: true,
                nextAction: "Install or confirm BlackHole 2ch, then check again."
            )
        case .needsMicrophonePermission:
            self.init(
                title: "Microphone Access Required",
                detail: "Microphone access is unavailable. Routing stopped and output is silent.",
                symbol: "exclamationmark.triangle",
                outputIsStopped: true,
                nextAction: "Allow access in System Settings, then check again."
            )
        case .needsAudioConfiguration:
            self.init(
                title: "Audio Setup Required",
                detail: "The saved audio configuration is incomplete. Output remains silent.",
                symbol: "exclamationmark.triangle",
                outputIsStopped: true,
                nextAction: "Choose a supported input, channel, and buffer in Settings."
            )
        case .readyStopped:
            self.init(
                title: "Ready",
                detail: "Audio and the plug-in chain are validated. Routing is stopped.",
                symbol: "waveform.circle",
                outputIsStopped: true,
                nextAction: "Start routing when the call app is using BlackHole 2ch."
            )
        case .starting:
            self.init(
                title: "Starting",
                detail: "Shi-tate is starting the validated audio path.",
                symbol: "waveform.circle",
                outputIsStopped: false,
                nextAction: nil
            )
        case .running:
            self.init(
                title: "Routing",
                detail: "The selected input is routed through the chain to BlackHole 2ch.",
                symbol: "waveform.circle.fill",
                outputIsStopped: false,
                nextAction: nil
            )
        case .muted:
            self.init(
                title: "Muted",
                detail: "Routing is active, but master output is muted.",
                symbol: "mic.slash",
                outputIsStopped: false,
                nextAction: "Unmute to restore output."
            )
        case .stopping:
            self.init(
                title: "Stopping",
                detail: "Shi-tate is fading and stopping the audio path.",
                symbol: "waveform.circle",
                outputIsStopped: false,
                nextAction: nil
            )
        case .recovering:
            self.init(
                title: "Recovering",
                detail: "Shi-tate is validating recovery state. Routing remains stopped.",
                symbol: "arrow.clockwise.circle",
                outputIsStopped: true,
                nextAction: nil
            )
        case .blocked:
            self.init(
                title: "Routing Blocked",
                detail: "A required device, format, or operation failed. Routing stopped safely.",
                symbol: "exclamationmark.triangle",
                outputIsStopped: true,
                nextAction: "Review the error and Audio Settings, then retry."
            )
        case .fatal:
            self.init(
                title: "Fatal Error",
                detail: "Shi-tate cannot continue safely. Routing is stopped and output is silent.",
                symbol: "xmark.octagon",
                outputIsStopped: true,
                nextAction: "Quit Shi-tate and review Diagnostics before restarting."
            )
        }
    }

    private init(
        title: String,
        detail: String,
        symbol: String,
        outputIsStopped: Bool,
        nextAction: String?
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.outputIsStopped = outputIsStopped
        self.nextAction = nextAction
    }
}

struct PluginSlotPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let fingerprint: String
    let name: String
    let manufacturer: String
    let version: String
    var isBypassed: Bool
    var isFaulted: Bool
    let latencySamples: Int
    let hasEditor: Bool
}

enum SessionWorkflowState: Equatable, Sendable {
    case notLoaded
    case restoreSkipped
    case restoring
    case complete
    case saving
    case incomplete(String)
}

enum EngineStatusEventMapper {
    static func event(
        for status: STEngineStatus,
        while state: ApplicationState
    ) -> ApplicationEvent {
        switch status {
        case .stopped:
            .engineStopped
        case .configured:
            state == .stopping ? .engineStopped : .engineConfigured
        case .starting:
            .startRequested
        case .running:
            .engineStarted
        case .muted:
            .muteChanged(true)
        case .stopping:
            .stopRequested
        case .blocked:
            .engineBlocked
        @unknown default:
            .engineFailed(.unexpectedEngineState)
        }
    }
}

enum PendingAudioOperation: Equatable, Sendable {
    case addPlugin(String)
    case removePlugin(UUID)
    case movePlugin(UUID, Int)
    case setPluginBypassed(UUID, Bool)
    case setAllPluginsBypassed(Bool)
    case saveSession
    case retrySessionRestore
    case rescanAndRetrySessionRestore
    case removeUnavailablePlugins
    case startWithoutUnavailablePlugins

    var interruptionMessage: String {
        switch self {
        case .saveSession:
            "Saving plug-in state pauses audio briefly. Routing resumes only if the save succeeds."
        case .addPlugin, .removePlugin, .movePlugin, .setPluginBypassed,
            .setAllPluginsBypassed:
            "Changing the plug-in chain pauses audio briefly. Routing resumes only after validation and save succeed."
        case .retrySessionRestore, .rescanAndRetrySessionRestore,
            .removeUnavailablePlugins:
            "Recovering the saved chain requires routing to stop. Routing resumes only after every retained plug-in is revalidated."
        case .startWithoutUnavailablePlugins:
            "Building a temporary reduced chain requires routing to stop. The saved session will remain unchanged."
        }
    }
}

enum PluginApprovalAuthority {
    static func approvedAdHocFingerprints(
        allowAdHocSignedPlugins: Bool,
        entries: [PluginCatalogEntry]
    ) -> Set<String> {
        guard allowAdHocSignedPlugins else {
            return []
        }
        return Set(
            entries.lazy
                .filter {
                    $0.signatureKind == .adHoc && $0.compatibility == .compatible
                }
                .map(\.fingerprint)
        )
    }
}

enum SessionRecoveryPlanner {
    static func reducedSession(
        from persisted: PersistedSession,
        retaining slotIDs: [UUID],
        updatedAt: String
    ) -> PersistedSession {
        let retained = Set(slotIDs)
        let slots = persisted.document.slots
            .filter { retained.contains($0.slotID) }
            .enumerated()
            .map { index, slot in
                var value = slot
                value.order = index
                return value
            }
        var document = persisted.document
        document.updatedAt = updatedAt
        document.slots = slots
        return PersistedSession(
            document: document,
            pluginStates: Dictionary(
                uniqueKeysWithValues: slots.compactMap { slot in
                    persisted.pluginStates[slot.slotID].map { (slot.slotID, $0) }
                }
            )
        )
    }
}

enum PluginCompatibilityFilter: String, CaseIterable, Identifiable {
    case all
    case compatible
    case incompatible
    case blocked

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case blackHoleCheck
    case installGuide
    case microphonePermission
    case audioSelection
    case audioValidation
    case pluginScan
    case chainSetup
    case callAppGuide
    case complete

    var id: Int { rawValue }
}

struct OnboardingReadiness: Equatable {
    var hasBlackHole: Bool
    var hasMicrophonePermission: Bool
    var hasAudioSelection: Bool
    var audioIsValid: Bool
}

enum OnboardingFlow {
    static func next(
        after step: OnboardingStep,
        readiness: OnboardingReadiness
    ) -> OnboardingStep {
        switch step {
        case .welcome:
            .blackHoleCheck
        case .blackHoleCheck:
            readiness.hasBlackHole ? .microphonePermission : .installGuide
        case .installGuide:
            .blackHoleCheck
        case .microphonePermission:
            readiness.hasMicrophonePermission ? .audioSelection : .microphonePermission
        case .audioSelection:
            readiness.hasAudioSelection ? .audioValidation : .audioSelection
        case .audioValidation:
            readiness.audioIsValid ? .pluginScan : .audioValidation
        case .pluginScan:
            .chainSetup
        case .chainSetup:
            .callAppGuide
        case .callAppGuide, .complete:
            .complete
        }
    }
}
