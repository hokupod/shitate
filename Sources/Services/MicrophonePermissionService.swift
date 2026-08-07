// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import AVFoundation
import AppKit
import Foundation

enum MicrophonePermissionStatus: Equatable {
    case undetermined
    case denied
    case restricted
    case authorized
}

@MainActor
protocol MicrophonePermissionProviding: AnyObject {
    var status: MicrophonePermissionStatus { get }
    func requestAccess() async -> Bool
    func openSystemSettings()
}

@MainActor
final class MicrophonePermissionService: MicrophonePermissionProviding {
    var status: MicrophonePermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            .undetermined
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .authorized:
            .authorized
        @unknown default:
            .denied
        }
    }

    func requestAccess() async -> Bool {
        guard status == .undetermined else {
            return status == .authorized
        }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    func openSystemSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )
        else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
final class MicrophonePermissionFlow {
    private let provider: any MicrophonePermissionProviding

    init(provider: any MicrophonePermissionProviding) {
        self.provider = provider
    }

    var status: MicrophonePermissionStatus {
        provider.status
    }

    func request() async -> MicrophonePermissionStatus {
        guard provider.status == .undetermined else {
            return provider.status
        }
        _ = await provider.requestAccess()
        return provider.status
    }

    func openSystemSettings() {
        provider.openSystemSettings()
    }
}
