// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import AppKit
import Foundation

@MainActor
extension AppModel {
    var diagnosticsReport: String {
        DiagnosticsReportBuilder.build(
            DiagnosticsSnapshot(
                appVersion: bridge.displayVersion,
                commit: BuildMetadata.commit,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: BuildMetadata.architecture,
                juceVersion: "9.0.0",
                state: statusTitle,
                inputName: selectedInput?.displayName ?? settings.audio.inputDeviceName,
                inputUID: selectedInputUID ?? settings.audio.inputDeviceUID,
                inputChannel: selectedInputChannel,
                outputName: activeOutputName,
                outputUID: activeOutputUID,
                sampleRate: diagnostics.sampleRate,
                bufferFrames: diagnostics.bufferFrames,
                xrunCount: diagnostics.xrunCount,
                plugins: pluginSlots.map { slot in
                    DiagnosticsPluginRecord(
                        name: slot.name,
                        version: slot.version,
                        fingerprint: slot.fingerprint,
                        status: slot.isFaulted ? "faulted" : (slot.isBypassed ? "bypassed" : "ok")
                    )
                },
                lastError: lastError
            ),
            redactor: DiagnosticRedactor()
        )
    }

    func copyDiagnosticsToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(diagnosticsReport, forType: .string)
    }

    func openLogsFolder() {
        do {
            try SecureDirectory.prepare(paths.logsDirectory)
            NSWorkspace.shared.open(paths.logsDirectory)
        } catch {
            lastError = "The owner-only logs folder could not be opened."
        }
    }
}
