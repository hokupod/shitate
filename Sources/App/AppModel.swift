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
    let runStateService: RunStateService
    let localLogService: LocalLogService
    let launchAtLoginService: LaunchAtLoginService
    let globalHotKeyService: GlobalHotKeyService
    @ObservationIgnored nonisolated(unsafe) private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var terminationCompletion: (@MainActor @Sendable (Bool) -> Void)?
    @ObservationIgnored private var isTerminationFinalizing = false
    @ObservationIgnored private var sessionSaveInFlight = false
    @ObservationIgnored private var sessionSaveFailed = false
    private var bootstrapped = false
    var startRoutingAtLaunchPending = false
    private var nextPermissionCheck = ContinuousClock.now
    var routingBeforeSleep = false
    var deviceRecoveryAttempted = false
    var wakeRecoveryInProgress = false
    var loadedSession: PersistedSession?
    var operationAfterStop: PendingAudioOperation?
    var resumeAfterOperation = false
    var approvedAdHocFingerprints = Set<String>()
    var blockedPluginFingerprints = Set<String>()
    var blockedPluginStateInvalid = false
    var failedRestoreSlotIDs = Set<UUID>()
    var safeModeSuspect: LoadingPluginDocument?
    var safeModeHistory: [RunHistoryRecord] = []

    var state: ApplicationState = .booting
    var settings: SettingsDocument = .defaults
    var inputDevices: [AudioDevice] = []
    var outputDevices: [AudioDevice] = []
    var defaultOutputDevice: AudioDevice?
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
    var pluginEditorError: String?
    var pluginEditorErrorSlotID: UUID?
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
    var previewSession: PreviewSessionState = .inactive
    var configuredOutputTarget: STAudioOutputTarget?

    init(
        bridge: STAudioEngineBridge = STAudioEngineBridge(),
        permissionProvider: any MicrophonePermissionProviding = MicrophonePermissionService(),
        workspaceEvents: WorkspaceEventService = WorkspaceEventService(),
        pluginCatalog: PluginCatalogService = PluginCatalogService(),
        paths: ApplicationPaths = .live,
        settingsStore: SettingsStore? = nil,
        sessionStore: SessionStore? = nil,
        auxiliaryStore: AuxiliaryPersistenceStore? = nil,
        runStateService: RunStateService? = nil,
        localLogService: LocalLogService? = nil,
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
        self.runStateService = runStateService ?? RunStateService(paths: paths)
        self.localLogService = localLogService ?? LocalLogService(paths: paths)
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
        let requiredTarget: STAudioOutputTarget =
            isPreviewSession ? .systemPreview : .blackHole
        return state == .readyStopped
            && (sessionWorkflow == .complete || sessionWorkflow == .restoreSkipped
                || ephemeralReducedChain)
            && !persistenceBlocksRouting
            && configuredOutputTarget == requiredTarget
    }

    var canStartPreview: Bool {
        previewSession == .inactive
            && (state == .readyStopped || state == .running || state == .muted)
            && (sessionWorkflow == .complete || sessionWorkflow == .restoreSkipped
                || ephemeralReducedChain)
            && pendingAudioOperation == nil
            && operationAfterStop == nil
            && !isPluginOperationInFlight
            && !terminationIsPending
            && !persistenceBlocksRouting
            && configuredOutputTarget == .blackHole
            && previewUnavailableReason == nil
    }

    var previewBufferFrames: Int? {
        guard let output = defaultOutputDevice else {
            return nil
        }
        return previewBufferFrames(for: output)
    }

    private func previewBufferFrames(for output: AudioDevice) -> Int? {
        guard let input = selectedInput else {
            return nil
        }
        return [bufferFrames, 256, 128, 512].first {
            [128, 256, 512].contains($0)
                && input.allowedBufferFrames.contains($0)
                && output.allowedBufferFrames.contains($0)
        }
    }

    var previewUnavailableReason: String? {
        guard routingMode == .automaticPrivateAggregate else {
            return "Preview is unavailable with Manual Aggregate routing."
        }
        guard let input = selectedInput, input.isAlive, !input.isAggregate, input.isPhysical else {
            return "Select an available physical microphone before previewing."
        }
        guard let output = defaultOutputDevice else {
            return "The macOS main output is unavailable."
        }
        guard output.isAlive, !output.isAggregate, output.isPhysical,
            output.outputChannelNames.count >= 2
        else {
            return "Preview requires a live, physical stereo main output."
        }
        guard output.id != blackHoleUID,
            output.displayName != AudioEnvironment.blackHoleDisplayName
        else {
            return "Choose speakers or headphones as the macOS main output instead of BlackHole."
        }
        guard input.sampleRates.contains(where: { abs($0 - 48_000) < 0.5 }),
            output.sampleRates.contains(where: { abs($0 - 48_000) < 0.5 })
        else {
            return "The microphone and main output must both support 48 kHz."
        }
        guard previewBufferFrames != nil else {
            return "The microphone and main output need a shared 128, 256, or 512-frame buffer."
        }
        return nil
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

    var isPreviewSession: Bool {
        previewSession != .inactive
    }

    var isPreviewActive: Bool {
        previewSession.isActive
    }

    var activeOutputDescription: String {
        if let output = previewSession.output {
            return "\(output.name) · Preview channels 1–2"
        }
        return "BlackHole 2ch · Channels 1–2"
    }

    var activeOutputName: String {
        previewSession.output?.name ?? AudioEnvironment.blackHoleDisplayName
    }

    var activeOutputUID: String {
        previewSession.output?.uid ?? blackHoleUID ?? settings.audio.outputDeviceUID
    }

    var statusTitle: String {
        statePresentation.title
    }

    var statusDetail: String {
        statePresentation.detail
    }

    var statusSymbol: String {
        statePresentation.symbol
    }

    var statePresentation: ApplicationStatePresentation {
        ApplicationStatePresentation(state: state, previewSession: previewSession)
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
        let runDecision: RunStateBootstrapDecision
        do {
            runDecision = try runStateService.beginRun()
            localLogService.log(
                "applicationLaunch", fields: ["safeMode": "\(runDecision.entersSafeMode)"])
        } catch {
            persistenceBlocksRouting = true
            cancelStartRoutingAtLaunch()
            state = .safeMode(.runStateWriteFailed)
            lastError = error.localizedDescription
            startMeterPolling()
            return
        }
        loadUserState()
        startRoutingAtLaunchPending = settings.startRoutingAtLaunch
        configureSystemPreferences()
        do {
            try pluginCatalog.load()
            approvedAdHocFingerprints = PluginApprovalAuthority.approvedAdHocFingerprints(
                allowAdHocSignedPlugins: settings.pluginPolicy.allowAdHocSignedPlugins,
                entries: pluginCatalog.document.entries
            )
        } catch {
            pluginCatalogError = "The plug-in catalog could not be validated. Rescan plug-ins."
        }

        blockedPluginFingerprints = runDecision.blockedFingerprints
        blockedPluginStateInvalid = runDecision.blockedPluginStateInvalid
        safeModeSuspect = runDecision.suspectPlugin
        safeModeHistory = runDecision.history
        if persistenceBlocksRouting {
            enterSafeMode(.stateMigrationFailed)
            startMeterPolling()
            return
        }
        if let reason = runDecision.safeModeReason {
            enterSafeMode(reason)
            startMeterPolling()
            return
        }

        do {
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

    func refreshEnvironment(
        acceptDetectedBlackHole: Bool = false,
        preserveDeviceRecoveryAttempt: Bool = false
    ) {
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
            guard !persistenceBlocksRouting else {
                return
            }
        }

        guard permissionFlow.status == .authorized else {
            apply(.environmentChecked(.microphonePermissionMissing))
            return
        }

        guard configurationValues() != nil else {
            apply(.environmentChecked(.audioConfigurationMissing))
            return
        }
        applyAudioSettings(preserveDeviceRecoveryAttempt: preserveDeviceRecoveryAttempt)
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

    func applyAudioSettings(preserveDeviceRecoveryAttempt: Bool = false) {
        guard permissionFlow.status == .authorized else {
            apply(.microphonePermissionLost)
            return
        }
        guard let values = configurationValues() else {
            apply(.audioConfigurationInvalid)
            return
        }

        configuredOutputTarget = nil
        do {
            try bridge.configureInputDeviceUID(
                values.inputUID,
                channelIndex: values.channelIndex,
                outputDeviceUID: values.outputUID,
                blackHoleDeviceUID: values.blackHoleUID,
                mode: routingMode.bridgeValue,
                outputTarget: .blackHole,
                manualOutputChannelStart: values.manualOutputChannelStart,
                sampleRate: 48_000,
                bufferFrames: bufferFrames
            )
            configuredOutputTarget = .blackHole
            bridge.setMasterMuted(isMuted)
            persistConfiguration()
            guard !persistenceBlocksRouting else {
                return
            }
            if !preserveDeviceRecoveryAttempt {
                deviceRecoveryAttempted = false
            }
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
        let requiredTarget: STAudioOutputTarget =
            isPreviewSession ? .systemPreview : .blackHole
        guard configuredOutputTarget == requiredTarget else {
            bridge.setMasterMuted(true)
            bridge.stop()
            configuredOutputTarget = nil
            lastError = "Audio output must be configured again before routing can start."
            apply(.audioConfigurationInvalid)
            return
        }
        let next = apply(.startRequested)
        guard next == .starting else {
            return
        }
        let operation = isPreviewSession ? "startPreview" : "startRouting"
        guard recordRunOperation(operation, routingWasActive: true) else {
            return
        }
        localLogService.log(isPreviewSession ? "previewStartRequested" : "routingStartRequested")
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
        let operation = isPreviewSession ? "stopPreviewAudio" : "stopRouting"
        _ = recordRunOperation(operation, routingWasActive: false)
        localLogService.log(isPreviewSession ? "previewAudioStopRequested" : "routingStopRequested")
        bridge.stop()
    }

    func startPreview() {
        guard canStartPreview, let target = defaultOutputDevice else {
            if let reason = previewUnavailableReason {
                lastError = reason
            }
            return
        }

        cancelStartRoutingAtLaunch()
        let output = PreviewOutput(uid: target.id, name: target.displayName)
        guard
            let nextSession = PreviewSessionState.begin(
                from: state,
                isMuted: isMuted,
                output: output
            ), let context = nextSession.returnContext
        else {
            return
        }
        previewSession = nextSession
        lastError = nil
        localLogService.log("previewSwitchRequested", fields: ["output": output.name])

        if context.wasRouting {
            stopRouting()
        } else {
            configureAndStartPreview(context: context, output: output)
        }
    }

    func stopPreview() {
        guard let returningSession = previewSession.beginReturn(),
            let context = returningSession.returnContext,
            let output = returningSession.output,
            state == .running || state == .muted,
            !isPluginOperationInFlight,
            pendingAudioOperation == nil,
            operationAfterStop == nil
        else {
            return
        }
        previewSession = returningSession
        localLogService.log("previewReturnRequested", fields: ["output": output.name])
        if isRoutingActive {
            stopRouting()
        } else {
            restoreBlackHoleAfterPreview(context: context)
        }
    }

    func performPrimaryAudioAction() {
        if isPreviewSession {
            stopPreview()
        } else if isRoutingActive {
            stopRouting()
        } else {
            startRouting()
        }
    }

    var primaryAudioActionTitle: String {
        if isPreviewSession {
            return "Stop Preview"
        }
        return isRoutingActive ? "Stop Routing" : "Start Routing"
    }

    var primaryAudioActionDisabled: Bool {
        if previewSession.isTransitioning || isPluginOperationInFlight
            || pendingAudioOperation != nil || operationAfterStop != nil
        {
            return true
        }
        if isPreviewSession {
            return !isPreviewActive || (state != .running && state != .muted)
        }
        switch state {
        case .starting, .stopping:
            return true
        default:
            return !isRoutingActive && !canStartRouting
        }
    }

    @discardableResult
    func continuePreviewTransitionAfterStop() -> Bool {
        switch previewSession {
        case .switchingToPreview(let context, let output):
            configureAndStartPreview(context: context, output: output)
            return true
        case .returning(let context, _):
            restoreBlackHoleAfterPreview(context: context)
            return true
        case .inactive, .active:
            return false
        }
    }

    func cancelPreviewSession() {
        if isPreviewSession {
            configuredOutputTarget = nil
        }
        previewSession = previewSession.failClosed()
    }

    func restoreBlackHoleAfterPreviewFailure() {
        guard isPreviewSession else {
            return
        }
        let operationError = lastError
        previewSession = .inactive
        configuredOutputTarget = nil
        guard state == .readyStopped else {
            return
        }
        if configureBlackHole(startAfterConfiguration: false, muted: isMuted) {
            lastError = operationError
        }
    }

    func restartPreviewAfterSuccessfulAudioOperation() {
        guard state == .readyStopped,
            let restartingSession = previewSession.prepareRestart(),
            let context = restartingSession.returnContext,
            let output = restartingSession.output
        else {
            failClosedPreviewConfiguration(
                "Preview could not be resumed after the audio operation."
            )
            return
        }
        previewSession = restartingSession
        configureAndStartPreview(context: context, output: output)
    }

    private func configureAndStartPreview(
        context: PreviewReturnContext,
        output: PreviewOutput
    ) {
        guard case .switchingToPreview = previewSession,
            routingMode == .automaticPrivateAggregate,
            let currentOutput = defaultOutputDevice,
            currentOutput.id == output.uid,
            previewUnavailableReason == nil,
            let values = configurationValues(),
            let previewBufferFrames = previewBufferFrames(for: currentOutput)
        else {
            failClosedPreviewConfiguration(
                "The Preview output is no longer the current eligible macOS main output."
            )
            return
        }

        configuredOutputTarget = nil
        do {
            try bridge.configureInputDeviceUID(
                values.inputUID,
                channelIndex: values.channelIndex,
                outputDeviceUID: output.uid,
                blackHoleDeviceUID: values.blackHoleUID,
                mode: .automaticPrivateAggregate,
                outputTarget: .systemPreview,
                manualOutputChannelStart: 0,
                sampleRate: 48_000,
                bufferFrames: previewBufferFrames
            )
            configuredOutputTarget = .systemPreview
            bridge.setMasterMuted(context.wasMuted)
            isMuted = context.wasMuted
            apply(.engineConfigured)
            startRouting()
        } catch {
            handleBridgeError(error as NSError)
        }
    }

    private func failClosedPreviewConfiguration(_ message: String) {
        bridge.setMasterMuted(true)
        bridge.stop()
        configuredOutputTarget = nil
        cancelPreviewSession()
        lastError = "\(message) Preview remains stopped."
        if state == .readyStopped {
            apply(.audioConfigurationInvalid)
        }
    }

    private func restoreBlackHoleAfterPreview(context: PreviewReturnContext) {
        previewSession = .inactive
        configureBlackHole(
            startAfterConfiguration: context.wasRouting,
            muted: context.wasMuted
        )
    }

    @discardableResult
    private func configureBlackHole(startAfterConfiguration: Bool, muted: Bool) -> Bool {
        configuredOutputTarget = nil
        guard let values = configurationValues() else {
            lastError = "The saved BlackHole route is incomplete. Audio remains stopped."
            apply(.audioConfigurationInvalid)
            return false
        }
        do {
            try bridge.configureInputDeviceUID(
                values.inputUID,
                channelIndex: values.channelIndex,
                outputDeviceUID: values.outputUID,
                blackHoleDeviceUID: values.blackHoleUID,
                mode: routingMode.bridgeValue,
                outputTarget: .blackHole,
                manualOutputChannelStart: values.manualOutputChannelStart,
                sampleRate: 48_000,
                bufferFrames: bufferFrames
            )
            configuredOutputTarget = .blackHole
            bridge.setMasterMuted(muted)
            isMuted = muted
            lastError = nil
            apply(.engineConfigured)
            if startAfterConfiguration {
                startRouting()
            }
            return true
        } catch {
            handleBridgeError(error as NSError)
            return false
        }
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
        configuredOutputTarget = nil
        cancelPreviewSession()
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
        failClosedForDeviceEvent(
            .microphonePermissionLost,
            message: "Microphone access was revoked. Routing stopped safely."
        )
    }

    private func handleWillSleep() {
        let previewWasActive = isPreviewSession
        routingBeforeSleep = isRoutingActive && !previewWasActive
        _ = recordRunOperation("sleep", routingWasActive: routingBeforeSleep)
        bridge.setMasterMuted(true)
        apply(.sleep)
        bridge.stop()
        configuredOutputTarget = nil
        cancelPreviewSession()
    }

    private func handleDidWake() {
        recoverAfterWake()
    }

    private func handleEngineStatus(_ status: STEngineStatus) {
        let wasStopping = state == .stopping
        if status == .running {
            deviceRecoveryAttempted = false
            isMuted = false
        } else if status == .muted {
            isMuted = true
        }

        let event = EngineStatusEventMapper.event(for: status, while: state)
        apply(event)

        if status == .running || status == .muted,
            let activeSession = previewSession.markActive(),
            let output = activeSession.output
        {
            previewSession = activeSession
            localLogService.log("previewStarted", fields: ["output": output.name])
        }

        if status == .stopped || (status == .configured && wasStopping) {
            if !continuePreviewTransitionAfterStop() {
                handleEngineStoppedWorkflow()
            }
        } else if status == .configured {
            attemptStartRoutingAtLaunch()
        }
        continueTerminationIfPossible()
    }

    private func handleBridgeError(_ error: NSError) {
        let previewWasActive = isPreviewSession
        let wasRouting = isRoutingActive && !previewWasActive
        configuredOutputTarget = nil
        if previewWasActive {
            cancelPreviewSession()
        }
        localLogService.log(
            "audioBridgeError",
            fields: ["code": "\(error.code)", "domain": error.domain]
        )
        switch error.code {
        case STBridgeError.Code.blackHoleMissing.rawValue:
            failClosedForDeviceEvent(
                .blackHoleRemoved,
                message: "BlackHole 2ch was removed. No alternate output was selected."
            )
        case STBridgeError.Code.outputDeviceMissing.rawValue:
            if routingMode == .automaticPrivateAggregate {
                failClosedForDeviceEvent(
                    .blackHoleRemoved,
                    message: "BlackHole 2ch was removed. No alternate output was selected."
                )
            } else {
                failClosedForDeviceEvent(
                    .engineFailed(.outputDeviceMissing),
                    message: "The selected aggregate output is unavailable."
                )
            }
        case STBridgeError.Code.microphonePermissionDenied.rawValue:
            failClosedForDeviceEvent(
                .microphonePermissionLost,
                message: "Microphone access was revoked. Open System Settings to restore access."
            )
        case STBridgeError.Code.inputDeviceMissing.rawValue:
            failClosedForDeviceEvent(
                .inputDeviceRemoved,
                message: "The selected input was removed. No alternate input was selected."
            )
        case STBridgeError.Code.unsupportedSampleRate.rawValue:
            bridge.setMasterMuted(true)
            bridge.stop()
            if previewWasActive {
                failClosedForDeviceEvent(
                    .engineFailed(.unsupportedSampleRate),
                    message: "Preview stopped because the main output could not remain at 48 kHz."
                )
            } else {
                attemptOneDeviceReset(issue: .unsupportedSampleRate, wasRouting: wasRouting)
            }
        case STBridgeError.Code.unsupportedBufferSize.rawValue:
            bridge.setMasterMuted(true)
            bridge.stop()
            if previewWasActive {
                failClosedForDeviceEvent(
                    .engineFailed(.unsupportedBufferSize),
                    message: "Preview stopped because the shared buffer size became unavailable."
                )
            } else {
                attemptOneDeviceReset(issue: .unsupportedBufferSize, wasRouting: wasRouting)
            }
        case STBridgeError.Code.aggregateDeviceCreationFailed.rawValue:
            failClosedForDeviceEvent(
                .engineFailed(.aggregateDeviceCreationFailed),
                message: "The private CoreAudio route could not be created. Output remains silent."
            )
        case STBridgeError.Code.previewOutputUnavailable.rawValue:
            failClosedForDeviceEvent(
                .engineFailed(.outputDeviceMissing),
                message:
                    "Preview requires a live, non-aggregate stereo main output at 48 kHz."
            )
        case STBridgeError.Code.previewOutputChanged.rawValue:
            failClosedForDeviceEvent(
                .engineFailed(.outputDeviceMissing),
                message:
                    "Preview stopped because the macOS main output changed. Start it again explicitly."
            )
        default:
            failClosedForDeviceEvent(
                .engineFailed(.engineStartFailed),
                message:
                    "Audio routing is unavailable and output remains silent. "
                    + "Review Audio Settings before trying again."
            )
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

        guard safeModeReason == nil else {
            return
        }

        switch AudioEnvironment.blackHoleAvailability(
            outputDevices: outputDevices,
            savedUID: blackHoleUID
        ) {
        case .missing:
            canAcceptDetectedBlackHole = false
            failClosedForDeviceEvent(
                .blackHoleRemoved,
                message: "BlackHole 2ch is not available. No alternate output was selected."
            )
            return
        case .ambiguous:
            canAcceptDetectedBlackHole = false
            failClosedForDeviceEvent(
                .blackHoleRemoved,
                message:
                    "Multiple BlackHole 2ch devices were found. Remove the duplicate before routing."
            )
            return
        case .identityChanged:
            canAcceptDetectedBlackHole = true
            failClosedForDeviceEvent(
                .blackHoleRemoved,
                message:
                    "The saved BlackHole 2ch identity changed. Confirm it before routing."
            )
            return
        case .available(let uid):
            canAcceptDetectedBlackHole = false
            blackHoleUID = uid
            settings.audio.outputDeviceUID = uid
            settings.audio.outputDeviceName = AudioEnvironment.blackHoleDisplayName
            persistSettings()
            if selectedInputUID != nil, selectedInput == nil {
                failClosedForDeviceEvent(
                    .inputDeviceRemoved,
                    message: "The selected input is unavailable. No alternate input was selected."
                )
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
        defaultOutputDevice = bridge.defaultOutputDevice().map(AudioDevice.init)
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
        var finalClean = clean
        if clean, runStateService.currentState != nil {
            do {
                try runStateService.markClean(routingWasActive: false)
            } catch {
                finalClean = false
                lastError = error.localizedDescription
            }
        }
        let completion = terminationCompletion
        terminationCompletion = nil
        isTerminationFinalizing = false
        completion?(finalClean)
    }
}
