// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Plugins/PluginCatalog.h"

#include <juce_core/juce_core.h>
#include <set>

namespace {

using namespace shitate::plugins;

[[nodiscard]] ScanResult catalogResult(SignatureKind kind = SignatureKind::developerID) {
    ScanResult result;
    result.requestID = "01234567-89ab-cdef-0123-456789abcdef";
    result.status = "compatible";
    result.bundle.path = "/Library/Audio/Plug-Ins/VST3/Gain.vst3";
    result.bundle.codeDirectoryHash = "0123456789abcdef0123456789abcdef01234567";
    result.bundle.teamIdentifier = kind == SignatureKind::adHoc ? "" : "TEAMID";
    result.bundle.signatureKind = kind;
    result.bundle.architectures = {"arm64"};
    result.bundle.modificationTime = 100;
    ScannedPlugin plugin;
    plugin.classUID = "1234abcd1234abcd1234abcd1234abcd";
    plugin.name = "Gain";
    plugin.inputChannels = 2;
    plugin.outputChannels = 2;
    plugin.compatible = true;
    result.plugins.push_back(plugin);
    return result;
}

class PluginCatalogTest final : public juce::UnitTest {
  public:
    PluginCatalogTest() : UnitTest("PluginCatalog", "Shitate") {}

    void runTest() override {
        beginTest("catalog creates deterministic unique fingerprints");
        PluginCatalog catalog;
        const auto result = catalogResult();
        expect(catalog.replaceBundle(result, {}, "2026-08-07T00:00:00Z"));
        expectEquals(static_cast<int>(catalog.entries().size()), 1);
        expectEquals(static_cast<int>(catalog.entries().front().fingerprint.size()), 64);
        expect(catalog.entries().front().compatibility == PluginCompatibility::compatible);

        beginTest("fingerprint fields use unambiguous domain-separated framing");
        expect(pluginFingerprint("/ab", "c", "d", "e") != pluginFingerprint("/a", "bc", "d", "e"));

        beginTest("every cache identity field invalidates independently");
        expect(catalog.hasValidCache(result.bundle.path, result.bundle.codeDirectoryHash, 100,
                                     scannerProtocolVersion, "0.1"));
        expect(!catalog.hasValidCache(result.bundle.path,
                                      "ffffffffffffffffffffffffffffffffffffffff", 100,
                                      scannerProtocolVersion, "0.1"));
        expect(!catalog.hasValidCache(result.bundle.path, result.bundle.codeDirectoryHash, 101,
                                      scannerProtocolVersion, "0.1"));
        expect(!catalog.hasValidCache(result.bundle.path, result.bundle.codeDirectoryHash, 100, 2,
                                      "0.1"));
        expect(!catalog.hasValidCache(result.bundle.path, result.bundle.codeDirectoryHash, 100,
                                      scannerProtocolVersion, "0.2"));
        expect(!catalog.hasValidCache("/different.vst3", result.bundle.codeDirectoryHash, 100,
                                      scannerProtocolVersion, "0.1"));

        beginTest("ad-hoc approval is scoped to the exact fingerprint");
        PluginCatalog adHocCatalog;
        const auto adHoc = catalogResult(SignatureKind::adHoc);
        expect(adHocCatalog.replaceBundle(adHoc, {}, "2026-08-07T00:00:00Z"));
        expect(adHocCatalog.entries().front().compatibility == PluginCompatibility::blocked);
        expectEquals(*adHocCatalog.entries().front().reason, std::string("adHocApprovalRequired"));
        const auto fingerprint = adHocCatalog.entries().front().fingerprint;
        expect(adHocCatalog.replaceBundle(adHoc, {fingerprint}, "2026-08-07T00:00:01Z"));
        expect(adHocCatalog.entries().front().compatibility == PluginCompatibility::compatible);

        beginTest("duplicate fingerprints fail without mutating the catalog");
        auto duplicate = result;
        duplicate.plugins.push_back(duplicate.plugins.front());
        const auto previousFingerprint = catalog.entries().front().fingerprint;
        expect(!catalog.replaceBundle(duplicate, {}, "2026-08-07T00:00:02Z"));
        expectEquals(static_cast<int>(catalog.entries().size()), 1);
        expectEquals(catalog.entries().front().fingerprint, previousFingerprint);

        beginTest("stale path removal keeps only discovered bundles");
        catalog.removeStalePaths({"/another.vst3"});
        expect(catalog.entries().empty());
    }
};

PluginCatalogTest pluginCatalogTest;

} // namespace
