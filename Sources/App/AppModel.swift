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
    let bridge: STAudioEngineBridge
    private let permissionFlow: MicrophonePermissionFlow
    private let workspaceEvents: WorkspaceEventService
    let pluginCatalog: PluginCatalogService
    let paths: ApplicationPaths
    let settingsStore: SettingsStore
    let sessionStore: SessionStore
    let auxiliaryStore: AuxiliaryPersistenceStore
    let launchAtLoginService: LaunchAtLoginService
    let globalHotKeyService: GlobalHotKeyService
    @ObservationIgnored nonisolated(unsafe) private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var terminationCompletion: (@MainActor @Sendable (Bool) -> Void)?
    @ObservationIgnored private var isTerminationFinalizing = false
    @ObservationIgnored private var sessionSaveInFlight = false
    @ObservationIgnored private var sessionSaveFailed = false
    private var bootstrapped = false
    private var startRoutingAtLaunchPending = false
    private var nextPermissionCheck = ContinuousClock.now
    var loadedSession: PersistedSession?
    var operationAfterStop: PendingAudioOperation?
    var resumeAfterOperation = false
    var approvedAdHocFingerprints = Set<String>()
    var failedRestoreSlotIDs = Set<UUID>()

    var state: ApplicationState = .booting
    var settings: SettingsDocument = .defaults
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
    var pluginSlots: [PluginSlotPresentation] = []
    var sessionWorkflow: SessionWorkflowState = .notLoaded
    var pendingAudioOperation: PendingAudioOperation?
    var isPluginOperationInFlight = false
    var ephemeralReducedChain = false
    var selectedSection: ProductSection = .dashboard
    var isOnboardingPresented = false
    var onboardingStep: OnboardingStep = .welcome
    var pluginSearchText = ""
    var pluginCompatibilityFilter: PluginCompatibilityFilter = .all
    var pluginManufacturerFilter = "All Manufacturers"
    var additionalPluginFolders: [String] = []
    var onboardingError: String?
    var persistenceBlocksRouting = false

    init(
        bridge: STAudioEngineBridge = STAudioEngineBridge(),
        permissionProvider: any MicrophonePermissionProviding = MicrophonePermissionService(),
        workspaceEvents: WorkspaceEventService = WorkspaceEventService(),
        pluginCatalog: PluginCatalogService = PluginCatalogService(),
        paths: ApplicationPaths = .live,
        settingsStore: SettingsStore? = nil,
        sessionStore: SessionStore? = nil,
        auxiliaryStore: AuxiliaryPersistenceStore? = nil,
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        globalHotKeyService: GlobalHotKeyService = GlobalHotKeyService()
    ) {
        self.bridge = bridge
        permissionFlow = MicrophonePermissionFlow(provider: permissionProvider)
        self.workspaceEvents = workspaceEvents
        self.pluginCatalog = pluginCatalog
        self.paths = paths
        self.settingsStore = settingsStore ?? SettingsStore(paths: paths)
        self.sessionStore = sessionStore ?? SessionStore(paths: paths)
        self.auxiliaryStore = auxiliaryStore ?? AuxiliaryPersistenceStore(paths: paths)
        self.launchAtLoginService = launchAtLoginService
        self.globalHotKeyService = globalHotKeyService
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
            && !persistenceBlocksRouting
    }

    var canStartRouting: Bool {
        state == .readyStopped
            && (sessionWorkflow == .complete || sessionWorkflow == .restoreSkipped
                || ephemeralReducedChain)
            && !persistenceBlocksRouting
    }

    var canEditPluginChain: Bool {
        sessionWorkflow == .complete
            && !isPluginOperationInFlight
            && pendingAudioOperation == nil
            && operationAfterStop == nil
            && state != .starting
            && state != .stopping
            && !terminationIsPending
    }

    var canAddPlugin: Bool {
        canEditPluginChain && pluginSlots.count < SessionDocument.maximumSlots
    }

    var canRecoverSession: Bool {
        if case .incomplete = sessionWorkflow {
            return loadedSession != nil
                && !isPluginOperationInFlight
                && pendingAudioOperation == nil
                && operationAfterStop == nil
                && state != .starting
                && state != .stopping
                && !terminationIsPending
        }
        return false
    }

    var isRoutingActive: Bool {
        state == .starting || state == .running || state == .muted || state == .stopping
    }

    var statusTitle: String {
        ApplicationStatePresentation(state: state).title
    }

    var statusDetail: String {
        ApplicationStatePresentation(state: state).detail
    }

    var statusSymbol: String {
        ApplicationStatePresentation(state: state).symbol
    }

    var statePresentation: ApplicationStatePresentation {
        ApplicationStatePresentation(state: state)
    }

    var hasMicrophonePermission: Bool {
        permissionFlow.status == .authorized
    }

    func bootstrap() async {
        guard !bootstrapped else {
            return
        }
        bootstrapped = true
        workspaceEvents.start()
        loadUserState()
        startRoutingAtLaunchPending = settings.startRoutingAtLaunch
        configureSystemPreferences()
        do {
            try pluginCatalog.load()
            approvedAdHocFingerprints = PluginApprovalAuthority.approvedAdHocFingerprints(
                allowAdHocSignedPlugins: settings.pluginPolicy.allowAdHocSignedPlugins,
                entries: pluginCatalog.document.entries
            )
            let refresh = try pluginCatalog.refreshDiscoveredBundles(
                inAdditionalFolders: additionalPluginFolders,
                approvedAdHocFingerprints: approvedAdHocFingerprints
            )
            if !refresh.failedBundlePaths.isEmpty {
                pluginCatalogError =
                    "Some VST3 plug-ins could not be validated. They remain unavailable."
            }
        } catch {
            pluginCatalogError = "The plug-in catalog could not be validated. Rescan plug-ins."
        }
        refreshEnvironment()
        restoreSavedSession()
        startMeterPolling()
    }

    func refreshEnvironment(acceptDetectedBlackHole: Bool = false) {
        guard !persistenceBlocksRouting else {
            apply(.engineFailed(.unexpectedEngineState))
            return
        }
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
            settings.audio.outputDeviceUID = uid
            settings.audio.outputDeviceName = AudioEnvironment.blackHoleDisplayName
            persistSettings()
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
            attemptStartRoutingAtLaunch()
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

    func prepareForTermination(
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard terminationCompletion == nil else {
            return
        }
        terminationCompletion = completion
        pendingAudioOperation = nil
        operationAfterStop = nil
        resumeAfterOperation = false
        globalHotKeyService.unregister()

        if bridgeIsRoutingActive {
            if state == .starting || state == .running || state == .muted {
                apply(.stopRequested)
            }
            bridge.stop()
        }
        continueTerminationIfPossible()
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
        settings.audio.mode =
            routingMode == .automaticPrivateAggregate
            ? .automaticPrivateAggregate : .manualAggregate
        settings.audio.inputDeviceUID = selectedInputUID ?? ""
        settings.audio.inputDeviceName = selectedInput?.displayName ?? ""
        settings.audio.inputChannelIndex = selectedInputChannel
        settings.audio.outputDeviceUID = blackHoleUID ?? ""
        settings.audio.outputDeviceName = AudioEnvironment.blackHoleDisplayName
        settings.audio.manualOutputChannelStart = manualOutputChannelStart
        settings.audio.sampleRate = 48_000
        settings.audio.bufferFrames = bufferFrames
        persistSettings()
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
        let wasStopping = state == .stopping
        if status == .running {
            isMuted = false
        } else if status == .muted {
            isMuted = true
        }

        let event = EngineStatusEventMapper.event(for: status, while: state)
        apply(event)

        if status == .stopped || (status == .configured && wasStopping) {
            handleEngineStoppedWorkflow()
        } else if status == .configured {
            attemptStartRoutingAtLaunch()
        }
        continueTerminationIfPossible()
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

    nonisolated func audioEngineBridge(
        _ bridge: STAudioEngineBridge,
        didFaultPluginSlotWith slotID: UUID
    ) {
        Task { @MainActor [weak self] in
            self?.refreshPluginSlots()
            self?.lastError =
                "A plug-in faulted and was bypassed for safety. Routing continued with its input."
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
            settings.audio.outputDeviceUID = uid
            settings.audio.outputDeviceName = AudioEnvironment.blackHoleDisplayName
            persistSettings()
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
    func apply(_ event: ApplicationEvent) -> ApplicationState {
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

    func attemptStartRoutingAtLaunch() {
        guard
            startRoutingAtLaunchPending,
            state == .readyStopped,
            sessionWorkflow == .complete,
            !isOnboardingPresented,
            !persistenceBlocksRouting
        else {
            return
        }
        startRoutingAtLaunchPending = false
        startRouting()
    }

    func cancelStartRoutingAtLaunch() {
        startRoutingAtLaunchPending = false
    }

    var terminationIsPending: Bool {
        terminationCompletion != nil
    }

    func beginSessionSave() -> Bool {
        guard !sessionSaveInFlight else {
            return false
        }
        sessionSaveInFlight = true
        return true
    }

    func recordSessionSaveFinished(success: Bool) {
        sessionSaveInFlight = false
        sessionSaveFailed = !success
    }

    func continueTerminationIfPossible() {
        guard
            terminationCompletion != nil,
            !isTerminationFinalizing,
            !bridgeIsRoutingActive,
            !isPluginOperationInFlight,
            !sessionSaveInFlight,
            sessionWorkflow != .restoring
        else {
            return
        }

        isTerminationFinalizing = true
        for slot in bridge.pluginSlots() {
            try? bridge.closeEditorForPluginSlot(with: slot.slotID)
        }

        guard !sessionSaveFailed else {
            finishTermination(clean: false)
            return
        }
        guard sessionWorkflow == .complete, !ephemeralReducedChain else {
            finishTermination(clean: true)
            return
        }

        saveCurrentSession { [weak self] success in
            self?.finishTermination(clean: success)
        }
    }

    private var bridgeIsRoutingActive: Bool {
        switch bridge.status {
        case .starting, .running, .muted, .stopping:
            true
        case .stopped, .configured, .blocked:
            false
        @unknown default:
            true
        }
    }

    private func finishTermination(clean: Bool) {
        let completion = terminationCompletion
        terminationCompletion = nil
        isTerminationFinalizing = false
        completion?(clean)
    }
}
