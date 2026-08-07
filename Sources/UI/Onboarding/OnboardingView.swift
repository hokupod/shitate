// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                stepContent
                    .frame(maxWidth: 660, alignment: .leading)
                    .padding(32)
            }
            Divider()
            actionBar
        }
        .frame(width: 760, height: 620)
        .interactiveDismissDisabled(true)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Set Up Shi-tate")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text(stepTitle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("Step \(stepNumber) of \(OnboardingStep.allCases.count - 1)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(
                value: Double(stepNumber), total: Double(OnboardingStep.allCases.count - 1)
            )
            .accessibilityLabel("Setup progress")
            .accessibilityValue("Step \(stepNumber) of \(OnboardingStep.allCases.count - 1)")
        }
        .padding(20)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.onboardingStep {
        case .welcome:
            welcome
        case .blackHoleCheck:
            blackHoleCheck
        case .installGuide:
            installGuide
        case .microphonePermission:
            microphonePermission
        case .audioSelection:
            audioSelection
        case .audioValidation:
            audioValidation
        case .pluginScan:
            pluginScan
        case .chainSetup:
            chainSetup
        case .callAppGuide:
            callAppGuide
        case .complete:
            complete
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(
                "Process your microphone with a local VST3 chain, then send dual-mono audio to BlackHole 2ch for a call app."
            )
            .font(.title3)
            InlineNotice(
                title: "Fail-closed audio",
                message:
                    "If a required device, permission, or plug-in validation fails, Shi-tate stops output instead of selecting another destination."
            )
            Text(
                "Setup does not download BlackHole or any plug-in. You can finish with an empty chain for plain passthrough."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var blackHoleCheck: some View {
        VStack(alignment: .leading, spacing: 18) {
            setupHeading(
                symbol: model.onboardingReadiness.hasBlackHole
                    ? "checkmark.circle.fill" : "externaldrive.badge.questionmark",
                title: model.onboardingReadiness.hasBlackHole
                    ? "BlackHole 2ch is available" : "Check for BlackHole 2ch",
                detail: "Shi-tate sends processed audio only to BlackHole 2ch channels 1–2."
            )
            if let error = model.lastError, !model.onboardingReadiness.hasBlackHole {
                InlineNotice(title: "Output remains silent", message: error, kind: .warning)
            }
            Button("Check Again") {
                model.refreshEnvironment()
            }
        }
    }

    private var installGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            setupHeading(
                symbol: "arrow.down.circle",
                title: "Install BlackHole 2ch",
                detail:
                    "Use the official BlackHole distribution. Shi-tate does not install or bundle it."
            )
            Link("Open the Official Installation Guide", destination: blackHoleGuideURL)
            Text(
                "After installation, return here and check again. A system restart can be required by the driver installer."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var microphonePermission: some View {
        VStack(alignment: .leading, spacing: 18) {
            setupHeading(
                symbol: model.hasMicrophonePermission
                    ? "checkmark.circle.fill" : "mic.badge.plus",
                title: model.hasMicrophonePermission
                    ? "Microphone access is allowed" : "Allow microphone access",
                detail: "macOS permission is required only to read your selected input."
            )
            if !model.hasMicrophonePermission {
                InlineNotice(
                    title: "Output remains silent",
                    message:
                        "Shi-tate cannot configure or start routing until macOS grants access.",
                    kind: .warning
                )
                HStack {
                    Button("Request Access") {
                        Task { await model.requestMicrophonePermission() }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Open System Settings") {
                        model.openMicrophoneSystemSettings()
                    }
                }
            }
        }
    }

    private var audioSelection: some View {
        VStack(alignment: .leading, spacing: 16) {
            setupHeading(
                symbol: "mic.and.signal.meter",
                title: "Choose the physical microphone",
                detail:
                    "Select one input channel. Shi-tate duplicates it to stereo before the plug-in chain."
            )
            AudioConfigurationForm()
                .environment(model)
        }
    }

    private var audioValidation: some View {
        VStack(alignment: .leading, spacing: 18) {
            setupHeading(
                symbol: model.onboardingReadiness.audioIsValid
                    ? "checkmark.circle.fill" : "checkmark.shield",
                title: model.onboardingReadiness.audioIsValid
                    ? "Audio path is valid" : "Validate the audio path",
                detail:
                    "Shi-tate verifies 48 kHz, the selected buffer, and the BlackHole destination."
            )
            if model.onboardingReadiness.audioIsValid {
                InlineNotice(
                    title: "Ready and stopped",
                    message:
                        "Validation succeeded. No audio is sent until you explicitly start routing."
                )
            } else {
                if let error = model.lastError {
                    InlineNotice(
                        title: "Validation required",
                        message: "\(error) Output remains silent.",
                        kind: .warning
                    )
                }
                Button("Validate Audio Settings") {
                    model.applyAudioSettings()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canApplyAudioSettings)
            }
        }
    }

    private var pluginScan: some View {
        VStack(alignment: .leading, spacing: 18) {
            setupHeading(
                symbol: "puzzlepiece.extension",
                title: "Scan local VST3 plug-ins",
                detail:
                    "Scanning runs in an isolated helper and accepts only compatible stereo Audio Effects."
            )
            LabeledContent(
                "Compatible plug-ins",
                value: "\(compatiblePluginCount)"
            )
            if let error = model.pluginCatalogError {
                InlineNotice(title: "Scan issue", message: error, kind: .warning)
            }
            HStack {
                Button("Rescan") { model.rescanPlugins() }
                Text("You can continue with zero plug-ins.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chainSetup: some View {
        VStack(alignment: .leading, spacing: 18) {
            setupHeading(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "Confirm the initial chain",
                detail: "The chain supports up to eight validated VST3 Audio Effects."
            )
            if model.pluginSlots.isEmpty {
                InlineNotice(
                    title: "Empty chain",
                    message:
                        "Zero plug-ins is a valid passthrough path. You can add effects later from Plug-ins or Chain."
                )
            } else {
                ForEach(model.pluginSlots) { slot in
                    Label(
                        slot.name,
                        systemImage: slot.isBypassed ? "circle.slash" : "checkmark.circle")
                }
            }
        }
    }

    private var callAppGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            setupHeading(
                symbol: "bubble.left.and.waveform",
                title: "Select BlackHole 2ch in your call app",
                detail: "Shi-tate does not change another app's microphone selection."
            )
            VStack(alignment: .leading, spacing: 10) {
                Label("Finish setup to save the default session.", systemImage: "1.circle")
                Label("Start routing from Dashboard or the menu bar.", systemImage: "2.circle")
                Label(
                    "Choose BlackHole 2ch as the microphone in the call app.",
                    systemImage: "3.circle")
                Label(
                    "Use Shi-tate's meters and mute control during the call.",
                    systemImage: "4.circle")
            }
            InlineNotice(
                title: "Avoid feedback",
                message:
                    "Do not monitor BlackHole through speakers while the microphone can hear them.",
                kind: .warning
            )
        }
    }

    private var complete: some View {
        setupHeading(
            symbol: "checkmark.circle.fill",
            title: "Setup complete",
            detail: "The default session is saved and routing remains stopped until you start it."
        )
    }

    private var actionBar: some View {
        HStack {
            if model.onboardingStep != .welcome && model.onboardingStep != .complete {
                Button("Back") {
                    model.returnToPreviousOnboardingStep()
                }
            }
            Spacer()
            if let error = model.onboardingError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if model.onboardingStep == .callAppGuide {
                Button("Finish Setup") {
                    model.finishOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !model.onboardingReadiness.audioIsValid
                        || model.sessionWorkflow == .saving
                )
                .keyboardShortcut(.defaultAction)
            } else if model.onboardingStep != .complete {
                Button(continueTitle) {
                    if model.onboardingStep == .blackHoleCheck
                        || model.onboardingStep == .installGuide
                    {
                        model.refreshEnvironment()
                    }
                    model.advanceOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(continueIsDisabled)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func setupHeading(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(detail)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var stepNumber: Int {
        min(model.onboardingStep.rawValue + 1, OnboardingStep.allCases.count - 1)
    }

    private var stepTitle: String {
        switch model.onboardingStep {
        case .welcome: "Welcome"
        case .blackHoleCheck: "BlackHole Check"
        case .installGuide: "Install BlackHole"
        case .microphonePermission: "Microphone Permission"
        case .audioSelection: "Audio Selection"
        case .audioValidation: "Audio Validation"
        case .pluginScan: "Plug-in Scan"
        case .chainSetup: "Chain Setup"
        case .callAppGuide: "Call App Setup"
        case .complete: "Complete"
        }
    }

    private var continueTitle: String {
        switch model.onboardingStep {
        case .blackHoleCheck: "Continue"
        case .installGuide: "Check Again"
        default: "Continue"
        }
    }

    private var continueIsDisabled: Bool {
        switch model.onboardingStep {
        case .microphonePermission:
            !model.onboardingReadiness.hasMicrophonePermission
        case .audioSelection:
            !model.onboardingReadiness.hasAudioSelection
        case .audioValidation:
            !model.onboardingReadiness.audioIsValid
        default:
            false
        }
    }

    private var compatiblePluginCount: Int {
        model.pluginCatalog.document.entries.filter { $0.compatibility == .compatible }.count
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
