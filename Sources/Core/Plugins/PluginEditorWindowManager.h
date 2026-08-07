// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "PluginRuntimeTypes.h"

#include <array>
#include <juce_gui_basics/juce_gui_basics.h>
#include <memory>
#include <optional>
#include <utility>

namespace shitate {
class HostedPluginSlot;
}

namespace shitate::plugins {

class PluginEditorWindowManager final {
  public:
    static constexpr int minimumWidth = 320;
    static constexpr int minimumHeight = 200;
    static constexpr int maximumWidth = 1600;
    static constexpr int maximumHeight = 1200;
    static constexpr std::size_t maximumWindows = 8;

    explicit PluginEditorWindowManager(bool showWindows = true) noexcept;
    ~PluginEditorWindowManager();

    [[nodiscard]] PluginRuntimeResult open(HostedPluginSlot& slot);
    [[nodiscard]] PluginRuntimeResult close(const SlotId& slotID);
    void closeAll() noexcept;
    [[nodiscard]] bool isOpen(const SlotId& slotID) const noexcept;
    [[nodiscard]] std::size_t size() const noexcept;
    [[nodiscard]] std::optional<std::pair<int, int>>
    windowSizeForTesting(const SlotId& slotID) const noexcept;
    [[nodiscard]] std::optional<bool>
    windowIsOnDesktopForTesting(const SlotId& slotID) const noexcept;

  private:
    struct WindowEntry final {
        SlotId slotID;
        std::unique_ptr<juce::DocumentWindow> window;
    };

    [[nodiscard]] bool isMessageThread() const noexcept;
    [[nodiscard]] std::size_t indexOf(const SlotId& slotID) const noexcept;

    std::array<WindowEntry, maximumWindows> windows_{};
    std::size_t size_{0};
    bool showWindows_{true};
};

} // namespace shitate::plugins
