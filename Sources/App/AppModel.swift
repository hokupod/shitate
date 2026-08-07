// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Foundation
import Observation

enum AudioRoutingSelection: Int, CaseIterable, Identifiable {
    case automaticPrivateAggregate
    case manualAggregate

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .automaticPrivateAggregate:
            "Automatic"
        case .manualAggregate:
            "Manual Aggregate"
        }
    }

    var bridgeValue: STAudioRoutingMode {
        switch self {
        case .automaticPrivateAggregate:
            .automaticPrivateAggregate
        case .manualAggregate:
            .manualAggregate
        }
    }
}

struct MeterReading: Equatable {
    static let silence = MeterReading(
        inputPeakDB: -96,
        inputRmsDB: -96,
        outputPeakDB: -96,
        outputRmsDB: -96,
        inputClipping: false,
        outputClipping: false
    )

    let inputPeakDB: Float
    let inputRmsDB: Float
    let outputPeakDB: Float
    let outputRmsDB: Float
    let inputClipping: Bool
    let outputClipping: Bool

    init(_ value: STMeterSnapshot) {
        inputPeakDB = value.inputPeakDb
        inputRmsDB = value.inputRmsDb
        outputPeakDB = value.outputPeakDb
        outputRmsDB = value.outputRmsDb
        inputClipping = value.inputClipping
        outputClipping = value.outputClipping
    }

    private init(
        inputPeakDB: Float,
        inputRmsDB: Float,
        outputPeakDB: Float,
        outputRmsDB: Float,
        inputClipping: Bool,
        outputClipping: Bool
    ) {
        self.inputPeakDB = inputPeakDB
        self.inputRmsDB = inputRmsDB
        self.outputPeakDB = outputPeakDB
        self.outputRmsDB = outputRmsDB
        self.inputClipping = inputClipping
        self.outputClipping = outputClipping
    }
}

struct AudioDiagnostics: Equatable {
    static let empty = AudioDiagnostics(
        sampleRate: 0,
        bufferFrames: 0,
        inputLatencySamples: 0,
        outputLatencySamples: 0,
        pluginLatencySamples: 0,
        aggregateLatencySamples: 0,
        xrunCount: 0,
        callbackTimeEmaMicroseconds: 0
    )

    let sampleRate: Double
    let bufferFrames: Int
    let inputLatencySamples: Int
    let outputLatencySamples: Int
    let pluginLatencySamples: Int
    let aggregateLatencySamples: Int
    let xrunCount: Int
    let callbackTimeEmaMicroseconds: Double

    init(_ value: STEngineDiagnostics) {
        sampleRate = value.sampleRate
        bufferFrames = value.bufferFrames
        inputLatencySamples = value.inputLatencySamples
        outputLatencySamples = value.outputLatencySamples
        pluginLatencySamples = value.pluginLatencySamples
        aggregateLatencySamples = value.aggregateLatencySamples
        xrunCount = value.xrunCount
        callbackTimeEmaMicroseconds = value.callbackTimeEmaMicroseconds
    }

    private init(
        sampleRate: Double,
        bufferFrames: Int,
        inputLatencySamples: Int,
        outputLatencySamples: Int,
        pluginLatencySamples: Int,
        aggregateLatencySamples: Int,
        xrunCount: Int,
        callbackTimeEmaMicroseconds: Double
    ) {
        self.sampleRate = sampleRate
        self.bufferFrames = bufferFrames
        self.inputLatencySamples = inputLatencySamples
        self.outputLatencySamples = outputLatencySamples
        self.pluginLatencySamples = pluginLatencySamples
        self.aggregateLatencySamples = aggregateLatencySamples
        self.xrunCount = xrunCount
        self.callbackTimeEmaMicroseconds = callbackTimeEmaMicroseconds
    }
}

@MainActor
@Observable
final class AppModel: NSObject, STAudioEngineBridgeDelegate {
    private enum DefaultsKey {
        static let inputUID = "audio.inputUID"
        static let inputChannel = "audio.inputChannel"
        static let blackHoleUID = "audio.blackHoleUID"
        static let routingMode = "audio.routingMode"
        static let manualOutputChannelStart = "audio.manualOutputChannelStart"
        static let bufferFrames = "audio.bufferFrames"
        static let resumeAfterWake = "audio.resumeAfterWake"
    }

