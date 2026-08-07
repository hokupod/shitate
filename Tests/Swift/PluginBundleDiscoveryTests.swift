// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Foundation
import XCTest

final class PluginBundleDiscoveryTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "shitate-discovery-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testDiscoveryCanonicalizesDeduplicatesAndSkipsNonBundles() throws {
        let gain = temporaryDirectory.appendingPathComponent("Gain.vst3", isDirectory: true)
        let nested = temporaryDirectory.appendingPathComponent("Vendor", isDirectory: true)
        let latency = nested.appendingPathComponent("Latency.VST3", isDirectory: true)
        let hidden = temporaryDirectory.appendingPathComponent(".Hidden.vst3", isDirectory: true)
        try FileManager.default.createDirectory(at: gain, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: gain.appendingPathComponent("Contents/Nested.vst3"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: latency, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
        try Data("not a bundle".utf8).write(
            to: temporaryDirectory.appendingPathComponent("File.vst3")
        )
        try FileManager.default.createSymbolicLink(
            at: temporaryDirectory.appendingPathComponent("Gain Alias.vst3"),
            withDestinationURL: gain
        )

        let result = try PluginBundleDiscovery().candidates(
            in: [temporaryDirectory.path, temporaryDirectory.appendingPathComponent(".").path]
        )

        XCTAssertEqual(
            result,
            [gain.resolvingSymlinksInPath().path, latency.resolvingSymlinksInPath().path]
                .sorted()
        )
    }

    func testDiscoveryIgnoresMissingAbsoluteRootAndRejectsRelativeRoot() throws {
        let missing = temporaryDirectory.appendingPathComponent("Missing")
        XCTAssertEqual(try PluginBundleDiscovery().candidates(in: [missing.path]), [])
        XCTAssertThrowsError(try PluginBundleDiscovery().candidates(in: ["relative/VST3"])) {
            error in
            XCTAssertEqual(
                error as? PluginBundleDiscoveryError,
                .invalidRoot("relative/VST3")
            )
        }
    }

    func testDiscoveryBoundsConfiguredRoots() {
        let roots = (0...PluginBundleDiscovery.maximumRoots).map { "/missing/\($0)" }
        XCTAssertThrowsError(try PluginBundleDiscovery().candidates(in: roots)) { error in
            XCTAssertEqual(error as? PluginBundleDiscoveryError, .tooManyRoots)
        }
    }
}
