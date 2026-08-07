// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "MasterOutputStage.h"

#include <algorithm>
#include <cmath>

namespace shitate {

void MasterOutputStage::Ramp::set(float newTarget, int samples) noexcept {
    target = newTarget;
    remaining = std::max(1, samples);
    step = (target - current) / static_cast<float>(remaining);
}

float MasterOutputStage::Ramp::next() noexcept {
    if (remaining <= 0) {
        return current;
    }

    current += step;
    --remaining;
    if (remaining == 0) {
        current = target;
    }
    return current;
}

void MasterOutputStage::prepare(double sampleRate) noexcept {
    const auto safeRate = std::max(1.0, sampleRate);
    startStopRampSamples_ = std::max(1, static_cast<int>(std::lround(safeRate * 0.010)));
    muteRampSamples_ = std::max(1, static_cast<int>(std::lround(safeRate * 0.005)));
    requestedRunning_.store(false, std::memory_order_relaxed);
    requestedMuted_.store(false, std::memory_order_relaxed);
    transportSilent_.store(true, std::memory_order_relaxed);
    appliedRunning_ = false;
    appliedMuted_ = false;
    transport_ = {};
    mute_ = {.current = 1.0F, .target = 1.0F, .step = 0.0F, .remaining = 0};
}

void MasterOutputStage::beginStart() noexcept {
    requestedRunning_.store(true, std::memory_order_release);
}

void MasterOutputStage::beginStop() noexcept {
    requestedRunning_.store(false, std::memory_order_release);
}

void MasterOutputStage::setMuted(bool muted) noexcept {
    requestedMuted_.store(muted, std::memory_order_release);
}

void MasterOutputStage::synchronizeTargets() noexcept {
    const auto shouldRun = requestedRunning_.load(std::memory_order_acquire);
    if (shouldRun != appliedRunning_) {
        appliedRunning_ = shouldRun;
        transport_.set(shouldRun ? 1.0F : 0.0F, startStopRampSamples_);
        if (shouldRun) {
            transportSilent_.store(false, std::memory_order_release);
        }
    }

    const auto shouldMute = requestedMuted_.load(std::memory_order_acquire);
    if (shouldMute != appliedMuted_) {
        appliedMuted_ = shouldMute;
        mute_.set(shouldMute ? 0.0F : 1.0F, muteRampSamples_);
    }
}

void MasterOutputStage::process(juce::AudioBuffer<float>& buffer, int frames) noexcept {
    synchronizeTargets();
    const auto safeFrames = std::clamp(frames, 0, buffer.getNumSamples());

    for (auto frame = 0; frame < safeFrames; ++frame) {
        const auto gain = transport_.next() * mute_.next();
        for (auto channel = 0; channel < buffer.getNumChannels(); ++channel) {
            buffer.getWritePointer(channel)[frame] *= gain;
        }
    }

    if (!appliedRunning_ && transport_.remaining == 0 && transport_.current == 0.0F) {
        transportSilent_.store(true, std::memory_order_release);
    }
}

bool MasterOutputStage::isMuted() const noexcept {
    return requestedMuted_.load(std::memory_order_acquire);
}

bool MasterOutputStage::isTransportSilent() const noexcept {
    return transportSilent_.load(std::memory_order_acquire);
}

} // namespace shitate
