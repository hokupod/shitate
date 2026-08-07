// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include <atomic>
#include <juce_audio_basics/juce_audio_basics.h>

namespace shitate {

struct MeterValue {
    float peakDb = -96.0F;
    float rmsDb = -96.0F;
    bool clipping = false;
    bool signalPresent = false;
};

class MeterAccumulator final {
  public:
    void prepare() noexcept;
    void beginBlock() noexcept;
    void accumulate(const juce::AudioBuffer<float>& buffer, int frames) noexcept;
    void publish() noexcept;
    void process(const juce::AudioBuffer<float>& buffer, int frames) noexcept;
    [[nodiscard]] MeterValue snapshot() const noexcept;

  private:
    static float linearToDb(float value) noexcept;

    std::atomic<float> peakLinear_{0.0F};
    std::atomic<float> rmsLinear_{0.0F};
    std::atomic<bool> clipping_{false};
    std::atomic<bool> signalPresent_{false};
    float blockPeak_ = 0.0F;
    double blockSumSquares_ = 0.0;
    int blockSampleCount_ = 0;
};

static_assert(std::atomic<float>::is_always_lock_free);

} // namespace shitate
