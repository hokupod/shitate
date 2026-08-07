// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Foundation
import Observation

enum PluginCatalogServiceError: Error {
    case invalidBridgeDescriptor
    case entryUnavailable
    case runtimeDescriptorUnavailable
}

enum PluginBundleDiscoveryError: Error, Equatable {
    case tooManyRoots
    case invalidRoot(String)
    case enumerationFailed(String)
    case tooManyEntries
    case tooManyCandidates
}

struct PluginBundleDiscovery {
    static let maximumRoots = 64
    static let maximumVisitedEntries = 100_000
    static let maximumCandidates = 4_096

    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func candidates(in rootPaths: [String]) throws -> [String] {
        guard rootPaths.count <= Self.maximumRoots else {
            throw PluginBundleDiscoveryError.tooManyRoots
        }

        var roots = Set<String>()
        for path in rootPaths {
            guard path.hasPrefix("/") else {
                throw PluginBundleDiscoveryError.invalidRoot(path)
            }
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory)
            else {
                continue
            }
            guard isDirectory.boolValue else {
                throw PluginBundleDiscoveryError.invalidRoot(path)
            }
            roots.insert(standardized.resolvingSymlinksInPath().path)
        }

        var candidates = Set<String>()
        var visitedEntries = 0
        for root in roots.sorted() {
            var enumerationError: Error?
            guard
                let enumerator = fileManager.enumerator(
                    at: URL(fileURLWithPath: root, isDirectory: true),
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, error in
                        enumerationError = error
                        return false
                    }
                )
            else {
                throw PluginBundleDiscoveryError.enumerationFailed(root)
            }

            while let url = enumerator.nextObject() as? URL {
                visitedEntries += 1
                guard visitedEntries <= Self.maximumVisitedEntries else {
                    throw PluginBundleDiscoveryError.tooManyEntries
                }
                guard
                    url.pathExtension.compare("vst3", options: .caseInsensitive)
                        == .orderedSame
                else {
                    continue
                }
                guard
                    let resourceValues = try? url.resourceValues(
                        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                    )
                else {
                    throw PluginBundleDiscoveryError.enumerationFailed(root)
                }
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                var isDirectory = ObjCBool(false)
                guard
                    fileManager.fileExists(
                        atPath: canonical.path,
                        isDirectory: &isDirectory
                    ),
                    isDirectory.boolValue
                else {
                    continue
                }
                if resourceValues.isDirectory == true,
                    resourceValues.isSymbolicLink != true
                {
                    enumerator.skipDescendants()
                }
                candidates.insert(canonical.path)
                guard candidates.count <= Self.maximumCandidates else {
                    throw PluginBundleDiscoveryError.tooManyCandidates
                }
            }
            if enumerationError != nil {
                throw PluginBundleDiscoveryError.enumerationFailed(root)
            }
        }
        return candidates.sorted()
    }
}

struct PluginCatalogRefreshResult: Equatable, Sendable {
    let discoveredBundlePaths: [String]
    let scannedBundlePaths: [String]
    let failedBundlePaths: [String]
}

@Observable
final class PluginCatalogService {
    private let bridge: STPluginBridge
    private let store: PluginCatalogStore
    private let discovery: PluginBundleDiscovery

    private(set) var document = PluginCatalogDocument()

    var scanProgress: STPluginScanProgress {
        bridge.scanProgress
    }

    init(
        bridge: STPluginBridge = STPluginBridge(),
        store: PluginCatalogStore = PluginCatalogStore(
            fileURL: FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent("dev.hokupod.shitate", isDirectory: true)
            .appendingPathComponent("plugin-catalog.json")
        ),
        discovery: PluginBundleDiscovery = PluginBundleDiscovery()
    ) {
        self.bridge = bridge
        self.store = store
        self.discovery = discovery
    }

    func load() throws {
        let persisted = try store.load()
        let revalidatedEntries = persisted.entries.filter {
            $0.compatibleAppVersion == PluginCatalogDocument.currentCompatibleAppVersion
                && liveIdentityMatches($0)
        }
        let revalidated = PluginCatalogDocument(entries: revalidatedEntries)
        if revalidated != persisted {
            try store.save(revalidated)
        }
        document = revalidated
    }

