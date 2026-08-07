// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "PluginCatalog.h"

#include "PluginScanProtocol.h"
#include "PluginSignatureVerifier.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <juce_cryptography/juce_cryptography.h>
#include <string_view>
#include <utility>
#include <vector>

namespace shitate::plugins {
namespace {

constexpr std::string_view fingerprintDomain = "shitate-plugin-fingerprint-v1";

void appendFingerprintField(std::vector<std::uint8_t>& identity, std::string_view value) {
    const auto length = static_cast<std::uint32_t>(value.size());
    const std::array<std::uint8_t, 4> prefix{
        static_cast<std::uint8_t>((length >> 24U) & 0xffU),
        static_cast<std::uint8_t>((length >> 16U) & 0xffU),
        static_cast<std::uint8_t>((length >> 8U) & 0xffU),
        static_cast<std::uint8_t>(length & 0xffU),
    };
    identity.insert(identity.end(), prefix.begin(), prefix.end());
    identity.insert(identity.end(), value.begin(), value.end());
}

} // namespace

std::string pluginFingerprint(const std::string& canonicalPath, const std::string& classUID,
                              const std::string& codeDirectoryHash,
                              const std::string& architecture) {
    std::vector<std::uint8_t> identity;
    identity.reserve(fingerprintDomain.size() + canonicalPath.size() + classUID.size() +
                     codeDirectoryHash.size() + architecture.size() + 20U);
    appendFingerprintField(identity, fingerprintDomain);
    appendFingerprintField(identity, canonicalPath);
    appendFingerprintField(identity, classUID);
    appendFingerprintField(identity, codeDirectoryHash);
    appendFingerprintField(identity, architecture);
    return juce::SHA256(identity.data(), identity.size()).toHexString().toStdString();
}

bool PluginCatalog::replaceBundle(const ScanResult& result,
                                  const std::set<std::string>& approvedAdHocFingerprints,
                                  const std::string& scannedAt) {
    if (result.protocolVersion != scannerProtocolVersion || result.bundle.path.empty() ||
        result.bundle.codeDirectoryHash.empty() || result.bundle.architectures.empty() ||
        scannedAt.empty()) {
        return false;
    }

    const auto selectedArchitecture =
        std::find(result.bundle.architectures.begin(), result.bundle.architectures.end(), "arm64");
    if (selectedArchitecture == result.bundle.architectures.end()) {
        return false;
    }

    std::vector<CatalogEntry> replacements;
    std::set<std::string> uniqueFingerprints;
    for (const auto& plugin : result.plugins) {
        CatalogEntry entry;
        entry.fingerprint =
            pluginFingerprint(result.bundle.path, plugin.classUID, result.bundle.codeDirectoryHash,
                              *selectedArchitecture);
        if (!uniqueFingerprints.insert(entry.fingerprint).second) {
            return false;
        }
        entry.bundlePath = result.bundle.path;
        entry.classUID = plugin.classUID;
        entry.name = plugin.name;
        entry.manufacturer = plugin.manufacturer;
        entry.version = plugin.version;
        entry.codeDirectoryHash = result.bundle.codeDirectoryHash;
        entry.teamIdentifier = result.bundle.teamIdentifier;
        entry.signatureKind = result.bundle.signatureKind;
        entry.architectures = result.bundle.architectures;
        entry.inputChannels = plugin.inputChannels;
        entry.outputChannels = plugin.outputChannels;
        entry.latencySamples = plugin.latencySamples;
        entry.hasEditor = plugin.hasEditor;
        entry.reason = plugin.reason;
        entry.bundleModificationTime = result.bundle.modificationTime;
        entry.scannerProtocol = result.protocolVersion;
        entry.lastScannedAt = scannedAt;

        if (!plugin.compatible) {
            entry.compatibility = PluginCompatibility::incompatible;
        } else if (result.bundle.signatureKind == SignatureKind::adHoc &&
                   !approvedAdHocFingerprints.contains(entry.fingerprint)) {
            entry.compatibility = PluginCompatibility::blocked;
            entry.reason = "adHocApprovalRequired";
        } else if (result.bundle.signatureKind == SignatureKind::apple ||
                   result.bundle.signatureKind == SignatureKind::developerID ||
                   (result.bundle.signatureKind == SignatureKind::adHoc &&
                    approvedAdHocFingerprints.contains(entry.fingerprint))) {
            entry.compatibility = PluginCompatibility::compatible;
            entry.reason.reset();
        } else {
            entry.compatibility = PluginCompatibility::blocked;
            entry.reason = "signatureRejected";
        }
        replacements.push_back(std::move(entry));
    }

    entries_.erase(
        std::remove_if(entries_.begin(), entries_.end(),
                       [&](const auto& entry) { return entry.bundlePath == result.bundle.path; }),
        entries_.end());
    entries_.insert(entries_.end(), replacements.begin(), replacements.end());
    std::sort(entries_.begin(), entries_.end(), [](const auto& left, const auto& right) {
        if (left.name != right.name) {
            return left.name < right.name;
        }
        return left.fingerprint < right.fingerprint;
    });
    return true;
}

bool PluginCatalog::hasValidCache(const std::string& canonicalPath,
                                  const std::string& codeDirectoryHash,
                                  std::int64_t modificationTime, int protocolVersion,
                                  const std::string& compatibleAppVersion) const {
    const auto first = std::find_if(entries_.begin(), entries_.end(), [&](const auto& entry) {
        return entry.bundlePath == canonicalPath;
    });
    if (first == entries_.end()) {
        return false;
    }

    return std::all_of(entries_.begin(), entries_.end(), [&](const auto& entry) {
        return entry.bundlePath != canonicalPath ||
               (entry.codeDirectoryHash == codeDirectoryHash &&
                entry.bundleModificationTime == modificationTime &&
                entry.scannerProtocol == protocolVersion &&
                entry.compatibleAppVersion == compatibleAppVersion);
    });
}

void PluginCatalog::removeStalePaths(const std::set<std::string>& currentCanonicalPaths) {
    entries_.erase(std::remove_if(entries_.begin(), entries_.end(),
                                  [&](const auto& entry) {
                                      return !currentCanonicalPaths.contains(entry.bundlePath);
                                  }),
                   entries_.end());
}

const std::vector<CatalogEntry>& PluginCatalog::entries() const noexcept {
    return entries_;
}

void PluginCatalog::clear() noexcept {
    entries_.clear();
}

} // namespace shitate::plugins
