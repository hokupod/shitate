// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import AppKit
import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            statusHeader
            environmentAction
            meterSection
            routingSection
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 440)
    }

    private var statusHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: model.statusSymbol)
                .font(.title2)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.statusTitle)
                    .font(.title2)
                Text(model.statusDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var environmentAction: some View {
        switch model.state {
        case .needsBlackHole:
            GroupBox("BlackHole 2ch") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.lastError ?? "BlackHole 2ch is required before routing.")
                        .foregroundStyle(.secondary)
                    HStack {
                        if let guideURL = URL(
                            string:
                                "https://github.com/ExistentialAudio/BlackHole/wiki/Installation"
                        ) {
                            Link("Open Official Install Guide", destination: guideURL)
                        }
                        Spacer()
                        Button(
                            model.canAcceptDetectedBlackHole
                                ? "Use Detected BlackHole" : "Check Again"
                        ) {
                            model.acceptDetectedBlackHole()
                        }
                    }
                    .padding(.top, 4)
                }
            }
        case .needsMicrophonePermission:
            GroupBox("Microphone Access") {
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
                .padding(.top, 4)
            }
        case .needsAudioConfiguration, .blocked:
            GroupBox("Next Step") {
                HStack {
                    Text(model.lastError ?? "Review the selected audio devices and format.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    SettingsLink {
                        Text("Open Audio Settings")
                    }
                }
                .padding(.top, 4)
            }
        default:
            EmptyView()
        }
    }

    private var meterSection: some View {
        GroupBox("Signal") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                MeterRow(
                    title: "Input",
                    peakDB: model.meters.inputPeakDB,
                    rmsDB: model.meters.inputRmsDB,
                    clipping: model.meters.inputClipping
                )
                MeterRow(
                    title: "Output",
                    peakDB: model.meters.outputPeakDB,
                    rmsDB: model.meters.outputRmsDB,
                    clipping: model.meters.outputClipping
                )
            }
            .padding(.top, 6)
        }
    }

    private var routingSection: some View {
        GroupBox("Routing") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Input", value: model.selectedInput?.displayName ?? "Not selected")
                LabeledContent("Output", value: AudioEnvironment.blackHoleDisplayName)
                LabeledContent(
                    "Actual Format",
                    value: formatDescription
                )
                HStack {
                    Button(model.isRoutingActive ? "Stop Routing" : "Start Routing") {
                        if model.isRoutingActive {
                            model.stopRouting()
                        } else {
                            model.startRouting()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isRoutingActive && !model.canStartRouting)

                    Button(model.isMuted ? "Unmute" : "Mute") {
                        model.toggleMute()
                    }
                    .disabled(model.state != .running && model.state != .muted)

                    Spacer()
                    Text("Xruns: \(model.diagnostics.xrunCount)")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("CoreAudio xruns")
                }
            }
            .padding(.top, 6)
        }
    }

    private var formatDescription: String {
        guard model.diagnostics.sampleRate > 0, model.diagnostics.bufferFrames > 0 else {
            return "Stopped"
        }
        return "\(Int(model.diagnostics.sampleRate)) Hz / \(model.diagnostics.bufferFrames) frames"
    }
}

private struct MeterRow: View {
    let title: String
    let peakDB: Float
    let rmsDB: Float
    let clipping: Bool

