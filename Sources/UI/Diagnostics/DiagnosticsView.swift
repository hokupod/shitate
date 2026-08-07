// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import SwiftUI

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ProductPage(
            title: "Diagnostics",
            subtitle: "Inspect privacy-safe runtime information."
        ) {
            StateSummaryView(presentation: model.statePresentation, error: model.lastError)
            versionSection
            audioSection
            pluginSection
            unavailableActions
        }
    }

    private var versionSection: some View {
        GroupBox("Build") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                GridRow {
                    Text("Shi-tate").foregroundStyle(.secondary)
                    Text(model.bridge.displayVersion)
                }
                GridRow {
                    Text("Commit").foregroundStyle(.secondary)
                    Text("Unavailable in this development build")
                }
                GridRow {
                    Text("JUCE").foregroundStyle(.secondary)
                    Text("9.0.0")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var audioSection: some View {
        GroupBox("Audio") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                GridRow {
                    Text("Input").foregroundStyle(.secondary)
                    Text(model.selectedInput?.displayName ?? "Not selected")
                }
                GridRow {
                    Text("Output").foregroundStyle(.secondary)
                    Text("BlackHole 2ch")
                }
                GridRow {
                    Text("Format").foregroundStyle(.secondary)
                    Text(formatDescription).monospacedDigit()
                }
                GridRow {
                    Text("Xruns").foregroundStyle(.secondary)
                    Text("\(model.diagnostics.xrunCount)").monospacedDigit()
                }
                GridRow {
                    Text("Callback EMA").foregroundStyle(.secondary)
                    Text(
                        "\(model.diagnostics.callbackTimeEmaMicroseconds.formatted(.number.precision(.fractionLength(1)))) µs"
                    )
                    .monospacedDigit()
                }
                GridRow {
                    Text("Callback maximum").foregroundStyle(.secondary)
                    Text("Unavailable until recovery diagnostics are implemented")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var pluginSection: some View {
        GroupBox("Loaded Plug-ins") {
            if model.pluginSlots.isEmpty {
                Text("No plug-ins are loaded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(model.pluginSlots) { slot in
                        LabeledContent(slot.name, value: truncatedFingerprint(slot.fingerprint))
                            .monospacedDigit()
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var unavailableActions: some View {
        GroupBox("Recovery Tools") {
            VStack(alignment: .leading, spacing: 10) {
                Text(
                    "Log export and Safe Mode reset arrive with the recovery phase. These controls are shown as unavailable so this build does not imply evidence it cannot produce."
                )
                .foregroundStyle(.secondary)
                HStack {
                    Button("Open Logs Folder") {}
                    Button("Copy Redacted Diagnostics") {}
                    Button("Reset Safe Mode") {}
                    Spacer()
                }
                .disabled(true)
            }
            .padding(.vertical, 4)
        }
    }

    private var formatDescription: String {
        guard model.diagnostics.sampleRate > 0, model.diagnostics.bufferFrames > 0 else {
            return "Stopped"
        }
        return "\(Int(model.diagnostics.sampleRate)) Hz · \(model.diagnostics.bufferFrames) frames"
    }

    private func truncatedFingerprint(_ fingerprint: String) -> String {
        guard fingerprint.count > 12 else {
            return fingerprint
        }
        return "\(fingerprint.prefix(12))…"
    }
}
