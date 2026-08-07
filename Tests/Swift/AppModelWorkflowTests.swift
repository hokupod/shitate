// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import XCTest

final class AppModelWorkflowTests: XCTestCase {
    @MainActor
    func testFreshModelRestoresACompleteZeroPluginSession() throws {
        let fixture = try AppModelFixture()
        defer { fixture.remove() }
        try SessionStore(paths: fixture.paths).save(
            PersistedSession(document: .emptyDefault, pluginStates: [:])
        )
        let model = fixture.makeModel()

        model.restoreSavedSession()

        XCTAssertEqual(model.sessionWorkflow, .complete)
        XCTAssertEqual(model.loadedSession?.document, .emptyDefault)
        XCTAssertFalse(model.isOnboardingPresented)
    }

    @MainActor
    func testMissingSessionPresentsOnboardingWithoutStarting() throws {
        let fixture = try AppModelFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()

        model.restoreSavedSession()

        XCTAssertEqual(model.sessionWorkflow, .notLoaded)
        XCTAssertTrue(model.isOnboardingPresented)
        XCTAssertEqual(model.onboardingStep, .welcome)
        XCTAssertFalse(model.canStartRouting)
    }

    @MainActor
    func testSkippedRestoreNeverOverwritesTheSavedSession() throws {
        let fixture = try AppModelFixture()
        defer { fixture.remove() }
        let slotID = UUID()
        let original = PersistedSession(
            document: SessionDocument(
                schemaVersion: 1,
                id: "default",
                name: "Saved",
                updatedAt: "2026-08-07T00:00:00Z",
                slots: [
                    SessionSlotDocument(
                        slotID: slotID,
                        order: 0,
                        pluginFingerprint: String(repeating: "a", count: 64),
                        bundlePath: "/Library/Audio/Plug-Ins/VST3/Saved.vst3",
                        classUID: String(repeating: "b", count: 32),
                        name: "Saved",
                        manufacturer: "Tests",
                        version: "1.0",
                        bypassed: false,
                        stateFile: SessionSlotDocument.stateFile(for: slotID)
                    )
                ]
            ),
            pluginStates: [slotID: Data([1, 2, 3])]
        )
        try SessionStore(paths: fixture.paths).save(original)
        let model = fixture.makeModel()
        model.settings.restoreLastSession = false

        model.restoreSavedSession()
        model.state = .readyStopped
        XCTAssertEqual(model.apply(.startRequested), .starting)
        XCTAssertEqual(model.apply(.engineStarted), .running)
        XCTAssertEqual(model.apply(.stopRequested), .stopping)
        XCTAssertEqual(model.apply(.engineStopped), .readyStopped)
        model.handleEngineStoppedWorkflow()
        var cleanResult: Bool?
        model.prepareForTermination { cleanResult = $0 }

        XCTAssertEqual(model.sessionWorkflow, .restoreSkipped)
        XCTAssertEqual(cleanResult, true)
        XCTAssertEqual(try SessionStore(paths: fixture.paths).load(id: "default"), original)
    }

    @MainActor
    func testCleanQuitPublishesACompleteZeroPluginSession() throws {
        let fixture = try AppModelFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.sessionWorkflow = .complete

        var cleanResult: Bool?
        model.prepareForTermination { cleanResult = $0 }

        XCTAssertEqual(cleanResult, true)
        let persisted = try SessionStore(paths: fixture.paths).load(id: "default")
        XCTAssertEqual(persisted?.document.slots, [])
    }

    @MainActor
    func testQuitBeforeOnboardingCompletionDoesNotCreateASession() throws {
        let fixture = try AppModelFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.isOnboardingPresented = true
        model.sessionWorkflow = .notLoaded

        var cleanResult: Bool?
        model.prepareForTermination { cleanResult = $0 }

        XCTAssertEqual(cleanResult, true)
        XCTAssertNil(try SessionStore(paths: fixture.paths).load(id: "default"))
    }

    @MainActor
    func testSessionSaveFailureMakesQuitResultDirty() throws {
        let fixture = try AppModelFixture(unsafeSessionParent: true)
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.sessionWorkflow = .complete

        var saveResult: Bool?
        model.saveCurrentSession { saveResult = $0 }
        XCTAssertEqual(saveResult, false)

        var cleanResult: Bool?
        model.prepareForTermination { cleanResult = $0 }
        XCTAssertEqual(cleanResult, false)
    }

