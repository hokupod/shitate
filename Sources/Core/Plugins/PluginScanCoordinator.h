// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "PluginScanTypes.h"
#include "PluginSignatureVerifier.h"

#include <chrono>
#include <cstddef>
#include <memory>
#include <string>
#include <vector>

namespace shitate::plugins {

struct ScanCoordinatorConfiguration final {
    std::string taskRoot{"/private/tmp"};
    std::chrono::milliseconds timeout{std::chrono::seconds(20)};
    std::chrono::milliseconds terminationGrace{std::chrono::milliseconds(250)};
    std::size_t maximumLogBytes{64U * 1024U};
    std::vector<std::string> inheritedEnvironmentKeys;
};

class PluginScanCoordinator final {
  public:
    explicit PluginScanCoordinator(std::shared_ptr<const SignatureInspector> signatureInspector =
                                       std::make_shared<PluginSignatureVerifier>(),
                                   ScanCoordinatorConfiguration configuration = {});

    [[nodiscard]] ScanOutcome scan(const std::string& scannerExecutable,
                                   const std::string& pluginBundlePath) const;
    [[nodiscard]] std::size_t cleanupStaleTasks(
        std::chrono::system_clock::time_point now = std::chrono::system_clock::now()) const;

  private:
    [[nodiscard]] bool removeOwnedTask(const std::string& taskPath) const;

    std::shared_ptr<const SignatureInspector> signatureInspector_;
    ScanCoordinatorConfiguration configuration_;
};

} // namespace shitate::plugins
