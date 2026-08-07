// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include <juce_audio_basics/juce_audio_basics.h>

namespace shitate {

class InputMapper final {
  public:
    void prepare(int maximumFrames) noexcept;
    void mapMonoToDualMono(const float* source, int frames,
                           juce::AudioBuffer<float>& destination) noexcept;

  private:
    int maximumFrames_ = 0;
};

} // namespace shitate
