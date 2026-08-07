// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "AudioTypes.h"
#include "DeviceService.h"
#include "InputMapper.h"
#include "MasterOutputStage.h"
#include "MeterAccumulator.h"
#include "OutputSafetyProcessor.h"
#include "RealtimeEventQueue.h"

#include <atomic>
#include <chrono>
#include <juce_audio_devices/juce_audio_devices.h>

namespace shitate {

enum class AudioCallbackState : std::uint8_t { idle, active, cancelled };

class AudioEngine final : public juce::AudioIODeviceCallback {
  public:
    AudioEngine(DeviceService& deviceService, RealtimeEventQueue& eventQueue) noexcept;
    ~AudioEngine() override;

    [[nodiscard]] AudioResult configure(const AudioConfiguration& configuration);
    [[nodiscard]] AudioResult start();
    void stop() noexcept;
    void failClosed() noexcept;
    void setMasterMuted(bool muted) noexcept;

    [[nodiscard]] bool isRunning() const noexcept;
    [[nodiscard]] EngineStatus status() const noexcept;
    [[nodiscard]] MeterSnapshot meterSnapshot() const noexcept;
    [[nodiscard]] EngineDiagnostics diagnostics() const noexcept;
    [[nodiscard]] bool popEvent(CoreEvent& event) noexcept;

    void audioDeviceAboutToStart(juce::AudioIODevice* device) override;
    void audioDeviceStopped() override;
    void audioDeviceError(const juce::String& message) override;
    void
    audioDeviceIOCallbackWithContext(const float* const* inputChannelData, int numInputChannels,
                                     float* const* outputChannelData, int numOutputChannels,
                                     int numSamples,
                                     const juce::AudioIODeviceCallbackContext& context) override;

#ifndef NDEBUG
    explicit AudioEngine(RealtimeEventQueue& eventQueue) noexcept;
    void prepareForTesting(double sampleRate);
    void setRunningForTesting(bool running) noexcept;
    void setCallbackBarrierForTesting(std::atomic<bool>* entered,
                                      std::atomic<bool>* release) noexcept;
    [[nodiscard]] bool callbackInvariantViolationForTesting() const noexcept;
#endif

  private:
    void prepareProcessing(double sampleRate);
    void servicePendingStop() noexcept;
    void completeStop() noexcept;
    void setStatus(EngineStatus status) noexcept;
    void cancelOutput() noexcept;
    void requestRecovery(AudioErrorCode error) noexcept;
    void clearOutputs(float* const* channels, int channelCount, int frames) noexcept;
    void processChunk(const float* input, float* leftOutput, float* rightOutput, int offset,
                      int frames) noexcept;
    [[nodiscard]] bool configurationIsValid() const noexcept;

    DeviceService* deviceService_ = nullptr;
    RealtimeEventQueue& eventQueue_;
    juce::AudioBuffer<float> workingBuffer_;
    InputMapper inputMapper_;
    MeterAccumulator inputMeter_;
    MeterAccumulator outputMeter_;
    OutputSafetyProcessor outputSafety_;
    MasterOutputStage masterOutput_;
    std::atomic<EngineStatus> status_{EngineStatus::stopped};
    std::atomic<bool> running_{false};
    std::atomic<bool> configured_{false};
    std::atomic<bool> outputPermitted_{false};
    std::atomic<bool> recoveryPending_{false};
    std::atomic<bool> callbackInvariantViolation_{false};
    std::atomic<AudioCallbackState> callbackState_{AudioCallbackState::idle};
    std::atomic<std::uint64_t> outputGeneration_{0};
    std::atomic<double> callbackTimeEmaMicroseconds_{0.0};
    std::atomic<int> lastReportedXrun_{0};
    std::chrono::steady_clock::time_point stopDeadline_{};
#ifndef NDEBUG
    std::atomic<bool>* callbackEnteredForTesting_ = nullptr;
    std::atomic<bool>* callbackReleaseForTesting_ = nullptr;
#endif
};

static_assert(std::atomic<EngineStatus>::is_always_lock_free);
static_assert(std::atomic<AudioCallbackState>::is_always_lock_free);
static_assert(std::atomic<std::uint64_t>::is_always_lock_free);
static_assert(std::atomic<double>::is_always_lock_free);
static_assert(std::atomic<int>::is_always_lock_free);

} // namespace shitate