    private let bridge: STAudioEngineBridge
    private let permissionFlow: MicrophonePermissionFlow
    private let workspaceEvents: WorkspaceEventService
    let pluginCatalog: PluginCatalogService
    private let defaults: UserDefaults
    @ObservationIgnored nonisolated(unsafe) private var meterTask: Task<Void, Never>?
    private var bootstrapped = false
    private var nextPermissionCheck = ContinuousClock.now

    var state: ApplicationState = .booting
    var inputDevices: [AudioDevice] = []
    var outputDevices: [AudioDevice] = []
    var selectedInputUID: String?
    var selectedInputChannel = 0
    var routingMode: AudioRoutingSelection = .automaticPrivateAggregate
    var manualOutputChannelStart = 0
    var bufferFrames = 256
    var blackHoleUID: String?
    var meters: MeterReading = .silence
    var diagnostics: AudioDiagnostics = .empty
    var isMuted = false
    var lastError: String?
    var lastTransitionError: ApplicationTransitionError?
    var pluginCatalogError: String?
    var canAcceptDetectedBlackHole = false

    init(
        bridge: STAudioEngineBridge = STAudioEngineBridge(),
        permissionProvider: any MicrophonePermissionProviding = MicrophonePermissionService(),
        workspaceEvents: WorkspaceEventService = WorkspaceEventService(),
        pluginCatalog: PluginCatalogService = PluginCatalogService(),
        defaults: UserDefaults = .standard
    ) {
        self.bridge = bridge
        permissionFlow = MicrophonePermissionFlow(provider: permissionProvider)
        self.workspaceEvents = workspaceEvents
        self.pluginCatalog = pluginCatalog
        self.defaults = defaults
        selectedInputUID = defaults.string(forKey: DefaultsKey.inputUID)
        selectedInputChannel = defaults.integer(forKey: DefaultsKey.inputChannel)
        routingMode =
            AudioRoutingSelection(
                rawValue: defaults.integer(forKey: DefaultsKey.routingMode)
            ) ?? .automaticPrivateAggregate
        manualOutputChannelStart = defaults.integer(
            forKey: DefaultsKey.manualOutputChannelStart
        )
        let savedBuffer = defaults.integer(forKey: DefaultsKey.bufferFrames)
        bufferFrames = savedBuffer == 0 ? 256 : savedBuffer
        blackHoleUID = defaults.string(forKey: DefaultsKey.blackHoleUID)
        defaults.set(false, forKey: DefaultsKey.resumeAfterWake)
        super.init()
        bridge.delegate = self
        workspaceEvents.onWillSleep = { [weak self] in
            self?.handleWillSleep()
        }
        workspaceEvents.onDidWake = { [weak self] in
            self?.handleDidWake()
        }
    }

    deinit {
        meterTask?.cancel()
    }

    var selectedInput: AudioDevice? {
        guard let selectedInputUID else {
            return nil
        }
        return inputDevices.first { $0.id == selectedInputUID }
    }

    var selectableInputDevices: [AudioDevice] {
        inputDevices.filter {
            routingMode == .manualAggregate ? $0.isAggregate : !$0.isAggregate
        }
    }

    var selectedInputChannels: [String] {
        selectedInput?.inputChannelNames ?? []
    }

    var compatibleBufferFrames: [Int] {
        guard let input = selectedInput, let output = configuredOutput else {
            return []
        }
        return [128, 256, 512].filter {
            input.allowedBufferFrames.contains($0) && output.allowedBufferFrames.contains($0)
        }
    }

    var canApplyAudioSettings: Bool {
        !isRoutingActive
            && configurationValues() != nil
            && permissionFlow.status == .authorized
    }

    var canStartRouting: Bool {
        state == .readyStopped
    }

    var isRoutingActive: Bool {
        state == .starting || state == .running || state == .muted || state == .stopping
    }

    var statusTitle: String {
        switch state {
        case .booting, .checkingEnvironment:
            "Checking Audio"
        case .needsBlackHole:
            "BlackHole Required"
        case .needsMicrophonePermission:
            "Microphone Access Required"
        case .needsAudioConfiguration:
            "Audio Setup Required"
        case .readyStopped:
            "Ready"
        case .starting:
            "Starting"
        case .running:
            "Routing"
        case .muted:
            "Muted"
        case .stopping:
            "Stopping"
        case .recovering:
            "Recovering"
        case .blocked:
            "Routing Blocked"
        case .safeMode:
            "Safe Mode"
        case .fatal:
            "Fatal Error"
        }
    }

