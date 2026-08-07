// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "OutputSafetyProcessor.h"

#include <algorithm>
#include <cmath>

namespace shitate {

void OutputSafetyProcessor::prepare(int maximumFrames) noexcept {
    maximumFrames_ = std::max(0, maximumFrames);
}

void OutputSafetyProcessor::process(juce::AudioBuffer<float>& buffer, int frames) noexcept {
    const auto safeFrames = std::clamp(frames, 0, std::min(maximumFrames_, buffer.getNumSamples()));

    for (auto channel = 0; channel < buffer.getNumChannels(); ++channel) {
        auto* samples = buffer.getWritePointer(channel);
        for (auto frame = 0; frame < safeFrames; ++frame) {
            auto sample = samples[frame];
            if (!std::isfinite(sample) || std::fpclassify(sample) == FP_SUBNORMAL) {
                sample = 0.0F;
            }
            samples[frame] = std::clamp(sample, -1.0F, 1.0F);
        }
    }
}

} // namespace shitate
