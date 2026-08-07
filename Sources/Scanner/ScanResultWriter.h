// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "Plugins/PluginScanTypes.h"

#include <string>

namespace shitate::scanner {

class ScanResultWriter final {
  public:
    [[nodiscard]] static bool write(const std::string& resultPath,
                                    const plugins::ScanResult& result) noexcept;
};

} // namespace shitate::scanner
