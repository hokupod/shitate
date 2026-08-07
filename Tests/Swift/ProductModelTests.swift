// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import XCTest

final class ProductModelTests: XCTestCase {
    func testEveryProductSectionHasStableNativeNavigationMetadata() {
        XCTAssertEqual(ProductSection.allCases.count, 5)
        for section in ProductSection.allCases {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertFalse(section.symbol.isEmpty)
        }
    }

    func testEveryApplicationStateHasAccessibleStatusCopy() {
        for state in representativeStates {
            let presentation = ApplicationStatePresentation(state: state)
            XCTAssertFalse(presentation.title.isEmpty)
            XCTAssertFalse(presentation.detail.isEmpty)
            XCTAssertFalse(presentation.symbol.isEmpty)
        }
    }

    func testPluginEnablementIsInverseOfBypassState() {
        let enabled = pluginSlot(isBypassed: false)
        let bypassed = pluginSlot(isBypassed: true)

        XCTAssertTrue(enabled.isEnabled)
        XCTAssertFalse(bypassed.isEnabled)
    }

    func testBlockedAndFatalStatesExplainStoppedOutputAndNextAction() {
        for state in [
            ApplicationState.blocked(.engineStartFailed),
            .fatal(.bridge("test")),
        ] {
            let presentation = ApplicationStatePresentation(state: state)
            XCTAssertTrue(presentation.outputIsStopped)
            XCTAssertNotNil(presentation.nextAction)
            XCTAssertTrue(
                presentation.detail.localizedCaseInsensitiveContains("stopped")
                    || presentation.detail.localizedCaseInsensitiveContains("silent")
            )
        }
    }

    func testOnboardingBranchesForMissingRequirements() {
        let missing = OnboardingReadiness(
            hasBlackHole: false,
            hasMicrophonePermission: false,
            hasAudioSelection: false,
            audioIsValid: false
        )
        XCTAssertEqual(
            OnboardingFlow.next(after: .blackHoleCheck, readiness: missing),
            .installGuide
        )
        XCTAssertEqual(
            OnboardingFlow.next(after: .microphonePermission, readiness: missing),
            .microphonePermission
        )
        XCTAssertEqual(
            OnboardingFlow.next(after: .audioSelection, readiness: missing),
            .audioSelection
        )
    }

    func testZeroPluginOnboardingContinuesToCallAppGuide() {
        let ready = OnboardingReadiness(
            hasBlackHole: true,
            hasMicrophonePermission: true,
            hasAudioSelection: true,
            audioIsValid: true
        )
        XCTAssertEqual(
            OnboardingFlow.next(after: .pluginScan, readiness: ready),
            .chainSetup
        )
        XCTAssertEqual(
            OnboardingFlow.next(after: .chainSetup, readiness: ready),
            .callAppGuide
        )
        XCTAssertEqual(
            OnboardingFlow.next(after: .callAppGuide, readiness: ready),
            .complete
        )
    }

    func testAudioInterruptionsAlwaysExplainPauseAndConditionalResume() {
        let operations: [PendingAudioOperation] = [
            .addPlugin("fingerprint"),
            .removePlugin(UUID()),
            .movePlugin(UUID(), 0),
            .setPluginBypassed(UUID(), true),
            .setAllPluginsBypassed(true),
            .saveSession,
        ]
        for operation in operations {
            XCTAssertTrue(
                operation.interruptionMessage.localizedCaseInsensitiveContains("pauses audio")
            )
            XCTAssertTrue(
                operation.interruptionMessage.localizedCaseInsensitiveContains("only")
            )
        }
    }

    func testRecoveryInterruptionsExplainStoppedOnlyBehavior() {
        let operations: [PendingAudioOperation] = [
            .retrySessionRestore,
            .rescanAndRetrySessionRestore,
            .removeUnavailablePlugins,
            .startWithoutUnavailablePlugins,
        ]
        for operation in operations {
            XCTAssertTrue(
                operation.interruptionMessage.localizedCaseInsensitiveContains("stop")
            )
        }
    }

