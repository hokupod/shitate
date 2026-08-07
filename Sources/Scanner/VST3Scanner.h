// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "Plugins/PluginScanTypes.h"

#include <optional>
#include <string>

namespace shitate::scanner {

enum class VST3ScanStatus {
    success,
    bundleLoadFailure,
    factoryFailure,
    noSupportedClass,
    internalError,
};

struct VST3ScanOutcome final {
    VST3ScanStatus status{VST3ScanStatus::internalError};
    std::optional<plugins::ScanResult> result;
    std::string errorCode;
};

class VST3Scanner final {
  public:
    [[nodiscard]] VST3ScanOutcome scan(const plugins::ScanRequest& request,
                                       const plugins::SignatureInfo& signature) const noexcept;
};

} // namespace shitate::scanner
