// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Foundation

enum AudioRoutingModeDocument: String, Codable, Sendable {
    case automaticPrivateAggregate
    case manualAggregate
}

struct PersistedAudioSettings: Codable, Equatable, Sendable {
    var mode: AudioRoutingModeDocument
    var inputDeviceUID: String
    var inputDeviceName: String
    var inputChannelIndex: Int
    var outputDeviceUID: String
    var outputDeviceName: String
    var manualOutputChannelStart: Int
    var sampleRate: Double
    var bufferFrames: Int

    static let defaults = PersistedAudioSettings(
        mode: .automaticPrivateAggregate,
        inputDeviceUID: "",
        inputDeviceName: "",
        inputChannelIndex: 0,
        outputDeviceUID: "",
        outputDeviceName: "BlackHole 2ch",
        manualOutputChannelStart: 0,
        sampleRate: 48_000,
        bufferFrames: 256
    )
}

struct PluginPolicySettings: Codable, Equatable, Sendable {
    var allowAdHocSignedPlugins: Bool

    static let defaults = PluginPolicySettings(allowAdHocSignedPlugins: false)
}

struct SettingsDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var launchAtLogin: Bool
    var startRoutingAtLaunch: Bool
    var restoreLastSession: Bool
    var resumeAfterWake: Bool
    var globalMuteShortcutEnabled: Bool
    var audio: PersistedAudioSettings
    var pluginPolicy: PluginPolicySettings
    var lastSessionID: String

    static let defaults = SettingsDocument(
        schemaVersion: currentSchemaVersion,
        launchAtLogin: false,
        startRoutingAtLaunch: false,
        restoreLastSession: true,
        resumeAfterWake: false,
        globalMuteShortcutEnabled: true,
        audio: .defaults,
        pluginPolicy: .defaults,
        lastSessionID: "default"
    )
}

struct SessionSlotDocument: Codable, Equatable, Sendable, Identifiable {
    var slotID: UUID
    var order: Int
    var pluginFingerprint: String
    var bundlePath: String
    var classUID: String
    var name: String
    var manufacturer: String
    var version: String
    var bypassed: Bool
    var stateFile: String

    var id: UUID { slotID }

    static func stateFile(for slotID: UUID) -> String {
        "plugin-states/\(slotID.uuidString).bin"
    }
}

struct SessionDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let maximumSlots = 8

    var schemaVersion: Int
    var id: String
    var name: String
    var updatedAt: String
    var slots: [SessionSlotDocument]

    static let emptyDefault = SessionDocument(
        schemaVersion: currentSchemaVersion,
        id: "default",
        name: "Default",
        updatedAt: ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 0)),
        slots: []
    )
}

struct LoadingPluginDocument: Codable, Equatable, Sendable {
    var slotID: UUID
    var pluginFingerprint: String
    var pluginName: String
}

struct RunHistoryRecord: Codable, Equatable, Sendable {
    var runID: UUID
    var startedAt: String
    var observedAt: String
    var durationSeconds: Double
    var abnormalExit: Bool
    var lastOperation: String
    var loadingPlugin: LoadingPluginDocument?
    var routingWasActive: Bool
    var clockReversed: Bool
}

struct RunStateDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    static let maximumHistoryRecords = 12

    var schemaVersion: Int
    var runID: UUID
    var cleanShutdown: Bool
    var startedAt: String
    var updatedAt: String
    var endedAt: String?
    var processUptimeSeconds: Double
    var lastOperation: String
    var loadingPlugin: LoadingPluginDocument?
    var routingWasActive: Bool
    var history: [RunHistoryRecord]
}

struct BlockedPluginsDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var fingerprints: [String]

    static let empty = BlockedPluginsDocument(
        schemaVersion: currentSchemaVersion,
        fingerprints: []
    )
}

struct ScanFoldersDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var folders: [String]

    static let empty = ScanFoldersDocument(
        schemaVersion: currentSchemaVersion,
        folders: []
    )
}

struct PersistedSession: Equatable, Sendable {
    var document: SessionDocument
    var pluginStates: [UUID: Data]
}
