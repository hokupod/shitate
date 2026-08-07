// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "Plugins/PluginScanTypes.h"

#include <string>

namespace shitate::scanner {

class ScanRequestLoader final {
  public:
    [[nodiscard]] static bool load(const std::string& requestPath, plugins::ScanRequest& request,
                                   std::string& errorCode);
    [[nodiscard]] static std::string resultPathForRequest(const std::string& requestPath);
};

} // namespace shitate::scanner