    @discardableResult
    func refreshDiscoveredBundles(
        inAdditionalFolders additionalFolders: [String] = [],
        approvedAdHocFingerprints: Set<String> = []
    ) throws -> PluginCatalogRefreshResult {
        let additionalRoots = try bridge.validatedAdditionalFolders(additionalFolders)
        let bundlePaths = try discovery.candidates(
            in: bridge.standardSearchPaths + additionalRoots
        )
        try removeEntriesNotAtPaths(Set(bundlePaths))

        var scannedPaths: [String] = []
        var failedPaths: [String] = []
        for bundlePath in bundlePaths {
            let cachedEntries = document.entries.filter { $0.bundlePath == bundlePath }
            if !cachedEntries.isEmpty, cachedEntries.allSatisfy(liveIdentityMatches) {
                continue
            }
            do {
                try rescanBundle(
                    at: bundlePath,
                    approvedAdHocFingerprints: approvedAdHocFingerprints
                )
                scannedPaths.append(bundlePath)
            } catch {
                failedPaths.append(bundlePath)
            }
        }
        return PluginCatalogRefreshResult(
            discoveredBundlePaths: bundlePaths,
            scannedBundlePaths: scannedPaths,
            failedBundlePaths: failedPaths
        )
    }

    @discardableResult
    func rescanBundle(
        at bundlePath: String,
        approvedAdHocFingerprints: Set<String> = []
    ) throws -> [PluginCatalogEntry] {
        let requestedPath = URL(fileURLWithPath: bundlePath).standardizedFileURL.path
        let inspection = try? bridge.inspectBundle(atPath: bundlePath)
        var matchingPaths = Set([requestedPath])
        if let inspection {
            matchingPaths.insert(inspection.canonicalPath)
        }
        let matchingEntries = document.entries.filter {
            matchingPaths.contains($0.bundlePath)
        }
        let cacheStillValid: Bool
        if let inspection, !matchingEntries.isEmpty {
            cacheStillValid = matchingEntries.allSatisfy {
                liveIdentityMatches($0, inspection: inspection)
            }
        } else {
            cacheStillValid = false
        }
        if !matchingEntries.isEmpty, !cacheStillValid {
            let invalidated = PluginCatalogDocument(
                entries: document.entries.filter {
                    !matchingPaths.contains($0.bundlePath)
                }
            )
            try store.save(invalidated)
            document = invalidated
            bridge.removeCatalogEntriesNot(
                atPaths: Set(document.entries.map(\.bundlePath))
            )
        }

        let descriptors = try bridge.rescanBundle(
            atPath: bundlePath,
            approvedAdHocFingerprints: approvedAdHocFingerprints
        )
        let replacements = try descriptors.map(entry)
        guard let canonicalPath = replacements.first?.bundlePath,
            replacements.allSatisfy({ $0.bundlePath == canonicalPath })
        else {
            throw PluginCatalogServiceError.invalidBridgeDescriptor
        }

        let entries = document.entries.filter { $0.bundlePath != canonicalPath } + replacements
        let candidate = PluginCatalogDocument(
            entries: entries.sorted {
                ($0.name, $0.fingerprint) < ($1.name, $1.fingerprint)
            }
        )
        try store.save(candidate)
        document = candidate
        return replacements
    }

    func removeEntriesNotAtPaths(_ canonicalPaths: Set<String>) throws {
        let candidate = PluginCatalogDocument(
            entries: document.entries.filter { canonicalPaths.contains($0.bundlePath) }
        )
        try store.save(candidate)
        document = candidate
        bridge.removeCatalogEntriesNot(atPaths: canonicalPaths)
    }

    func validatedAdditionalFolders(_ folders: [String]) throws -> [String] {
        try bridge.validatedAdditionalFolders(folders)
    }