    var statusDetail: String {
        switch state {
        case .needsBlackHole:
            "BlackHole 2ch is missing or its saved identity changed. No alternate output was selected."
        case .needsMicrophonePermission:
            "Allow microphone access before routing. Output remains silent."
        case .needsAudioConfiguration:
            "Choose an input, channel, routing mode, and supported buffer in Audio Settings."
        case .readyStopped:
            "Audio is configured and stopped."
        case .running:
            "The selected input is routed to BlackHole 2ch."
        case .muted:
            "Routing is active with master output muted."
        case .blocked:
            "Routing stopped safely. Review the error and Audio Settings."
        default:
            "Shi-tate keeps output silent until every routing requirement is valid."
        }
    }

    var statusSymbol: String {
        switch state {
        case .running:
            "waveform.circle.fill"
        case .muted:
            "mic.slash"
        case .needsBlackHole, .needsMicrophonePermission, .needsAudioConfiguration, .blocked:
            "exclamationmark.triangle"
        case .fatal:
            "xmark.octagon"
        default:
            "waveform.circle"
        }
    }

    func bootstrap() async {
        guard !bootstrapped else {
            return
        }
        bootstrapped = true
        workspaceEvents.start()
        do {
            try pluginCatalog.load()
            let refresh = try pluginCatalog.refreshDiscoveredBundles()
            if !refresh.failedBundlePaths.isEmpty {
                pluginCatalogError =
                    "Some VST3 plug-ins could not be validated. They remain unavailable."
            }
        } catch {
            pluginCatalogError = "The plug-in catalog could not be validated. Rescan plug-ins."
        }
        refreshEnvironment()
        startMeterPolling()
    }

    func refreshEnvironment(acceptDetectedBlackHole: Bool = false) {
        guard apply(.beginEnvironmentCheck) == .checkingEnvironment else {
            return
        }
        reloadDeviceCatalog()

        var savedUID = blackHoleUID
        if acceptDetectedBlackHole {
            savedUID = nil
        }
        canAcceptDetectedBlackHole = false
        switch AudioEnvironment.blackHoleAvailability(
            outputDevices: outputDevices,
            savedUID: savedUID
        ) {
        case .missing:
            lastError = "BlackHole 2ch is not available. Routing remains silent."
            apply(.environmentChecked(.blackHoleMissing))
            return
        case .ambiguous:
            lastError =
                "Multiple BlackHole 2ch devices were found. Remove the duplicate before routing."
            apply(.environmentChecked(.blackHoleMissing))
            return
        case .identityChanged:
            canAcceptDetectedBlackHole = true
            lastError =
                "The saved BlackHole 2ch identity changed. Confirm the detected device before routing."
            apply(.environmentChecked(.blackHoleMissing))
            return
        case .available(let uid):
            blackHoleUID = uid
            defaults.set(uid, forKey: DefaultsKey.blackHoleUID)
        }

        guard permissionFlow.status == .authorized else {
            apply(.environmentChecked(.microphonePermissionMissing))
            return
        }

        guard configurationValues() != nil else {
            apply(.environmentChecked(.audioConfigurationMissing))
            return
        }
        applyAudioSettings()
    }

    func requestMicrophonePermission() async {
        let status = await permissionFlow.request()
        if status == .authorized {
            refreshEnvironment()
        } else {
            apply(.microphonePermissionLost)
        }
    }

    func openMicrophoneSystemSettings() {
        permissionFlow.openSystemSettings()
    }

    func acceptDetectedBlackHole() {
        refreshEnvironment(acceptDetectedBlackHole: canAcceptDetectedBlackHole)
    }

    func applyAudioSettings() {
        guard permissionFlow.status == .authorized else {
            apply(.microphonePermissionLost)
            return
        }
        guard let values = configurationValues() else {
            apply(.audioConfigurationInvalid)
            return
        }

        do {
            try bridge.configureInputDeviceUID(
                values.inputUID,
                channelIndex: values.channelIndex,
                outputDeviceUID: values.outputUID,
                blackHoleDeviceUID: values.blackHoleUID,
                mode: routingMode.bridgeValue,
                manualOutputChannelStart: values.manualOutputChannelStart,
                sampleRate: 48_000,
                bufferFrames: bufferFrames
            )
            bridge.setMasterMuted(isMuted)
            persistConfiguration()
            lastError = nil
            apply(.engineConfigured)
        } catch {
            handleBridgeError(error as NSError)
        }
    }