    func testAdHocApprovalAuthorityUsesOnlyLiveCompatibleCatalogEntries() {
        let approved = catalogEntry(
            fingerprint: "approved",
            signatureKind: .adHoc,
            compatibility: .compatible
        )
        let blocked = catalogEntry(
            fingerprint: "blocked",
            signatureKind: .adHoc,
            compatibility: .blocked
        )
        let developerID = catalogEntry(
            fingerprint: "developer",
            signatureKind: .developerID,
            compatibility: .compatible
        )
        XCTAssertEqual(
            PluginApprovalAuthority.approvedAdHocFingerprints(
                allowAdHocSignedPlugins: true,
                entries: [approved, blocked, developerID]
            ),
            ["approved"]
        )
        XCTAssertEqual(
            PluginApprovalAuthority.approvedAdHocFingerprints(
                allowAdHocSignedPlugins: false,
                entries: [approved]
            ),
            []
        )

        XCTAssertEqual(
            PluginApprovalAuthority.explicitlyApprovedEntry(
                fingerprint: approved.fingerprint,
                in: [blocked, developerID, approved]
            ),
            approved
        )
        XCTAssertNil(
            PluginApprovalAuthority.explicitlyApprovedEntry(
                fingerprint: blocked.fingerprint,
                in: [blocked]
            )
        )
        XCTAssertNil(
            PluginApprovalAuthority.explicitlyApprovedEntry(
                fingerprint: developerID.fingerprint,
                in: [developerID]
            )
        )
        XCTAssertNil(
            PluginApprovalAuthority.explicitlyApprovedEntry(
                fingerprint: "replaced-fingerprint",
                in: [approved]
            )
        )
    }

    func testPluginActionsKeepAdHocApprovalExplicitAndFailClosed() {
        let blocked = catalogEntry(
            fingerprint: "blocked",
            signatureKind: .adHoc,
            compatibility: .blocked
        )
        let approved = catalogEntry(
            fingerprint: "approved",
            signatureKind: .adHoc,
            compatibility: .compatible
        )
        let developerID = catalogEntry(
            fingerprint: "developer",
            signatureKind: .developerID,
            compatibility: .compatible
        )
        let apple = catalogEntry(
            fingerprint: "apple",
            signatureKind: .apple,
            compatibility: .compatible
        )

        XCTAssertEqual(
            PluginCatalogActionPolicy.primaryAction(
                for: blocked,
                allowAdHocSignedPlugins: false,
                approvedAdHocFingerprints: []
            ),
            .reviewSettings
        )
        XCTAssertEqual(
            PluginCatalogActionPolicy.primaryAction(
                for: blocked,
                allowAdHocSignedPlugins: true,
                approvedAdHocFingerprints: []
            ),
            .approve
        )
        XCTAssertEqual(
            PluginCatalogActionPolicy.primaryAction(
                for: approved,
                allowAdHocSignedPlugins: true,
                approvedAdHocFingerprints: [approved.fingerprint]
            ),
            .add
        )
        XCTAssertEqual(
            PluginCatalogActionPolicy.primaryAction(
                for: approved,
                allowAdHocSignedPlugins: true,
                approvedAdHocFingerprints: []
            ),
            .approve
        )
        XCTAssertEqual(
            PluginCatalogActionPolicy.primaryAction(
                for: approved,
                allowAdHocSignedPlugins: false,
                approvedAdHocFingerprints: [approved.fingerprint]
            ),
            .reviewSettings
        )
        XCTAssertEqual(
            PluginCatalogActionPolicy.primaryAction(
                for: developerID,
                allowAdHocSignedPlugins: false,
                approvedAdHocFingerprints: []
            ),
            .add
        )
        XCTAssertEqual(
            PluginCatalogActionPolicy.primaryAction(
                for: apple,
                allowAdHocSignedPlugins: false,
                approvedAdHocFingerprints: []
            ),
            .add
        )
    }

    func testFreshRuntimeCompatibilityMustRemainCompatible() throws {
        let fingerprint = "fresh"
        let blocked = catalogEntry(
            fingerprint: fingerprint,
            signatureKind: .adHoc,
            compatibility: .blocked
        )
        XCTAssertThrowsError(
            try PluginCatalogService.validatedRuntimeEntry(
                fingerprint: fingerprint,
                in: [blocked]
            )
        ) { error in
            guard case PluginCatalogServiceError.runtimeDescriptorUnavailable = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }

        let compatible = catalogEntry(
            fingerprint: fingerprint,
            signatureKind: .developerID,
            compatibility: .compatible
        )
        XCTAssertEqual(
            try PluginCatalogService.validatedRuntimeEntry(
                fingerprint: fingerprint,
                in: [compatible]
            ),
            compatible
        )
    }