    @MainActor
    func testEditorOpenFailureIsVisibleAndRecorded() throws {
        let fixture = try AppModelFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.sessionWorkflow = .complete
        model.state = .readyStopped

        model.openPluginEditor(UUID())
        model.localLogService.flush()

        XCTAssertTrue(model.pluginEditorError?.contains("could not be opened") == true)
        let log = try String(contentsOf: model.localLogService.currentLogURL, encoding: .utf8)
        XCTAssertTrue(log.contains("pluginEditorOpenRequested"))
        XCTAssertTrue(log.contains("pluginEditorOpenFailed"))
        XCTAssertTrue(log.contains("code="))
        XCTAssertTrue(log.contains("domain="))
        XCTAssertTrue(log.contains("slot=unknown"))
        XCTAssertFalse(log.contains("message="))
        XCTAssertFalse(log.contains("slot was not found"))

        model.refreshPluginSlots()
        XCTAssertNil(model.pluginEditorError)
        XCTAssertNil(model.pluginEditorErrorSlotID)
        XCTAssertNil(model.lastError)
    }

    @MainActor
    func testBlockedEditorOpenReplacesStaleNoticeAndIsRecorded() throws {
        let fixture = try AppModelFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.pluginEditorError = "stale editor failure"
        model.lastError = model.pluginEditorError

        model.openPluginEditor(UUID())
        model.localLogService.flush()

        XCTAssertTrue(model.pluginEditorError?.contains("temporarily unavailable") == true)
        XCTAssertEqual(model.lastError, model.pluginEditorError)
        let log = try String(contentsOf: model.localLogService.currentLogURL, encoding: .utf8)
        XCTAssertTrue(log.contains("pluginEditorOpenBlocked"))
        XCTAssertTrue(log.contains("reason=chainUnavailable"))
    }

    @MainActor
    func testPreviewChoosesAnotherSupportedSharedBufferWithoutPersistingIt() throws {
        let fixture = try AppModelFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.state = .readyStopped
        model.sessionWorkflow = .complete
        model.bufferFrames = 256
        model.selectedInputUID = "microphone"
        model.inputDevices = [
            AudioDevice(
                id: "microphone",
                displayName: "USB Microphone",
                inputChannelNames: ["Mic"],
                allowedBufferFrames: [128, 256]
            )
        ]
        model.defaultOutputDevice = AudioDevice(
            id: "headphones",
            displayName: "USB Headphones",
            outputChannelNames: ["Left", "Right"],
            allowedBufferFrames: [128]
        )
        model.configuredOutputTarget = .blackHole

        XCTAssertEqual(model.previewBufferFrames, 128)
        XCTAssertNil(model.previewUnavailableReason)
        XCTAssertTrue(model.canStartPreview)
        XCTAssertEqual(model.bufferFrames, 256)
    }

    @MainActor
    func testPreviewExplainsManualAndVirtualOutputRejections() throws {
        let fixture = try AppModelFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.state = .readyStopped
        model.sessionWorkflow = .complete
        model.selectedInputUID = "microphone"
        model.inputDevices = [
            AudioDevice(
                id: "microphone",
                displayName: "USB Microphone",
                inputChannelNames: ["Mic"]
            )
        ]
        model.defaultOutputDevice = AudioDevice(
            id: "virtual",
            displayName: "Virtual Output",
            outputChannelNames: ["Left", "Right"],
            isPhysical: false
        )

        XCTAssertTrue(model.previewUnavailableReason?.contains("physical stereo") == true)
        model.routingMode = .manualAggregate
        XCTAssertTrue(model.previewUnavailableReason?.contains("Manual Aggregate") == true)
        XCTAssertFalse(model.canStartPreview)
    }

    @MainActor
    func testPersistenceFailureSilencesPreviewAndBlocksRestart() throws {
        let fixture = try AppModelFixture(unsafeSessionParent: true)
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let output = PreviewOutput(uid: "headphones", name: "USB Headphones")
        model.state = .running
        model.sessionWorkflow = .complete
        model.configuredOutputTarget = .systemPreview
        model.previewSession = .active(
            PreviewReturnContext(wasRouting: true, wasMuted: false),
            output
        )

        model.persistSettings()

        XCTAssertTrue(model.persistenceBlocksRouting)
        XCTAssertEqual(model.previewSession, .inactive)
        XCTAssertNil(model.configuredOutputTarget)
        XCTAssertFalse(model.canStartPreview)
        XCTAssertFalse(model.canStartRouting)
        XCTAssertEqual(model.state, .blocked(.unexpectedEngineState))
    }

    @MainActor
    func testStalePreviewConfigurationCannotStartBlackHoleRouting() throws {
        let fixture = try AppModelFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        model.state = .readyStopped
        model.sessionWorkflow = .complete
        model.configuredOutputTarget = .systemPreview

        XCTAssertFalse(model.canStartRouting)
        model.startRouting()

        XCTAssertNil(model.configuredOutputTarget)
        XCTAssertEqual(model.state, .needsAudioConfiguration)
        XCTAssertTrue(model.lastError?.contains("configured again") == true)
    }

