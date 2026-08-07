// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "MeterAccumulator.h"

#include <algorithm>
#include <cmath>

namespace shitate {
namespace {
constexpr float meterFloorDb = -96.0F;
constexpr float signalFloorLinear = 0.0000158489319F;
} // namespace

void MeterAccumulator::prepare() noexcept {
    peakLinear_.store(0.0F, std::memory_order_relaxed);
    rmsLinear_.store(0.0F, std::memory_order_relaxed);
    clipping_.store(false, std::memory_order_relaxed);
    signalPresent_.store(false, std::memory_order_relaxed);
    beginBlock();
}

void MeterAccumulator::beginBlock() noexcept {
    blockPeak_ = 0.0F;
    blockSumSquares_ = 0.0;
    blockSampleCount_ = 0;
}

void MeterAccumulator::accumulate(const juce::AudioBuffer<float>& buffer, int frames) noexcept {
    const auto safeFrames = std::clamp(frames, 0, buffer.getNumSamples());
    const auto channels = buffer.getNumChannels();

    for (auto channel = 0; channel < channels; ++channel) {
        const auto* samples = buffer.getReadPointer(channel);
        for (auto frame = 0; frame < safeFrames; ++frame) {
            const auto sample = std::isfinite(samples[frame]) ? samples[frame] : 0.0F;
            const auto magnitude = std::abs(sample);
            blockPeak_ = std::max(blockPeak_, magnitude);
            blockSumSquares_ += static_cast<double>(sample) * static_cast<double>(sample);
            ++blockSampleCount_;
        }
    }
}

void MeterAccumulator::publish() noexcept {
    const auto rms = blockSampleCount_ > 0
                         ? static_cast<float>(
                               std::sqrt(blockSumSquares_ / static_cast<double>(blockSampleCount_)))
                         : 0.0F;
    peakLinear_.store(blockPeak_, std::memory_order_relaxed);
    rmsLinear_.store(rms, std::memory_order_relaxed);
    clipping_.store(blockPeak_ >= 1.0F, std::memory_order_relaxed);
    signalPresent_.store(blockPeak_ >= signalFloorLinear, std::memory_order_relaxed);
}

void MeterAccumulator::process(const juce::AudioBuffer<float>& buffer, int frames) noexcept {
    beginBlock();
    accumulate(buffer, frames);
    publish();
}

MeterValue MeterAccumulator::snapshot() const noexcept {
    const auto peak = peakLinear_.load(std::memory_order_relaxed);
    const auto rms = rmsLinear_.load(std::memory_order_relaxed);
    return {
        .peakDb = linearToDb(peak),
        .rmsDb = linearToDb(rms),
        .clipping = clipping_.load(std::memory_order_relaxed),
        .signalPresent = signalPresent_.load(std::memory_order_relaxed),
    };
}

float MeterAccumulator::linearToDb(float value) noexcept {
    if (!std::isfinite(value) || value <= 0.0F) {
        return meterFloorDb;
    }

    return std::max(meterFloorDb, 20.0F * std::log10(value));
}

} // namespace shitate
