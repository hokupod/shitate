// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include <atomic>
#include <juce_audio_basics/juce_audio_basics.h>

namespace shitate {

class MasterOutputStage final {
  public:
    void prepare(double sampleRate) noexcept;
    void beginStart() noexcept;
    void beginStop() noexcept;
    void setMuted(bool muted) noexcept;
    void process(juce::AudioBuffer<float>& buffer, int frames) noexcept;

    [[nodiscard]] bool isMuted() const noexcept;
    [[nodiscard]] bool isTransportSilent() const noexcept;

  private:
    struct Ramp {
        float current = 0.0F;
        float target = 0.0F;
        float step = 0.0F;
        int remaining = 0;

        void set(float newTarget, int samples) noexcept;
        [[nodiscard]] float next() noexcept;
    };

    void synchronizeTargets() noexcept;

    std::atomic<bool> requestedRunning_{false};
    std::atomic<bool> requestedMuted_{false};
    std::atomic<bool> transportSilent_{true};
    bool appliedRunning_ = false;
    bool appliedMuted_ = false;
    int startStopRampSamples_ = 1;
    int muteRampSamples_ = 1;
    Ramp transport_;
    Ramp mute_;
};

static_assert(std::atomic<bool>::is_always_lock_free);

} // namespace shitate
