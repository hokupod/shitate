// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "InputMapper.h"

#include <algorithm>

namespace shitate {

void InputMapper::prepare(int maximumFrames) noexcept {
    maximumFrames_ = std::max(0, maximumFrames);
}

void InputMapper::mapMonoToDualMono(const float* source, int frames,
                                    juce::AudioBuffer<float>& destination) noexcept {
    const auto channels = std::min(2, destination.getNumChannels());
    const auto safeFrames =
        std::clamp(frames, 0, std::min(maximumFrames_, destination.getNumSamples()));

    for (auto channel = 0; channel < channels; ++channel) {
        auto* target = destination.getWritePointer(channel);
        if (source == nullptr) {
            juce::FloatVectorOperations::clear(target, safeFrames);
        } else {
            juce::FloatVectorOperations::copy(target, source, safeFrames);
        }
    }

    for (auto channel = channels; channel < destination.getNumChannels(); ++channel) {
        destination.clear(channel, 0, safeFrames);
    }
}

} // namespace shitate
