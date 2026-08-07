// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

namespace shitate::plugins {

class SlotId final {
  public:
    static constexpr std::size_t byteCount = 16;

    SlotId() = default;
    explicit SlotId(std::array<std::uint8_t, byteCount> bytes) noexcept;

    [[nodiscard]] static std::optional<SlotId> fromString(std::string_view value) noexcept;
    [[nodiscard]] std::string toString() const;
    [[nodiscard]] const std::array<std::uint8_t, byteCount>& bytes() const noexcept;
    [[nodiscard]] bool isValid() const noexcept;

    [[nodiscard]] friend bool operator==(const SlotId&, const SlotId&) noexcept = default;

  private:
    std::array<std::uint8_t, byteCount> bytes_{};
};

enum class PluginRuntimeError : int {
    none = 0,
    invalidDescriptor = 300,
    identityChanged = 301,
    journalWriteFailed = 302,
    instanceCreationFailed = 303,
    unsupportedLayout = 304,
    stateInvalid = 305,
    prepareFailed = 306,
    chainFull = 307,
    duplicateSlot = 308,
    slotNotFound = 309,
    engineRunning = 310,
    invalidMove = 311,
    sessionIncomplete = 312,
    editorUnavailable = 313,
    editorThreadInvalid = 314,
};

struct PluginRuntimeResult final {
    PluginRuntimeError error{PluginRuntimeError::none};
    std::string message;

    [[nodiscard]] bool succeeded() const noexcept {
        return error == PluginRuntimeError::none;
    }

    [[nodiscard]] static PluginRuntimeResult success() {
        return {};
    }

    [[nodiscard]] static PluginRuntimeResult failure(PluginRuntimeError error,
                                                     std::string message) {
        return {error, std::move(message)};
    }
};

} // namespace shitate::plugins
