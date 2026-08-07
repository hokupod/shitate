// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "PluginRuntimeTypes.h"

#include <algorithm>
#include <array>
#include <cstdio>

namespace shitate::plugins {
namespace {

[[nodiscard]] int hexValue(char value) noexcept {
    if (value >= '0' && value <= '9') {
        return value - '0';
    }
    if (value >= 'a' && value <= 'f') {
        return value - 'a' + 10;
    }
    if (value >= 'A' && value <= 'F') {
        return value - 'A' + 10;
    }
    return -1;
}

} // namespace

SlotId::SlotId(std::array<std::uint8_t, byteCount> bytes) noexcept : bytes_(bytes) {}

std::optional<SlotId> SlotId::fromString(std::string_view value) noexcept {
    if (value.size() != 36 || value[8] != '-' || value[13] != '-' || value[18] != '-' ||
        value[23] != '-') {
        return std::nullopt;
    }

    std::array<std::uint8_t, byteCount> bytes{};
    std::size_t byteIndex = 0;
    for (std::size_t index = 0; index < value.size();) {
        if (value[index] == '-') {
            ++index;
            continue;
        }
        if (index + 1 >= value.size() || byteIndex >= bytes.size()) {
            return std::nullopt;
        }
        const auto high = hexValue(value[index]);
        const auto low = hexValue(value[index + 1]);
        if (high < 0 || low < 0) {
            return std::nullopt;
        }
        bytes[byteIndex++] = static_cast<std::uint8_t>((high << 4) | low);
        index += 2;
    }
    if (byteIndex != bytes.size() ||
        std::all_of(bytes.begin(), bytes.end(), [](auto byte) { return byte == 0; })) {
        return std::nullopt;
    }
    return SlotId(bytes);
}

std::string SlotId::toString() const {
    std::array<char, 37> result{};
    static constexpr char hex[] = "0123456789abcdef";
    std::size_t output = 0;
    for (std::size_t index = 0; index < bytes_.size(); ++index) {
        if (index == 4 || index == 6 || index == 8 || index == 10) {
            result[output++] = '-';
        }
        result[output++] = hex[bytes_[index] >> 4U];
        result[output++] = hex[bytes_[index] & 0x0fU];
    }
    return result.data();
}

const std::array<std::uint8_t, SlotId::byteCount>& SlotId::bytes() const noexcept {
    return bytes_;
}

bool SlotId::isValid() const noexcept {
    return std::any_of(bytes_.begin(), bytes_.end(), [](auto byte) { return byte != 0; });
}

} // namespace shitate::plugins
