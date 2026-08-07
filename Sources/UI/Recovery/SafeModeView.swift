// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import SwiftUI

struct SafeModeView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsReset = false

    var body: some View {
        ProductPage(
            title: "Safe Mode",
            subtitle: "Recover without loading plug-ins or opening the audio output automatically."
        ) {
            StateSummaryView(presentation: model.statePresentation, error: model.lastError)
            reasonSection
            if model.blockedPluginStateInvalid {
                blockedStateRepairSection
            }
            recoverySection
            if let suspect = model.safeModeSuspect {
                suspectSection(suspect)
            }
            historySection
        }
        .confirmationDialog(
            "Reset the Saved Session?",
            isPresented: $confirmsReset,
            titleVisibility: .visible
        ) {
            Button("Reset Session", role: .destructive) {
                model.resetSessionFromSafeMode()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the saved plug-in chain with an empty chain. Audio stays stopped.")
        }
    }

    private var reasonSection: some View {
        GroupBox("Why Safe Mode Started") {
            VStack(alignment: .leading, spacing: 8) {
                Label(reasonTitle, systemImage: "exclamationmark.shield")
                    .font(.headline)
                Text(reasonDetail)
                    .foregroundStyle(.secondary)
                Text("Launch at Login remains enabled, but Start Routing at Launch is suppressed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var recoverySection: some View {
        GroupBox("Recovery") {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Choose an explicit recovery action. Shi-tate will not load a VST3 or open BlackHole until you continue."
                )
                .foregroundStyle(.secondary)

                HStack {
                    Button("Continue with Empty Chain") {
                        model.continueFromSafeModeWithEmptyChain()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.persistenceBlocksRouting || model.blockedPluginStateInvalid
                    )

                    Button("Restore Saved Chain One by One") {
                        model.restoreSavedSessionFromSafeMode()
                    }
                    .disabled(
                        model.loadedSession == nil || model.persistenceBlocksRouting
                            || model.blockedPluginStateInvalid
                    )

                    Spacer()
                }

                HStack {
                    Button("Open Diagnostics") {
                        model.selectedSection = .diagnostics
                    }
                    Button("Reset Session…", role: .destructive) {
                        confirmsReset = true
                    }
                    .disabled(
                        model.persistenceBlocksRouting || model.blockedPluginStateInvalid
                    )
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var blockedStateRepairSection: some View {
        GroupBox("Blocked Plug-in State") {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "Plug-in loading remains disabled until this state is repaired.",
                    systemImage: "lock.shield"
                )
                Text(
                    "Repair keeps the invalid file as an owner-only quarantine copy and creates a validated empty block list."
                )
                .foregroundStyle(.secondary)
                Button("Repair Block List") {
                    model.repairBlockedPluginState()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func suspectSection(_ suspect: LoadingPluginDocument) -> some View {
        GroupBox("Likely Suspect") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Plug-in", value: suspect.pluginName)
                LabeledContent(
                    "Fingerprint",
                    value: "\(suspect.pluginFingerprint.prefix(12))…"
                )
                .monospacedDigit()

                HStack {
                    Button("Rescan") {
                        model.rescanSafeModeSuspect()
                    }
                    Button("Remove from Saved Session") {
                        model.removeSafeModeSuspectFromSession()
                    }
                    if model.blockedPluginFingerprints.contains(suspect.pluginFingerprint) {
                        Button("Unblock Exact Fingerprint") {
                            model.unblockSafeModeSuspect()
                        }
                        .disabled(model.blockedPluginStateInvalid)
                    }
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var historySection: some View {
        GroupBox("Recent Launches") {
            if model.safeModeHistory.isEmpty {
                Text("No prior launch history is available.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.safeModeHistory.suffix(3).enumerated()), id: \.offset) {
                        _, record in
                        HStack {
                            Label(
                                record.abnormalExit ? "Abnormal exit" : "Clean exit",
                                systemImage: record.abnormalExit
                                    ? "exclamationmark.triangle" : "checkmark.circle"
                            )
                            Spacer()
                            Text("\(Int(record.durationSeconds)) s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(record.lastOperation)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var reasonTitle: String {
        switch model.safeModeReason {
        case .previousRunUnclean: "Previous Run Was Unclean"
        case .pluginLoadInterrupted: "Plug-in Load Was Interrupted"
        case .rapidCrashLoop: "Rapid Crash Loop Detected"
        case .repeatedPluginCrash: "Repeated Plug-in Crash Detected"
        case .clockReversal: "System Clock Changed"
        case .runStateInvalid: "Run State Is Invalid"
        case .runStateWriteFailed: "Run State Is Not Writable"
        case .stateMigrationFailed: "Saved State Migration Failed"
        case nil: "Safe Mode"
        }
    }

    private var reasonDetail: String {
        switch model.safeModeReason {
        case .previousRunUnclean:
            "The previous process did not complete the ordered shutdown sequence."
        case .pluginLoadInterrupted(let name):
            "The previous process ended while loading \(name)."
        case .rapidCrashLoop:
            "Three consecutive launches ended abnormally within 30 seconds."
        case .repeatedPluginCrash(let name):
            "\(name) interrupted three consecutive loads. Its exact fingerprint is blocked."
        case .clockReversal:
            "The wall clock moved backwards. Existing crash evidence was retained and startup failed safe."
        case .runStateInvalid:
            "Run-state data is corrupt or uses an unsupported future schema."
        case .runStateWriteFailed:
            "Shi-tate cannot prove write-before-load ordering, so routing and plug-in loading remain disabled."
        case .stateMigrationFailed:
            "Settings or session state could not be migrated without weakening validation."
        case nil:
            "Recovery is not required."
        }
    }
}
