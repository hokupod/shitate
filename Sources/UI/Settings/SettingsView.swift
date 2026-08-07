// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case audio
    case general
    case plugins

    var id: String { rawValue }

    var title: String {
        switch self {
        case .audio: "Audio"
        case .general: "General"
        case .plugins: "Plug-ins"
        }
    }

    var symbol: String {
        switch self {
        case .audio: "waveform"
        case .general: "gearshape"
        case .plugins: "puzzlepiece.extension"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("settings.selectedPane") private var selectedPane = SettingsPane.audio.rawValue

    var body: some View {
        TabView(selection: $selectedPane) {
            AudioSettingsPane()
                .environment(model)
                .tabItem { Label(SettingsPane.audio.title, systemImage: SettingsPane.audio.symbol) }
                .tag(SettingsPane.audio.rawValue)
            GeneralSettingsPane()
                .environment(model)
                .tabItem {
                    Label(SettingsPane.general.title, systemImage: SettingsPane.general.symbol)
                }
                .tag(SettingsPane.general.rawValue)
            PluginPolicySettingsPane()
                .environment(model)
                .tabItem {
                    Label(SettingsPane.plugins.title, systemImage: SettingsPane.plugins.symbol)
                }
                .tag(SettingsPane.plugins.rawValue)
        }
        .frame(width: 560, height: 470)
    }
}

struct AudioSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.isRoutingActive {
                InlineNotice(
                    title: "Audio settings are locked",
                    message: "Stop routing before changing a device or format.",
                    kind: .information
                )
            }
            AudioConfigurationForm()
                .environment(model)
            Spacer()
            HStack {
                Text("Changes take effect only after validation succeeds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply Audio Settings") {
                    model.applyAudioSettings()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canApplyAudioSettings)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }
}

struct AudioConfigurationForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Picker("Routing mode", selection: $model.routingMode) {
                ForEach(AudioRoutingSelection.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .onChange(of: model.routingMode) {
                model.markAudioSettingsDirty()
            }

            Picker("Input device", selection: selectedInputBinding) {
                Text("Select an input…").tag(String?.none)
                ForEach(model.selectableInputDevices) { device in
                    Text(device.displayName).tag(String?.some(device.id))
                }
            }

            Picker("Input channel", selection: $model.selectedInputChannel) {
                ForEach(Array(model.selectedInputChannels.enumerated()), id: \.offset) {
                    index, name in
                    Text(name).tag(index)
                }
            }
            .disabled(model.selectedInputChannels.isEmpty)
            .onChange(of: model.selectedInputChannel) {
                model.markAudioSettingsDirty()
            }

            if model.routingMode == .manualAggregate {
                Picker("BlackHole channel pair", selection: $model.manualOutputChannelStart) {
                    ForEach(manualOutputPairs, id: \.offset) { pair in
                        Text(pair.title).tag(pair.offset)
                    }
                }
                .disabled(manualOutputPairs.isEmpty)
                .onChange(of: model.manualOutputChannelStart) {
                    model.markAudioSettingsDirty()
                }
            }

            LabeledContent("Output", value: "BlackHole 2ch · Channels 1–2")
            LabeledContent("Sample rate", value: "48,000 Hz")

            Picker("Buffer", selection: $model.bufferFrames) {
                ForEach(model.compatibleBufferFrames, id: \.self) { frames in
                    Text("\(frames) frames").tag(frames)
                }
            }
            .disabled(model.compatibleBufferFrames.isEmpty)
            .onChange(of: model.bufferFrames) {
                model.markAudioSettingsDirty()
            }
        }
        .formStyle(.grouped)
        .disabled(model.isRoutingActive)
    }

    private var selectedInputBinding: Binding<String?> {
        Binding(
            get: { model.selectedInputUID },
            set: { value in
                model.selectedInputUID = value
                model.selectedInputChannel = 0
                model.manualOutputChannelStart = 0
                if let preferred = preferredBuffer {
                    model.bufferFrames = preferred
                }
                model.markAudioSettingsDirty()
            }
        )
    }

    private var preferredBuffer: Int? {
        guard let input = model.selectedInput else {
            return nil
        }
        if model.routingMode == .manualAggregate {
            return [256, 128, 512].first { input.allowedBufferFrames.contains($0) }
        }
        guard
            let blackHoleUID = model.blackHoleUID,
            let output = model.outputDevices.first(where: { $0.id == blackHoleUID })
        else {
            return nil
        }
        return AudioEnvironment.preferredBuffer(input: input, output: output)
    }

    private var manualOutputPairs: [(offset: Int, title: String)] {
        guard let device = model.selectedInput else {
            return []
        }
        return stride(from: 0, to: max(device.outputChannelNames.count - 1, 0), by: 2)
            .map { offset in
                let first = device.outputChannelNames[offset]
                let second = device.outputChannelNames[offset + 1]
                return (offset, "\(first) + \(second)")
            }
    }
}

private struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Launch Shi-tate at login",
                    isOn: Binding(
                        get: { model.settings.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    )
                )
                Toggle(
                    "Start routing after launch when setup is valid",
                    isOn: Binding(
                        get: { model.settings.startRoutingAtLaunch },
                        set: { model.setStartRoutingAtLaunch($0) }
                    )
                )
                Toggle(
                    "Restore the last session",
                    isOn: Binding(
                        get: { model.settings.restoreLastSession },
                        set: { model.setRestoreLastSession($0) }
                    )
                )
            }

            Section("System events") {
                Toggle("Resume routing after wake", isOn: .constant(false))
                    .disabled(true)
                Text("Unavailable in v0.1. Shi-tate always remains stopped after wake.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard") {
                Toggle(
                    "Global mute shortcut: Control-Shift-M",
                    isOn: Binding(
                        get: { model.settings.globalMuteShortcutEnabled },
                        set: { model.setGlobalMuteShortcutEnabled($0) }
                    )
                )
                if let warning = model.globalHotKeyService.warning {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
                Text(
                    "The shortcut uses the macOS Carbon hot-key API and does not need Accessibility access."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
    }
}

private struct PluginPolicySettingsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Trust policy") {
                Toggle(
                    "Allow explicit approval of ad-hoc signed VST3",
                    isOn: Binding(
                        get: { model.settings.pluginPolicy.allowAdHocSignedPlugins },
                        set: { model.setAllowAdHocSignedPlugins($0) }
                    )
                )
                InlineNotice(
                    title: "Reduced platform protection",
                    message:
                        "Each ad-hoc plug-in still requires approval of its exact fingerprint. Only enable this for software you trust.",
                    kind: .warning
                )
            }

            Section("Supported format") {
                LabeledContent("Format", value: "VST3 Audio Effect")
                LabeledContent("Architecture", value: "arm64 or Universal")
                LabeledContent("Layout", value: "Stereo input · Stereo output")
                Text("Shi-tate does not download or redistribute third-party plug-ins.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
    }
}
