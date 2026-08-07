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