    func testReducedRecoveryRetainsAvailableSlotsAfterAMiddleFailure() {
        let slotIDs = [UUID(), UUID(), UUID()]
        let slots = slotIDs.enumerated().map { index, slotID in
            SessionSlotDocument(
                slotID: slotID,
                order: index,
                pluginFingerprint: "fingerprint-\(index)",
                bundlePath: "/Library/Audio/Plug-Ins/VST3/Plugin\(index).vst3",
                classUID: "class-\(index)",
                name: "Plugin \(index)",
                manufacturer: "Tests",
                version: "1.0",
                bypassed: false,
                stateFile: SessionSlotDocument.stateFile(for: slotID)
            )
        }
        let persisted = PersistedSession(
            document: SessionDocument(
                schemaVersion: 1,
                id: "default",
                name: "Default",
                updatedAt: "2026-08-07T00:00:00Z",
                slots: slots
            ),
            pluginStates: Dictionary(
                uniqueKeysWithValues: slotIDs.enumerated().map {
                    ($0.element, Data([UInt8($0.offset)]))
                }
            )
        )

        let reduced = SessionRecoveryPlanner.reducedSession(
            from: persisted,
            retaining: [slotIDs[0], slotIDs[2]],
            updatedAt: "2026-08-07T01:00:00Z"
        )

        XCTAssertEqual(reduced.document.slots.map(\.slotID), [slotIDs[0], slotIDs[2]])
        XCTAssertEqual(reduced.document.slots.map(\.order), [0, 1])
        XCTAssertEqual(Set(reduced.pluginStates.keys), [slotIDs[0], slotIDs[2]])
    }

    private func pluginSlot(isBypassed: Bool) -> PluginSlotPresentation {
        PluginSlotPresentation(
            id: UUID(),
            fingerprint: "fixture",
            name: "Fixture",
            manufacturer: "Tests",
            version: "1.0",
            isBypassed: isBypassed,
            isFaulted: false,
            latencySamples: 0,
            hasEditor: true
        )
    }

    func testConfiguredStatusCompletesAnAsynchronousStop() {
        XCTAssertEqual(
            EngineStatusEventMapper.event(for: .configured, while: .stopping),
            .engineStopped
        )
        XCTAssertEqual(
            EngineStatusEventMapper.event(for: .configured, while: .checkingEnvironment),
            .engineConfigured
        )
    }

    private var representativeStates: [ApplicationState] {
        [
            .booting,
            .safeMode(.previousRunUnclean),
            .checkingEnvironment,
            .needsBlackHole,
            .needsMicrophonePermission,
            .needsAudioConfiguration,
            .readyStopped,
            .starting,
            .running,
            .muted,
            .stopping,
            .recovering,
            .blocked(.inputDeviceMissing),
            .fatal(.bridge("test")),
        ]
    }

    private func catalogEntry(
        fingerprint: String,
        signatureKind: PluginCatalogSignatureKind,
        compatibility: PluginCatalogCompatibility
    ) -> PluginCatalogEntry {
        PluginCatalogEntry(
            fingerprint: fingerprint,
            bundlePath: "/Library/Audio/Plug-Ins/VST3/Test.vst3",
            classUID: String(repeating: "a", count: 32),
            name: "Test",
            manufacturer: "Tests",
            version: "1.0",
            codeDirectoryHash: String(repeating: "b", count: 40),
            teamIdentifier: signatureKind == .adHoc ? "" : "TEAMID",
            signatureKind: signatureKind,
            architectures: ["arm64"],
            inputChannels: 2,
            outputChannels: 2,
            latencySamples: 0,
            hasEditor: false,
            compatibility: compatibility,
            reason: compatibility == .compatible
                ? nil : PluginCatalogEntry.adHocApprovalRequiredReason,
            bundleModificationTime: 1,
            scannerProtocol: 1,
            compatibleAppVersion: "0.1",
            lastScannedAt: "2026-08-07T00:00:00Z"
        )
    }
}
