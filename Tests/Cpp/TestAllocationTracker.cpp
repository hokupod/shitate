// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "TestAllocationTracker.h"

#include <atomic>
#include <cstdlib>
#include <new>

namespace {
std::atomic<std::size_t> allocations{0};

void* allocate(std::size_t size) {
    allocations.fetch_add(1, std::memory_order_relaxed);
    if (auto* memory = std::malloc(size); memory != nullptr) {
        return memory;
    }
    throw std::bad_alloc();
}
} // namespace

void* operator new(std::size_t size) {
    return allocate(size);
}

void* operator new[](std::size_t size) {
    return allocate(size);
}

void operator delete(void* memory) noexcept {
    std::free(memory);
}

void operator delete[](void* memory) noexcept {
    std::free(memory);
}

void operator delete(void* memory, std::size_t size) noexcept {
    (void)size;
    std::free(memory);
}

void operator delete[](void* memory, std::size_t size) noexcept {
    (void)size;
    std::free(memory);
}

namespace shitate::test {

std::size_t allocationCount() noexcept {
    return allocations.load(std::memory_order_relaxed);
}

} // namespace shitate::test
