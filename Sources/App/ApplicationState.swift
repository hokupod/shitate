// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Foundation

enum SafeModeReason: Equatable {
    case previousRunUnclean
}

enum BlockingIssue: Equatable {
    case inputDeviceMissing
    case outputDeviceMissing
    case unsupportedSampleRate
    case unsupportedBufferSize
    case aggregateDeviceCreationFailed
    case engineStartFailed
    case unexpectedEngineState
}

enum AppFailure: Equatable {
    case bridge(String)
}

enum ApplicationState: Equatable {
    case booting
    case safeMode(SafeModeReason)
    case checkingEnvironment
    case needsBlackHole
    case needsMicrophonePermission
    case needsAudioConfiguration
    case readyStopped
    case starting
    case running
    case muted
    case stopping
    case recovering
    case blocked(BlockingIssue)
    case fatal(AppFailure)
}

enum EnvironmentReadiness: Equatable {
    case blackHoleMissing
    case microphonePermissionMissing
    case audioConfigurationMissing
    case ready
}

enum ApplicationEvent: Equatable {
    case beginEnvironmentCheck
    case environmentChecked(EnvironmentReadiness)
    case audioConfigurationInvalid
    case startRequested
    case engineConfigured
    case engineStarted
    case engineBlocked
    case engineFailed(BlockingIssue)
    case stopRequested
    case engineStopped
    case muteChanged(Bool)
    case inputDeviceRemoved
    case blackHoleRemoved
    case microphonePermissionLost
    case sleep
    case recoveryStarted
    case recoveryCompleted
    case fatal(AppFailure)
}

enum ApplicationTransitionError: Error, Equatable {
    case invalid(state: ApplicationState, event: ApplicationEvent)
    case staleCompletion(state: ApplicationState, event: ApplicationEvent)
}

extension ApplicationTransitionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalid:
            "The requested application-state transition is not valid."
        case .staleCompletion:
            "A completed operation no longer matches the current application state."
        }
    }
}