    func runtimeDescriptor(
        fingerprint: String,
        approvedAdHocFingerprints: Set<String>
    ) throws -> STPluginDescriptor {
        guard
            let persisted = document.entries.first(where: { $0.fingerprint == fingerprint }),
            persisted.compatibility == .compatible
        else {
            throw PluginCatalogServiceError.entryUnavailable
        }
        let approved: Set<String>
        if persisted.signatureKind == .adHoc,
            approvedAdHocFingerprints.contains(fingerprint)
        {
            approved = [fingerprint]
        } else {
            approved = []
        }
        let descriptors = try bridge.rescanBundle(
            atPath: persisted.bundlePath,
            approvedAdHocFingerprints: approved
        )
        let replacements = try descriptors.map(entry)
        guard replacements.allSatisfy({ $0.bundlePath == persisted.bundlePath }) else {
            throw PluginCatalogServiceError.invalidBridgeDescriptor
        }

        let candidate = PluginCatalogDocument(
            entries: (document.entries.filter { $0.bundlePath != persisted.bundlePath }
                + replacements).sorted {
                    ($0.name, $0.fingerprint) < ($1.name, $1.fingerprint)
                }
        )
        try store.save(candidate)
        document = candidate
        _ = try Self.validatedRuntimeEntry(
            fingerprint: fingerprint,
            in: replacements
        )
        guard let runtime = descriptors.first(where: { $0.fingerprint == fingerprint }) else {
            throw PluginCatalogServiceError.runtimeDescriptorUnavailable
        }
        return runtime
    }

    static func validatedRuntimeEntry(
        fingerprint: String,
        in replacements: [PluginCatalogEntry]
    ) throws -> PluginCatalogEntry {
        guard
            let entry = replacements.first(where: { $0.fingerprint == fingerprint }),
            entry.compatibility == .compatible
        else {
            throw PluginCatalogServiceError.runtimeDescriptorUnavailable
        }
        return entry
    }

    private func liveIdentityMatches(_ entry: PluginCatalogEntry) -> Bool {
        guard let inspection = try? bridge.inspectBundle(atPath: entry.bundlePath) else {
            return false
        }
        return liveIdentityMatches(entry, inspection: inspection)
    }

    private func liveIdentityMatches(
        _ entry: PluginCatalogEntry,
        inspection: STPluginInspection
    ) -> Bool {
        guard entry.scannerProtocol == PluginCatalogDocument.currentScannerProtocolVersion,
            entry.compatibleAppVersion == PluginCatalogDocument.currentCompatibleAppVersion,
            inspection.canonicalPath == entry.bundlePath,
            inspection.codeDirectoryHash == entry.codeDirectoryHash,
            inspection.teamIdentifier == entry.teamIdentifier,
            inspection.architectures.sorted() == entry.architectures.sorted(),
            inspection.bundleModificationTime == entry.bundleModificationTime,
            catalogSignatureKind(inspection.signatureKind) == entry.signatureKind
        else {
            return false
        }
        return true
    }

    private func entry(_ descriptor: STPluginDescriptor) throws -> PluginCatalogEntry {
        guard let signatureKind = catalogSignatureKind(descriptor.signatureKind),
            let compatibility = catalogCompatibility(descriptor.compatibility)
        else {
            throw PluginCatalogServiceError.invalidBridgeDescriptor
        }
        return PluginCatalogEntry(
            fingerprint: descriptor.fingerprint,
            bundlePath: descriptor.bundlePath,
            classUID: descriptor.classUID,
            name: descriptor.name,
            manufacturer: descriptor.manufacturer,
            version: descriptor.version,
            codeDirectoryHash: descriptor.codeDirectoryHash,
            teamIdentifier: descriptor.teamIdentifier,
            signatureKind: signatureKind,
            architectures: descriptor.architectures,
            inputChannels: descriptor.inputChannels,
            outputChannels: descriptor.outputChannels,
            latencySamples: descriptor.latencySamples,
            hasEditor: descriptor.hasEditor,
            compatibility: compatibility,
            reason: descriptor.reason,
            bundleModificationTime: descriptor.bundleModificationTime,
            scannerProtocol: descriptor.scannerProtocol,
            compatibleAppVersion: descriptor.compatibleAppVersion,
            lastScannedAt: descriptor.lastScannedAt
        )
    }

    private func catalogSignatureKind(
        _ value: STPluginSignatureKind
    ) -> PluginCatalogSignatureKind? {
        switch value {
        case .apple:
            .apple
        case .developerID:
            .developerID
        case .adHoc:
            .adHoc
        case .unsigned, .invalid:
            nil
        @unknown default:
            nil
        }
    }

    private func catalogCompatibility(
        _ value: STPluginCompatibility
    ) -> PluginCatalogCompatibility? {
        switch value {
        case .compatible:
            .compatible
        case .incompatible:
            .incompatible
        case .blocked:
            .blocked
        @unknown default:
            nil
        }
    }
}
