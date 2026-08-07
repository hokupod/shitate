// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "AudioTypes.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>

namespace shitate {

class RealtimeEventQueue final {
  public:
    static constexpr std::size_t capacity = 64;
    static constexpr std::size_t eventTypeCount = 6;

    RealtimeEventQueue() noexcept;

    [[nodiscard]] bool push(CoreEvent event) noexcept;
    [[nodiscard]] bool pop(CoreEvent& event) noexcept;

  private:
    struct Cell {
        std::atomic<std::size_t> sequence{0};
        CoreEvent event;
    };

    [[nodiscard]] bool pushRing(CoreEvent event) noexcept;
    [[nodiscard]] bool popRing(CoreEvent& event) noexcept;
    [[nodiscard]] bool popCoalesced(CoreEvent& event) noexcept;

    static constexpr std::size_t mask = capacity - 1;
    static_assert((capacity & mask) == 0, "capacity must be a power of two");

    std::array<Cell, capacity> cells_{};
    alignas(64) std::atomic<std::size_t> enqueuePosition_{0};
    alignas(64) std::atomic<std::size_t> dequeuePosition_{0};
    std::atomic<std::uint32_t> coalescedTypes_{0};
    std::atomic<int> coalescedValues_[eventTypeCount]{};
    std::atomic<int> coalescedErrors_[eventTypeCount]{};
};

static_assert(std::atomic<std::size_t>::is_always_lock_free);
static_assert(std::atomic<std::uint32_t>::is_always_lock_free);

} // namespace shitate
