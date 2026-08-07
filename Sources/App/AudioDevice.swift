// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Foundation

struct AudioDevice: Identifiable, Equatable {
    let id: String
    let displayName: String
    let inputChannelNames: [String]
    let outputChannelNames: [String]
    let sampleRates: [Double]
    let allowedBufferFrames: [Int]
    let minimumBufferFrames: Int
    let maximumBufferFrames: Int
    let isAlive: Bool
    let isAggregate: Bool

    init(_ value: STAudioDeviceInfo) {
        id = value.uid
        displayName = value.displayName
        inputChannelNames = value.inputChannelNames
        outputChannelNames = value.outputChannelNames
        sampleRates = value.sampleRates.map(\.doubleValue)
        allowedBufferFrames = value.allowedBufferFrames.map(\.intValue)
        minimumBufferFrames = value.minimumBufferFrames
        maximumBufferFrames = value.maximumBufferFrames
        isAlive = value.isAlive
        isAggregate = value.isAggregate
    }

    init(
        id: String,
        displayName: String,
        inputChannelNames: [String] = [],
        outputChannelNames: [String] = [],
        sampleRates: [Double] = [48_000],
        allowedBufferFrames: [Int] = [128, 256, 512],
        minimumBufferFrames: Int = 128,
        maximumBufferFrames: Int = 512,
        isAlive: Bool = true,
        isAggregate: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.inputChannelNames = inputChannelNames
        self.outputChannelNames = outputChannelNames
        self.sampleRates = sampleRates
        self.allowedBufferFrames = allowedBufferFrames
        self.minimumBufferFrames = minimumBufferFrames
        self.maximumBufferFrames = maximumBufferFrames
        self.isAlive = isAlive
        self.isAggregate = isAggregate
    }
}

enum BlackHoleAvailability: Equatable {
    case missing
    case available(uid: String)
    case identityChanged
    case ambiguous
}

enum AudioEnvironment {
    static let blackHoleDisplayName = "BlackHole 2ch"

    static func blackHoleAvailability(
        outputDevices: [AudioDevice],
        savedUID: String?
    ) -> BlackHoleAvailability {
        let candidates = outputDevices.filter {
            $0.isAlive && !$0.outputChannelNames.isEmpty && $0.displayName == blackHoleDisplayName
        }

        if let savedUID {
            if candidates.contains(where: { $0.id == savedUID }) {
                return .available(uid: savedUID)
            }
            return candidates.isEmpty ? .missing : .identityChanged
        }

        guard candidates.count == 1, let candidate = candidates.first else {
            return candidates.isEmpty ? .missing : .ambiguous
        }
        return .available(uid: candidate.id)
    }

    static func preferredBuffer(input: AudioDevice, output: AudioDevice) -> Int? {
        [256, 128, 512].first {
            input.allowedBufferFrames.contains($0) && output.allowedBufferFrames.contains($0)
        }
    }
}