    @MainActor
    func testPreviewRestartRejectsManualAggregateModeAndFailsClosed() throws {
        let fixture = try AppModelFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let output = PreviewOutput(uid: "headphones", name: "USB Headphones")
        model.state = .readyStopped
        model.sessionWorkflow = .complete
        model.routingMode = .manualAggregate
        model.configuredOutputTarget = .systemPreview
        model.previewSession = .active(
            PreviewReturnContext(wasRouting: true, wasMuted: false),
            output
        )

        model.restartPreviewAfterSuccessfulAudioOperation()

        XCTAssertEqual(model.previewSession, .inactive)
        XCTAssertNil(model.configuredOutputTarget)
        XCTAssertEqual(model.state, .needsAudioConfiguration)
        XCTAssertTrue(model.lastError?.contains("remains stopped") == true)
    }

    @MainActor
    func testPreviewRestartRejectsAChangedDefaultOutputAndFailsClosed() throws {
        let fixture = try AppModelFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let capturedOutput = PreviewOutput(uid: "headphones", name: "USB Headphones")
        model.state = .readyStopped
        model.sessionWorkflow = .complete
        model.configuredOutputTarget = .systemPreview
        model.previewSession = .active(
            PreviewReturnContext(wasRouting: true, wasMuted: true),
            capturedOutput
        )
        model.defaultOutputDevice = AudioDevice(
            id: "speakers",
            displayName: "MacBook Pro Speakers",
            outputChannelNames: ["Left", "Right"]
        )

        model.restartPreviewAfterSuccessfulAudioOperation()

        XCTAssertEqual(model.previewSession, .inactive)
        XCTAssertNil(model.configuredOutputTarget)
        XCTAssertEqual(model.state, .needsAudioConfiguration)
        XCTAssertTrue(model.lastError?.contains("eligible macOS main output") == true)
    }

    @MainActor
    func testPreviewRestartRejectsAMissingDefaultOutputAndFailsClosed() throws {
        let fixture = try AppModelFixture()
        defer { fixture.remove() }
        let model = fixture.makeModel()
        let capturedOutput = PreviewOutput(uid: "headphones", name: "USB Headphones")
        model.state = .readyStopped
        model.sessionWorkflow = .complete
        model.configuredOutputTarget = .systemPreview
        model.previewSession = .active(
            PreviewReturnContext(wasRouting: true, wasMuted: false),
            capturedOutput
        )
        model.defaultOutputDevice = nil

        model.restartPreviewAfterSuccessfulAudioOperation()

        XCTAssertEqual(model.previewSession, .inactive)
        XCTAssertNil(model.configuredOutputTarget)
        XCTAssertEqual(model.state, .needsAudioConfiguration)
        XCTAssertTrue(model.lastError?.contains("remains stopped") == true)
    }
}

@MainActor
private final class AppModelFixture {
    let root: URL
    let paths: ApplicationPaths

    init(unsafeSessionParent: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shitate-app-model-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        if unsafeSessionParent {
            try Data("not-a-directory".utf8).write(to: support)
        }
        paths = ApplicationPaths(
            applicationSupportDirectory: support,
            logsDirectory: root.appendingPathComponent("Logs", isDirectory: true)
        )
    }

    func makeModel() -> AppModel {
        let catalog = PluginCatalogService(
            store: PluginCatalogStore(fileURL: root.appendingPathComponent("catalog.json"))
        )
        return AppModel(
            permissionProvider: AppModelPermissionProvider(),
            workspaceEvents: WorkspaceEventService(notificationCenter: NotificationCenter()),
            pluginCatalog: catalog,
            paths: paths,
            settingsStore: SettingsStore(paths: paths),
            sessionStore: SessionStore(paths: paths),
            auxiliaryStore: AuxiliaryPersistenceStore(paths: paths),
            launchAtLoginService: LaunchAtLoginService(
                backend: LaunchAtLoginBackend(isEnabled: { false }, setEnabled: { _ in })
            ),
            globalHotKeyService: GlobalHotKeyService(backend: AppModelHotKeyBackend())
        )
    }

    nonisolated func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class AppModelPermissionProvider: MicrophonePermissionProviding {
    var status: MicrophonePermissionStatus { .authorized }

    func requestAccess() async -> Bool { true }
    func openSystemSettings() {}
}

@MainActor
private final class AppModelHotKeyBackend: GlobalHotKeyBackend {
    func register(action: @escaping () -> Void) throws {}
    func unregister() {}
}