    func startRouting() {
        guard permissionFlow.status == .authorized else {
            apply(.microphonePermissionLost)
            return
        }
        let next = apply(.startRequested)
        guard next == .starting else {
            return
        }
        do {
            try bridge.start()
        } catch {
            handleBridgeError(error as NSError)
        }
    }

    func stopRouting() {
        let previous = state
        let next = apply(.stopRequested)
        guard next != previous else {
            return
        }
        bridge.stop()
    }

    func toggleMute() {
        guard state == .running || state == .muted else {
            return
        }
        isMuted.toggle()
        bridge.setMasterMuted(isMuted)
        apply(.muteChanged(isMuted))
    }

    func markAudioSettingsDirty() {
        guard !isRoutingActive else {
            return
        }
        switch state {
        case .readyStopped, .blocked:
            lastError = nil
            apply(.audioConfigurationInvalid)
        default:
            break
        }
    }

    private var configuredOutput: AudioDevice? {
        if routingMode == .manualAggregate {
            return selectedInput
        }
        guard let blackHoleUID else {
            return nil
        }
        return outputDevices.first { $0.id == blackHoleUID }
    }

    private func configurationValues() -> (
        inputUID: String,
        channelIndex: Int,
        outputUID: String,
        blackHoleUID: String,
        manualOutputChannelStart: Int
    )? {
        guard
            let input = selectedInput,
            input.isAlive,
            selectedInputChannel >= 0,
            selectedInputChannel < input.inputChannelNames.count,
            input.sampleRates.contains(where: { abs($0 - 48_000) < 0.5 }),
            compatibleBufferFrames.contains(bufferFrames),
            let blackHoleUID,
            let output = configuredOutput,
            output.isAlive,
            output.sampleRates.contains(where: { abs($0 - 48_000) < 0.5 })
        else {
            return nil
        }

        if routingMode == .automaticPrivateAggregate {
            guard !input.isAggregate, output.id == blackHoleUID else {
                return nil
            }
            return (input.id, selectedInputChannel, output.id, blackHoleUID, 0)
        }

        guard
            input.isAggregate,
            manualOutputChannelStart >= 0,
            manualOutputChannelStart + 1 < input.outputChannelNames.count
        else {
            return nil
        }
        return (
            input.id,
            selectedInputChannel,
            input.id,
            blackHoleUID,
            manualOutputChannelStart
        )
    }

    private func persistConfiguration() {
        defaults.set(selectedInputUID, forKey: DefaultsKey.inputUID)
        defaults.set(selectedInputChannel, forKey: DefaultsKey.inputChannel)
        defaults.set(routingMode.rawValue, forKey: DefaultsKey.routingMode)
        defaults.set(manualOutputChannelStart, forKey: DefaultsKey.manualOutputChannelStart)
        defaults.set(bufferFrames, forKey: DefaultsKey.bufferFrames)
    }

