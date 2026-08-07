// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ProductPage(
            title: "Dashboard",
            subtitle: "Monitor and control the active microphone path."
        ) {
            StateSummaryView(
                presentation: model.statePresentation,
                error: model.lastError
            )
            environmentActions
            routingOverview
            meterSection
            runtimeSection
        }
    }

    @ViewBuilder
    private var environmentActions: some View {
        switch model.state {
        case .needsBlackHole:
            GroupBox("BlackHole 2ch") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Shi-tate never downloads or installs BlackHole automatically.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Link(
                            "Open Official Installation Guide",
                            destination: blackHoleGuideURL
                        )
                        Spacer()
                        Button(
                            model.canAcceptDetectedBlackHole
                                ? "Use Detected BlackHole" : "Check Again"
                        ) {
                            model.acceptDetectedBlackHole()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        case .needsMicrophonePermission:
            GroupBox("Microphone Access") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Audio remains silent until macOS grants microphone access.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Request Access") {
                            Task {
                                await model.requestMicrophonePermission()
                            }
                        }
                        Button("Open System Settings") {
                            model.openMicrophoneSystemSettings()
                        }
                        Spacer()
                        Button("Check Again") {
                            model.refreshEnvironment()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        case .needsAudioConfiguration, .blocked:
            HStack {
                InlineNotice(
                    title: "Routing remains stopped",
                    message: "Review the selected device, channel, and buffer before retrying.",
                    kind: .warning
                )
                SettingsLink {
                    Text("Open Settings…")
                }
            }
        default:
            EmptyView()
        }
    }

    private var routingOverview: some View {
        GroupBox("Audio Path") {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    GridRow {
                        Text("Input")
                            .foregroundStyle(.secondary)
                        Text(inputDescription)
                    }
                    GridRow {
                        Text("Output")
                            .foregroundStyle(.secondary)
                        Text("BlackHole 2ch · Channels 1–2")
                    }
                    GridRow {
                        Text("Actual Format")
                            .foregroundStyle(.secondary)
                        Text(formatDescription)
                            .monospacedDigit()
                    }
                }
                Divider()
                HStack {
                    Button(model.isRoutingActive ? "Stop Routing" : "Start Routing") {
                        model.isRoutingActive ? model.stopRouting() : model.startRouting()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(routingButtonDisabled)

                    Button(model.isMuted ? "Unmute" : "Mute") {
                        model.toggleMute()
                    }
                    .disabled(model.state != .running && model.state != .muted)

                    Button(allPluginsBypassed ? "Enable All Plug-ins" : "Bypass All Plug-ins") {
                        model.setAllPluginsBypassed(!allPluginsBypassed)
                    }
                    .disabled(model.pluginSlots.isEmpty || !model.canEditPluginChain)
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var meterSection: some View {
        GroupBox("Signal") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                AudioMeterRow(
                    title: "Input",
                    peakDB: model.meters.inputPeakDB,
                    rmsDB: model.meters.inputRmsDB,
                    clipping: model.meters.inputClipping
                )
                AudioMeterRow(
                    title: "Output",
                    peakDB: model.meters.outputPeakDB,
                    rmsDB: model.meters.outputRmsDB,
                    clipping: model.meters.outputClipping
                )
            }
            .padding(.vertical, 6)
        }
    }

    private var runtimeSection: some View {
        GroupBox("Runtime") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                GridRow {
                    LabeledContent(
                        "Host Latency",
                        value: "\(model.diagnostics.aggregateLatencySamples) samples"
                    )
                    LabeledContent(
                        "Plug-in Latency",
                        value: "\(model.diagnostics.pluginLatencySamples) samples"
                    )
                }
                GridRow {
                    LabeledContent("Xruns", value: "\(model.diagnostics.xrunCount)")
                    LabeledContent(
                        "Callback EMA",
                        value:
                            "\(model.diagnostics.callbackTimeEmaMicroseconds.formatted(.number.precision(.fractionLength(1)))) µs"
                    )
                }
            }
            .monospacedDigit()
            .padding(.vertical, 4)
        }
    }

    private var allPluginsBypassed: Bool {
        !model.pluginSlots.isEmpty && model.pluginSlots.allSatisfy(\.isBypassed)
    }

    private var inputDescription: String {
        guard let input = model.selectedInput else {
            return "Not selected"
        }
        let channel =
            model.selectedInputChannels.indices.contains(model.selectedInputChannel)
            ? model.selectedInputChannels[model.selectedInputChannel]
            : "Channel \(model.selectedInputChannel + 1)"
        return "\(input.displayName) · \(channel)"
    }

    private var formatDescription: String {
        guard model.diagnostics.sampleRate > 0, model.diagnostics.bufferFrames > 0 else {
            return "Stopped"
        }
        return "\(Int(model.diagnostics.sampleRate)) Hz · \(model.diagnostics.bufferFrames) frames"
    }

    private var routingButtonDisabled: Bool {
        switch model.state {
        case .starting, .stopping:
            true
        default:
            !model.isRoutingActive && !model.canStartRouting
        }
    }

    private var blackHoleGuideURL: URL {
        guard
            let url = URL(
                string: "https://github.com/ExistentialAudio/BlackHole/wiki/Installation"
            )
        else {
            preconditionFailure("The BlackHole guide URL must be valid.")
        }
        return url
    }
}
