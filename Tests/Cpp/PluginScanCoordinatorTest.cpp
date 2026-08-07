// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Plugins/PluginScanCoordinator.h"

#include <filesystem>
#include <juce_core/juce_core.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {

using namespace shitate::plugins;

class RejectingInspector final : public SignatureInspector {
  public:
    [[nodiscard]] SignatureInfo inspect(const std::string&) const noexcept override {
        SignatureInfo info;
        info.kind = SignatureKind::unsignedCode;
        info.errorCode = "unsignedCode";
        return info;
    }
};

class PluginScanCoordinatorTest final : public juce::UnitTest {
  public:
    PluginScanCoordinatorTest() : UnitTest("PluginScanCoordinator", "Shitate") {}

    void runTest() override {
        beginTest("invalid signature fails before spawn");
        PluginScanCoordinator rejecting(std::make_shared<RejectingInspector>());
        const auto rejected = rejecting.scan("/does/not/exist", "/untrusted.vst3");
        expect(rejected.kind == ScanOutcomeKind::invalidSignature);
        expectEquals(rejected.diagnosticCode, std::string("unsignedCode"));

        beginTest("stale cleanup removes only exact owned safe task directories");
        const auto root =
            std::filesystem::path(juce::File::getSpecialLocation(juce::File::tempDirectory)
                                      .getFullPathName()
                                      .toStdString()) /
            ("shitate-cleanup-test-" + std::to_string(::getpid()));
        std::filesystem::create_directory(root);
        ::chmod(root.c_str(), 0700);
        const auto uuid = std::string("01234567-89ab-cdef-0123-456789abcdef");
        const auto safe = root / ("shitate-scan-" + uuid);
        const auto nested = root / "shitate-scan-fedcba98-7654-3210-fedc-ba9876543210";
        const auto invalidName = root / "shitate-scan-not-a-uuid";
        const auto externalTarget = root / "external-target";
        std::filesystem::create_directory(safe);
        std::filesystem::create_directory(nested);
        std::filesystem::create_directory(invalidName);
        std::filesystem::create_directory(externalTarget);
        ::chmod(safe.c_str(), 0700);
        ::chmod(nested.c_str(), 0700);
        ::chmod(invalidName.c_str(), 0700);
        ::chmod(externalTarget.c_str(), 0700);
        std::filesystem::create_directory(nested / "unexpected");
        std::filesystem::create_symlink(externalTarget, nested / "unexpected" / "link");

        ScanCoordinatorConfiguration configuration;
        configuration.taskRoot = root.string();
        PluginScanCoordinator coordinator(std::make_shared<RejectingInspector>(), configuration);
        const auto future = std::chrono::system_clock::now() + std::chrono::hours(25);
        expectEquals(static_cast<int>(coordinator.cleanupStaleTasks(future)), 2);
        expect(!std::filesystem::exists(safe));
        expect(!std::filesystem::exists(nested));
        expect(std::filesystem::exists(externalTarget));
        expect(std::filesystem::exists(invalidName));

        std::filesystem::remove(invalidName);
        std::filesystem::remove(externalTarget);
        std::filesystem::remove(root);
    }
};

PluginScanCoordinatorTest pluginScanCoordinatorTest;

} // namespace
