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
    case startRequested
    case engineConfigured
    case engineStarted
    case engineBlocked
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

enum ApplicationStateReducer {
    static func reduce(_ state: ApplicationState, _ event: ApplicationEvent) -> ApplicationState {
        switch event {
        case .beginEnvironmentCheck:
            return .checkingEnvironment
        case .environmentChecked(let readiness):
            return stateForEnvironment(readiness)
        case .startRequested:
            return state == .readyStopped ? .starting : state
        case .engineConfigured:
            return state == .stopping || state == .readyStopped ? .readyStopped : state
        case .engineStarted:
            return state == .starting || state == .running || state == .muted
                ? .running : .blocked(.unexpectedEngineState)
        case .engineBlocked:
            switch state {
            case .safeMode, .needsBlackHole, .needsMicrophonePermission,
                .needsAudioConfiguration, .blocked, .fatal:
                return state
            default:
                return .blocked(.engineStartFailed)
            }
        case .stopRequested, .sleep:
            return state == .starting || state == .running || state == .muted ? .stopping : state
        case .engineStopped:
            if state == .stopping || state == .readyStopped {
                return .readyStopped
            }
            return .blocked(.unexpectedEngineState)
        case .muteChanged(let muted):
            if muted, state == .starting || state == .running {
                return .muted
            }
            if !muted, state == .muted {
                return .running
            }
            return state
        case .inputDeviceRemoved:
            return .blocked(.inputDeviceMissing)
        case .blackHoleRemoved:
            return .needsBlackHole
        case .microphonePermissionLost:
            return .needsMicrophonePermission
        case .recoveryStarted:
            return .recovering
        case .recoveryCompleted:
            return state == .recovering ? .readyStopped : .blocked(.unexpectedEngineState)
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
}
