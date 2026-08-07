// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "Plugins/PluginRuntimeTypes.h"
#include "Plugins/PluginScanTypes.h"

#include <cstdint>
#include <vector>

namespace shitate {

struct SerializedPluginState final {
    plugins::PluginRuntimeResult result;
    std::vector<std::uint8_t> data;
};

struct PluginSlotSnapshot final {
    plugins::SlotId slotID;
    plugins::CatalogEntry identity;
    bool bypassed{false};
    bool faulted{false};
    int latencySamples{0};
    int eventKey{0};
};

} // namespace shitate
