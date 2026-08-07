// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Foundation

struct RunStateBootstrapDecision: Equatable, Sendable {
    var safeModeReason: SafeModeReason?
    var suspectPlugin: LoadingPluginDocument?
    var blockedFingerprints: Set<String>
    var blockedPluginStateInvalid: Bool
    var history: [RunHistoryRecord]

    var entersSafeMode: Bool { safeModeReason != nil }
}

enum RunStateServiceError: Error, LocalizedError, Equatable {
    case notStarted
    case blockedPluginStateInvalid
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .notStarted:
            "Run-state tracking did not start."
        case .blockedPluginStateInvalid:
            "The blocked plug-in state is invalid. Repair it before loading or unblocking plug-ins."
        case .persistence(let message):
            "Run-state could not be persisted safely. \(message)"
        }
    }
}

@MainActor
final class RunStateService {
    private(set) var currentState: RunStateDocument?
    private(set) var blockedPluginStateInvalid = false

    private let store: RunStateStore
    private let auxiliaryStore: AuxiliaryPersistenceStore
    private let now: () -> Date
    private let uptime: () -> TimeInterval
    private var startedUptime: TimeInterval?
    private let formatter = ISO8601DateFormatter()

    init(
        paths: ApplicationPaths,
        store: RunStateStore? = nil,
        auxiliaryStore: AuxiliaryPersistenceStore? = nil,
        now: @escaping () -> Date = Date.init,
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.store = store ?? RunStateStore(paths: paths)
        self.auxiliaryStore = auxiliaryStore ?? AuxiliaryPersistenceStore(paths: paths)
        self.now = now
        self.uptime = uptime
    }

    func beginRun() throws -> RunStateBootstrapDecision {
        let launchDate = now()
        blockedPluginStateInvalid = false
        var safeModeReason: SafeModeReason?
        let previous: RunStateDocument?
        do {
            previous = try store.load()
        } catch {
            previous = nil
            safeModeReason = .runStateInvalid
        }

        var blocked: Set<String>
        do {
            blocked = Set(try auxiliaryStore.loadBlockedPlugins().fingerprints)
        } catch {
            blocked = []
            blockedPluginStateInvalid = true
            safeModeReason = .runStateInvalid
        }

        var history = previous?.history ?? []
        var suspect: LoadingPluginDocument?
        if let previous {
            let record = historyRecord(for: previous, observedAt: launchDate)
            history.append(record)
            history = Array(history.suffix(RunStateDocument.maximumHistoryRecords))

            if record.abnormalExit {
                suspect = record.loadingPlugin
                safeModeReason =
                    record.loadingPlugin.map {
                        .pluginLoadInterrupted($0.pluginName)
                    } ?? .previousRunUnclean
            }
            if record.clockReversed {
                safeModeReason = .clockReversal
            }

            let consecutive = Array(history.suffix(3))
            if consecutive.count == 3,
                consecutive.allSatisfy({ $0.abnormalExit && $0.durationSeconds <= 30 })
            {
                safeModeReason = .rapidCrashLoop
            }
            if let fingerprint = repeatedPluginFingerprint(in: consecutive) {
                let name = consecutive.last?.loadingPlugin?.pluginName ?? "Unknown plug-in"
                safeModeReason = .repeatedPluginCrash(name)
                if !blockedPluginStateInvalid {
                    blocked.insert(fingerprint)
                    try persistBlockedFingerprints(blocked)
                }
            }
        }

        if blockedPluginStateInvalid {
            safeModeReason = .runStateInvalid
        }

        let timestamp = formatter.string(from: launchDate)
        let state = RunStateDocument(
            schemaVersion: RunStateDocument.currentSchemaVersion,
            runID: UUID(),
            cleanShutdown: false,
            startedAt: timestamp,
            updatedAt: timestamp,
            endedAt: nil,
            processUptimeSeconds: 0,
            lastOperation: "launch",
            loadingPlugin: nil,
            routingWasActive: false,
            history: history
        )
        startedUptime = uptime()
        try persist(state)

        return RunStateBootstrapDecision(
            safeModeReason: safeModeReason,
            suspectPlugin: suspect,
            blockedFingerprints: blocked,
            blockedPluginStateInvalid: blockedPluginStateInvalid,
            history: history
        )
    }

