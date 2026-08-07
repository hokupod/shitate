// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include <atomic>
#include <mutex>

namespace shitate {

class RealtimeSafety final {
  public:
    static void enterCallback() noexcept {
#ifndef NDEBUG
        callbackActive_ = true;
#endif
    }

    static void leaveCallback() noexcept {
#ifndef NDEBUG
        callbackActive_ = false;
#endif
    }

    static void noteLockAttempt() noexcept {
#ifndef NDEBUG
        if (callbackActive_) {
            lockAttempted_.store(true, std::memory_order_release);
        }
#endif
    }

#ifndef NDEBUG
    static void resetLockAssertionForTesting() noexcept {
        lockAttempted_.store(false, std::memory_order_release);
    }

    [[nodiscard]] static bool lockAttemptedForTesting() noexcept {
        return lockAttempted_.load(std::memory_order_acquire);
    }
#endif

  private:
#ifndef NDEBUG
    inline static thread_local bool callbackActive_ = false;
    inline static std::atomic<bool> lockAttempted_{false};
#endif
};

class RealtimeCheckedMutex final {
  public:
    void lock() {
        RealtimeSafety::noteLockAttempt();
        mutex_.lock();
    }

    [[nodiscard]] bool try_lock() {
        RealtimeSafety::noteLockAttempt();
        return mutex_.try_lock();
    }

    void unlock() noexcept {
        mutex_.unlock();
    }

  private:
    std::mutex mutex_;
};

} // namespace shitate