    private func startMeterPolling() {
        meterTask?.cancel()
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let interval: Duration
                guard let self else {
                    return
                }
                handleRuntimePermissionLoss()
                meters = MeterReading(bridge.meterSnapshot())
                diagnostics = AudioDiagnostics(bridge.diagnostics())
                interval =
                    state == .running || state == .muted
                    ? .milliseconds(33)
                    : .milliseconds(200)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func handleRuntimePermissionLoss() {
        let now = ContinuousClock.now
        guard now >= nextPermissionCheck else {
            return
        }
        nextPermissionCheck = now.advanced(by: .seconds(1))
        guard
            permissionFlow.status != .authorized,
            state == .starting || state == .running || state == .muted || state == .readyStopped
        else {
            return
        }
        if state == .starting || state == .running || state == .muted {
            bridge.stop()
        }
        isMuted = false
        lastError = "Microphone access was revoked. Routing stopped safely."
        apply(.microphonePermissionLost)
    }

    private func handleWillSleep() {
        let wasRouting = isRoutingActive
        apply(.sleep)
        if wasRouting {
            bridge.stop()
        }
    }

    private func handleDidWake() {
        refreshEnvironment()
    }

    private func handleEngineStatus(_ status: STEngineStatus) {
        switch status {
        case .stopped:
            apply(.engineStopped)
        case .configured:
            apply(.engineConfigured)
        case .starting:
            if state == .readyStopped {
                apply(.startRequested)
            }
        case .running:
            isMuted = false
            apply(.engineStarted)
        case .muted:
            isMuted = true
            apply(.muteChanged(true))
        case .stopping:
            if state == .running || state == .muted || state == .starting {
                apply(.stopRequested)
            }
        case .blocked:
            apply(.engineBlocked)
        @unknown default:
            apply(.engineFailed(.unexpectedEngineState))
        }
    }

    private func handleBridgeError(_ error: NSError) {
        lastError = error.localizedDescription
        switch error.code {
        case STBridgeError.Code.blackHoleMissing.rawValue:
            apply(.blackHoleRemoved)
        case STBridgeError.Code.outputDeviceMissing.rawValue:
            if routingMode == .automaticPrivateAggregate {
                apply(.blackHoleRemoved)
            } else {
                apply(.engineFailed(.outputDeviceMissing))
            }
        case STBridgeError.Code.microphonePermissionDenied.rawValue:
            apply(.microphonePermissionLost)
        case STBridgeError.Code.inputDeviceMissing.rawValue:
            apply(.engineFailed(.inputDeviceMissing))
        case STBridgeError.Code.unsupportedSampleRate.rawValue:
            apply(.engineFailed(.unsupportedSampleRate))
        case STBridgeError.Code.unsupportedBufferSize.rawValue:
            apply(.engineFailed(.unsupportedBufferSize))
        case STBridgeError.Code.aggregateDeviceCreationFailed.rawValue:
            apply(.engineFailed(.aggregateDeviceCreationFailed))
        default:
            apply(.engineFailed(.engineStartFailed))
        }
    }

    nonisolated func audioEngineBridge(
        _ bridge: STAudioEngineBridge, didChange status: STEngineStatus
    ) {
        Task { @MainActor [weak self] in
            self?.handleEngineStatus(status)
        }
    }

    nonisolated func audioEngineBridge(
        _ bridge: STAudioEngineBridge,
        didReceiveError error: any Error
    ) {
        let value = error as NSError
        Task { @MainActor [weak self] in
            self?.handleBridgeError(value)
        }
    }

    nonisolated func audioEngineBridgeDidChangeDevices(_ bridge: STAudioEngineBridge) {
        Task { @MainActor [weak self] in
            self?.refreshDeviceCatalog()
        }
    }

    private func refreshDeviceCatalog() {
        reloadDeviceCatalog()

        switch AudioEnvironment.blackHoleAvailability(
            outputDevices: outputDevices,
            savedUID: blackHoleUID
        ) {
        case .missing:
            canAcceptDetectedBlackHole = false
            lastError = "BlackHole 2ch is not available. Routing remains silent."
            apply(.blackHoleRemoved)
        case .ambiguous:
            canAcceptDetectedBlackHole = false
            lastError =
                "Multiple BlackHole 2ch devices were found. Remove the duplicate before routing."
            apply(.blackHoleRemoved)
        case .identityChanged:
            canAcceptDetectedBlackHole = true
            lastError =
                "The saved BlackHole 2ch identity changed. Confirm the detected device before routing."
            apply(.blackHoleRemoved)
        case .available(let uid):
            canAcceptDetectedBlackHole = false
            blackHoleUID = uid
            defaults.set(uid, forKey: DefaultsKey.blackHoleUID)
            if selectedInputUID != nil, selectedInput == nil {
                lastError = "The selected input device is no longer available."
                apply(.audioConfigurationInvalid)
            } else if state == .needsBlackHole {
                lastError = "BlackHole 2ch is available. Review Audio Settings before routing."
                apply(.audioConfigurationInvalid)
            }
        }
    }

    private func reloadDeviceCatalog() {
        let devices = bridge.audioDevices().map(AudioDevice.init)
        inputDevices = devices.filter { !$0.inputChannelNames.isEmpty }
        outputDevices = devices.filter { !$0.outputChannelNames.isEmpty }
    }

    @discardableResult
    private func apply(_ event: ApplicationEvent) -> ApplicationState {
        do {
            let next = try ApplicationStateReducer.reduce(state, event)
            state = next
            lastTransitionError = nil
            return next
        } catch let error as ApplicationTransitionError {
            lastTransitionError = error
            return state
        } catch {
            state = .fatal(.bridge(error.localizedDescription))
            return state
        }
    }
}