    func recordOperation(
        _ operation: String,
        loadingPlugin: LoadingPluginDocument? = nil,
        routingWasActive: Bool? = nil
    ) throws {
        guard var state = currentState else {
            throw RunStateServiceError.notStarted
        }
        state.updatedAt = formatter.string(from: now())
        state.processUptimeSeconds = elapsedUptime()
        state.lastOperation = String(operation.prefix(128))
        state.loadingPlugin = loadingPlugin
        if let routingWasActive {
            state.routingWasActive = routingWasActive
        }
        try persist(state)
    }

    func finishPluginLoad(routingWasActive: Bool) throws {
        try recordOperation(
            "pluginLoadCompleted",
            loadingPlugin: nil,
            routingWasActive: routingWasActive
        )
    }

    func markClean(routingWasActive: Bool) throws {
        guard var state = currentState else {
            throw RunStateServiceError.notStarted
        }
        let ended = now()
        let timestamp = formatter.string(from: ended)
        state.cleanShutdown = true
        state.updatedAt = timestamp
        state.endedAt = timestamp
        state.processUptimeSeconds = elapsedUptime()
        state.lastOperation = "cleanShutdown"
        state.loadingPlugin = nil
        state.routingWasActive = routingWasActive
        try persist(state)
    }

    func setBlocked(_ blocked: Set<String>) throws {
        guard !blockedPluginStateInvalid else {
            throw RunStateServiceError.blockedPluginStateInvalid
        }
        try persistBlockedFingerprints(blocked)
    }

    @discardableResult
    func repairBlockedPluginState() throws -> URL? {
        guard blockedPluginStateInvalid else {
            return nil
        }
        do {
            let quarantineURL = try auxiliaryStore.repairBlockedPlugins()
            blockedPluginStateInvalid = false
            return quarantineURL
        } catch {
            throw RunStateServiceError.persistence(error.localizedDescription)
        }
    }

    private func persist(_ state: RunStateDocument) throws {
        do {
            try store.save(state)
            currentState = state
        } catch {
            throw RunStateServiceError.persistence(error.localizedDescription)
        }
    }

    private func persistBlockedFingerprints(_ blocked: Set<String>) throws {
        do {
            try auxiliaryStore.saveBlockedPlugins(
                BlockedPluginsDocument(
                    schemaVersion: BlockedPluginsDocument.currentSchemaVersion,
                    fingerprints: blocked.sorted()
                )
            )
        } catch {
            throw RunStateServiceError.persistence(error.localizedDescription)
        }
    }

    private func historyRecord(
        for previous: RunStateDocument,
        observedAt launchDate: Date
    ) -> RunHistoryRecord {
        let startedAt = formatter.date(from: previous.startedAt) ?? launchDate
        let persistedEnd = previous.endedAt.flatMap(formatter.date(from:))
        let observedAt = persistedEnd ?? launchDate
        let updatedAt = formatter.date(from: previous.updatedAt) ?? startedAt
        let wallDuration = observedAt.timeIntervalSince(startedAt)
        let clockReversed = wallDuration < 0 || launchDate < updatedAt
        let abnormal =
            !previous.cleanShutdown || previous.loadingPlugin != nil || persistedEnd == nil
        let duration: TimeInterval
        if !abnormal, previous.processUptimeSeconds > 0 {
            duration = previous.processUptimeSeconds
        } else {
            duration = max(0, wallDuration)
        }
        return RunHistoryRecord(
            runID: previous.runID,
            startedAt: previous.startedAt,
            observedAt: formatter.string(from: observedAt),
            durationSeconds: duration,
            abnormalExit: abnormal,
            lastOperation: previous.lastOperation,
            loadingPlugin: previous.loadingPlugin,
            routingWasActive: previous.routingWasActive,
            clockReversed: clockReversed
        )
    }

    private func repeatedPluginFingerprint(in records: [RunHistoryRecord]) -> String? {
        guard records.count == 3, records.allSatisfy(\.abnormalExit) else {
            return nil
        }
        let fingerprints = records.compactMap { $0.loadingPlugin?.pluginFingerprint }
        guard fingerprints.count == 3, Set(fingerprints).count == 1 else {
            return nil
        }
        return fingerprints[0]
    }

    private func elapsedUptime() -> TimeInterval {
        guard let startedUptime else {
            return 0
        }
        return max(0, uptime() - startedUptime)
    }
}
