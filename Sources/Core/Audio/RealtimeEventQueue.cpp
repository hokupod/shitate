// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "RealtimeEventQueue.h"

#include <bit>
#include <cstdint>

namespace shitate {

RealtimeEventQueue::RealtimeEventQueue() noexcept {
    for (std::size_t index = 0; index < capacity; ++index) {
        cells_[index].sequence.store(index, std::memory_order_relaxed);
    }
}

bool RealtimeEventQueue::push(CoreEvent event) noexcept {
    if (pushRing(event)) {
        return true;
    }

    const auto index = static_cast<std::size_t>(event.type);
    coalescedValues_[index].store(event.value, std::memory_order_relaxed);
    coalescedErrors_[index].store(static_cast<int>(event.error), std::memory_order_relaxed);
    coalescedTypes_.fetch_or(std::uint32_t{1} << index, std::memory_order_release);
    return false;
}

bool RealtimeEventQueue::pop(CoreEvent& event) noexcept {
    return popRing(event) || popCoalesced(event);
}

bool RealtimeEventQueue::pushRing(CoreEvent event) noexcept {
    auto position = enqueuePosition_.load(std::memory_order_relaxed);

    for (;;) {
        auto& cell = cells_[position & mask];
        const auto sequence = cell.sequence.load(std::memory_order_acquire);
        const auto difference =
            static_cast<std::intptr_t>(sequence) - static_cast<std::intptr_t>(position);

        if (difference == 0) {
            if (enqueuePosition_.compare_exchange_weak(position, position + 1,
                                                       std::memory_order_relaxed)) {
                cell.event = event;
                cell.sequence.store(position + 1, std::memory_order_release);
                return true;
            }
        } else if (difference < 0) {
            return false;
        } else {
            position = enqueuePosition_.load(std::memory_order_relaxed);
        }
    }
}

bool RealtimeEventQueue::popRing(CoreEvent& event) noexcept {
    auto position = dequeuePosition_.load(std::memory_order_relaxed);

    for (;;) {
        auto& cell = cells_[position & mask];
        const auto sequence = cell.sequence.load(std::memory_order_acquire);
        const auto difference =
            static_cast<std::intptr_t>(sequence) - static_cast<std::intptr_t>(position + 1);

        if (difference == 0) {
            if (dequeuePosition_.compare_exchange_weak(position, position + 1,
                                                       std::memory_order_relaxed)) {
                event = cell.event;
                cell.sequence.store(position + capacity, std::memory_order_release);
                return true;
            }
        } else if (difference < 0) {
            return false;
        } else {
            position = dequeuePosition_.load(std::memory_order_relaxed);
        }
    }
}

bool RealtimeEventQueue::popCoalesced(CoreEvent& event) noexcept {
    auto pending = coalescedTypes_.load(std::memory_order_acquire);

    while (pending != 0) {
        const auto index = static_cast<std::size_t>(std::countr_zero(pending));
        const auto bit = std::uint32_t{1} << index;
        const auto remaining = pending & ~bit;
        if (coalescedTypes_.compare_exchange_weak(pending, remaining, std::memory_order_acq_rel)) {
            event = {
                .type = static_cast<CoreEventType>(index),
                .value = coalescedValues_[index].load(std::memory_order_relaxed),
                .error = static_cast<AudioErrorCode>(
                    coalescedErrors_[index].load(std::memory_order_relaxed)),
            };
            return true;
        }
    }

    return false;
}

} // namespace shitate