enum ApplicationStateReducer {
    static func reduce(
        _ state: ApplicationState,
        _ event: ApplicationEvent
    ) throws -> ApplicationState {
        switch event {
        case .beginEnvironmentCheck:
            switch state {
            case .booting, .safeMode, .checkingEnvironment, .needsBlackHole,
                .needsMicrophonePermission, .needsAudioConfiguration, .readyStopped, .blocked:
                return .checkingEnvironment
            case .starting, .running, .muted, .stopping, .recovering, .fatal:
                throw invalid(state, event)
            }
        case .environmentChecked(let readiness):
            switch state {
            case .checkingEnvironment:
                return stateForEnvironment(readiness)
            case .needsBlackHole, .needsMicrophonePermission, .needsAudioConfiguration,
                .readyStopped:
                throw stale(state, event)
            case .booting, .safeMode, .starting, .running, .muted, .stopping, .recovering,
                .blocked, .fatal:
                throw invalid(state, event)
            }
        case .audioConfigurationInvalid:
            switch state {
            case .booting, .checkingEnvironment, .needsBlackHole, .needsAudioConfiguration,
                .readyStopped, .blocked:
                return .needsAudioConfiguration
            case .safeMode, .needsMicrophonePermission, .starting, .running, .muted, .stopping,
                .recovering, .fatal:
                throw invalid(state, event)
            }
        case .startRequested:
            switch state {
            case .readyStopped:
                return .starting
            case .starting:
                return .starting
            case .booting, .safeMode, .checkingEnvironment, .needsBlackHole,
                .needsMicrophonePermission, .needsAudioConfiguration, .running, .muted,
                .stopping, .recovering, .blocked, .fatal:
                throw invalid(state, event)
            }
        case .engineConfigured:
            switch state {
            case .checkingEnvironment, .needsAudioConfiguration, .readyStopped:
                return .readyStopped
            case .starting, .running, .muted, .stopping:
                return state
            case .booting, .safeMode, .needsBlackHole, .needsMicrophonePermission, .recovering,
                .blocked, .fatal:
                throw invalid(state, event)
            }
        case .engineStarted:
            switch state {
            case .starting, .running:
                return .running
            case .muted:
                return .muted
            case .readyStopped, .stopping:
                throw stale(state, event)
            case .booting, .safeMode, .checkingEnvironment, .needsBlackHole,
                .needsMicrophonePermission, .needsAudioConfiguration, .recovering, .blocked,
                .fatal:
                throw invalid(state, event)
            }
        case .engineBlocked:
            switch state {
            case .safeMode, .needsBlackHole, .needsMicrophonePermission,
                .needsAudioConfiguration, .blocked, .fatal:
                return state
            case .booting, .checkingEnvironment, .readyStopped, .starting, .running, .muted,
                .stopping, .recovering:
                return .blocked(.engineStartFailed)
            }
        case .engineFailed(let issue):
            switch state {
            case .safeMode, .fatal:
                return state
            case .booting, .checkingEnvironment, .needsBlackHole,
                .needsMicrophonePermission, .needsAudioConfiguration, .readyStopped, .starting,
                .running, .muted, .stopping, .recovering, .blocked:
                return .blocked(issue)
            }
        case .stopRequested:
            switch state {
            case .starting, .running, .muted:
                return .stopping
            case .readyStopped, .stopping:
                return state
            case .booting, .safeMode, .checkingEnvironment, .needsBlackHole,
                .needsMicrophonePermission, .needsAudioConfiguration, .recovering, .blocked,
                .fatal:
                throw invalid(state, event)
            }
        case .engineStopped:
            switch state {
            case .stopping, .readyStopped:
                return .readyStopped
            case .starting, .running, .muted:
                return .blocked(.unexpectedEngineState)
            case .safeMode, .checkingEnvironment, .needsBlackHole,
                .needsMicrophonePermission, .needsAudioConfiguration, .blocked, .fatal:
                return state
            case .booting, .recovering:
                throw invalid(state, event)
            }
        case .muteChanged(let muted):
            switch (state, muted) {
            case (.starting, true), (.running, true), (.muted, true):
                return .muted
            case (.muted, false):
                return .running
            case (.starting, false), (.running, false):
                return state
            case (.booting, _), (.safeMode, _), (.checkingEnvironment, _),
                (.needsBlackHole, _), (.needsMicrophonePermission, _),
                (.needsAudioConfiguration, _), (.readyStopped, _), (.stopping, _),
                (.recovering, _), (.blocked, _), (.fatal, _):
                throw invalid(state, event)
            }
        case .inputDeviceRemoved:
            switch state {
            case .fatal:
                return state
            case .booting, .safeMode, .checkingEnvironment, .needsBlackHole,
                .needsMicrophonePermission, .needsAudioConfiguration, .readyStopped, .starting,
                .running, .muted, .stopping, .recovering, .blocked:
                return .blocked(.inputDeviceMissing)
            }
        case .blackHoleRemoved:
            switch state {
            case .fatal:
                return state
            case .booting, .safeMode, .checkingEnvironment, .needsBlackHole,
                .needsMicrophonePermission, .needsAudioConfiguration, .readyStopped, .starting,
                .running, .muted, .stopping, .recovering, .blocked:
                return .needsBlackHole
            }
        case .microphonePermissionLost:
            switch state {
            case .fatal:
                return state
            case .booting, .safeMode, .checkingEnvironment, .needsBlackHole,
                .needsMicrophonePermission, .needsAudioConfiguration, .readyStopped, .starting,
                .running, .muted, .stopping, .recovering, .blocked:
                return .needsMicrophonePermission
            }
        case .sleep:
            switch state {
            case .starting, .running, .muted:
                return .stopping
            case .booting, .safeMode, .checkingEnvironment, .needsBlackHole,
                .needsMicrophonePermission, .needsAudioConfiguration, .readyStopped, .stopping,
                .recovering, .blocked, .fatal:
                return state
            }
        case .recoveryStarted:
            switch state {
            case .safeMode, .blocked:
                return .recovering
            case .recovering:
                return .recovering
            case .booting, .checkingEnvironment, .needsBlackHole, .needsMicrophonePermission,
                .needsAudioConfiguration, .readyStopped, .starting, .running, .muted, .stopping,
                .fatal:
                throw invalid(state, event)
            }
        case .recoveryCompleted:
            switch state {
            case .recovering:
                return .readyStopped
            case .readyStopped:
                return .readyStopped
            case .booting, .safeMode, .checkingEnvironment, .needsBlackHole,
                .needsMicrophonePermission, .needsAudioConfiguration, .starting, .running,
                .muted, .stopping, .blocked, .fatal:
                throw invalid(state, event)
            }
        case .fatal(let error):
            return .fatal(error)
        }
    }

    private static func stateForEnvironment(_ readiness: EnvironmentReadiness) -> ApplicationState {
        switch readiness {
        case .blackHoleMissing:
            .needsBlackHole
        case .microphonePermissionMissing:
            .needsMicrophonePermission
        case .audioConfigurationMissing:
            .needsAudioConfiguration
        case .ready:
            .readyStopped
        }
    }

    private static func invalid(
        _ state: ApplicationState,
        _ event: ApplicationEvent
    ) -> ApplicationTransitionError {
        .invalid(state: state, event: event)
    }

    private static func stale(
        _ state: ApplicationState,
        _ event: ApplicationEvent
    ) -> ApplicationTransitionError {
        .staleCompletion(state: state, event: event)
    }
}