    var body: some View {
        GridRow {
            Text(title)
                .frame(width: 52, alignment: .leading)
            ProgressView(value: normalizedPeak)
                .tint(clipping ? .red : .accentColor)
                .accessibilityLabel("\(title) peak level")
                .accessibilityValue(
                    "\(peakDB.formatted(.number.precision(.fractionLength(1)))) decibels")
            Text("\(rmsDB.formatted(.number.precision(.fractionLength(1)))) dB RMS")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .trailing)
            if clipping {
                Label("Clipping", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } else {
                Text("No clipping")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var normalizedPeak: Double {
        min(max(Double(peakDB + 96) / 96, 0), 1)
    }
}

struct AudioSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Routing Mode") {
                Picker("Mode", selection: $model.routingMode) {
                    ForEach(AudioRoutingSelection.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isRoutingActive)
                .onChange(of: model.routingMode) {
                    model.selectedInputUID = nil
                    model.selectedInputChannel = 0
                    model.manualOutputChannelStart = 0
                    model.markAudioSettingsDirty()
                }
                Text(routingModeHelp)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Input") {
                Picker("Device", selection: $model.selectedInputUID) {
                    Text("Choose a device").tag(nil as String?)
                    ForEach(model.selectableInputDevices) { device in
                        Text(device.displayName).tag(Optional(device.id))
                    }
                }
                .onChange(of: model.selectedInputUID) {
                    model.selectedInputChannel = 0
                    model.manualOutputChannelStart = 0
                    model.markAudioSettingsDirty()
                }
                .disabled(model.isRoutingActive)

                Picker("Channel", selection: $model.selectedInputChannel) {
                    ForEach(Array(model.selectedInputChannels.enumerated()), id: \.offset) {
                        index, name in
                        Text(name).tag(index)
                    }
                }
                .disabled(model.isRoutingActive || model.selectedInputChannels.isEmpty)
                .onChange(of: model.selectedInputChannel) {
                    model.markAudioSettingsDirty()
                }

                LabeledContent("Virtual Output", value: AudioEnvironment.blackHoleDisplayName)
            }

            if model.routingMode == .manualAggregate {
                Section("Manual Aggregate Output") {
                    Picker("First Output Channel", selection: $model.manualOutputChannelStart) {
                        ForEach(manualOutputStarts, id: \.self) { index in
                            Text(manualOutputLabel(index)).tag(index)
                        }
                    }
                    .disabled(model.isRoutingActive || manualOutputStarts.isEmpty)
                    .onChange(of: model.manualOutputChannelStart) {
                        model.markAudioSettingsDirty()
                    }
                }
            }

            Section("Format") {
                LabeledContent("Sample Rate", value: "48 kHz")
                Picker("Buffer", selection: $model.bufferFrames) {
                    ForEach(model.compatibleBufferFrames, id: \.self) { frames in
                        Text("\(frames) frames").tag(frames)
                    }
                }
                .disabled(model.isRoutingActive || model.compatibleBufferFrames.isEmpty)
                .onChange(of: model.bufferFrames) {
                    model.markAudioSettingsDirty()
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button("Refresh Devices") {
                        model.refreshEnvironment()
                    }
                    .disabled(model.isRoutingActive)
                    Spacer()
                    Button("Apply Audio Settings") {
                        model.applyAudioSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canApplyAudioSettings)
                }
                .padding(12)
            }
            .background(.bar)
        }
        .padding(12)
        .frame(width: 500, height: 560)
    }

    private var routingModeHelp: String {
        switch model.routingMode {
        case .automaticPrivateAggregate:
            "Uses the selected physical input and BlackHole 2ch in a private CoreAudio aggregate."
        case .manualAggregate:
            "Requires an aggregate you created in Audio MIDI Setup with BlackHole as clock source."
        }
    }

    private var manualOutputStarts: [Int] {
        guard let device = model.selectedInput else {
            return []
        }
        return Array(0..<max(0, device.outputChannelNames.count - 1))
    }

    private func manualOutputLabel(_ index: Int) -> String {
        guard let device = model.selectedInput, index + 1 < device.outputChannelNames.count else {
            return "Channels \(index + 1)–\(index + 2)"
        }
        return "\(device.outputChannelNames[index]) + \(device.outputChannelNames[index + 1])"
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Shi-tate") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }
        Divider()
        Button(model.isRoutingActive ? "Stop Routing" : "Start Routing") {
            model.isRoutingActive ? model.stopRouting() : model.startRouting()
        }
        .disabled(!model.isRoutingActive && !model.canStartRouting)
        Button(model.isMuted ? "Unmute" : "Mute") {
            model.toggleMute()
        }
        .disabled(model.state != .running && model.state != .muted)
        Divider()
        Text("Input: \(model.selectedInput?.displayName ?? "Not selected")")
        Text("Output: \(AudioEnvironment.blackHoleDisplayName)")
        if let error = model.lastError {
            Text(error)
        }
        Divider()
        SettingsLink {
            Text("Audio Settings…")
        }
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}
