// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "AudioTypes.h"
#include "RealtimeEventQueue.h"
#include "RealtimeSafety.h"

#include <CoreAudio/CoreAudio.h>
#include <atomic>
#include <juce_audio_devices/juce_audio_devices.h>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace shitate {

class DeviceService final : private juce::AudioIODeviceType::Listener {
  public:
    explicit DeviceService(RealtimeEventQueue& eventQueue);
    ~DeviceService() override;

    DeviceService(const DeviceService&) = delete;
    DeviceService& operator=(const DeviceService&) = delete;

    [[nodiscard]] std::vector<AudioDeviceInfo> enumerateDevices();
    [[nodiscard]] AudioResult configure(const AudioConfiguration& configuration);
    [[nodiscard]] AudioResult start(juce::AudioIODeviceCallback* callback);
    void stop() noexcept;
    void close() noexcept;

    [[nodiscard]] bool isConfigurationValid() const noexcept;
    [[nodiscard]] EngineDiagnostics diagnostics() const noexcept;
    [[nodiscard]] AggregateEvidence activeAggregateEvidence() const;

    void invalidateFromCallback() noexcept;

    [[nodiscard]] static const AudioDeviceInfo*
    findByUID(const std::vector<AudioDeviceInfo>& devices, std::string_view uid) noexcept;
    [[nodiscard]] static const AudioDeviceInfo*
    findBlackHole(const std::vector<AudioDeviceInfo>& devices) noexcept;
    [[nodiscard]] static int choosePreferredBuffer(const AudioDeviceInfo& input,
                                                   const AudioDeviceInfo& output) noexcept;
    [[nodiscard]] static AudioResult
    validateConfiguration(const AudioConfiguration& configuration,
                          const std::vector<AudioDeviceInfo>& devices);
    [[nodiscard]] static AudioResult
    validateManualAggregateEvidence(const ManualAggregateEvidence& evidence);
    [[nodiscard]] static AudioResult
    validateRoutingEvidence(RoutingMode mode, const AggregateEvidence& automaticEvidence,
                            const ManualAggregateEvidence& manualEvidence);

  private:
    void audioDeviceListChanged() override;
    [[nodiscard]] juce::AudioIODeviceType* coreAudioType() noexcept;
    [[nodiscard]] AudioErrorCode
    configuredEnvironmentError(const std::vector<AudioDeviceInfo>& devices) const;
    [[nodiscard]] ManualAggregateEvidence
    inspectManualAggregate(const AudioConfiguration& configuration) const;
    [[nodiscard]] bool installXrunListener() noexcept;
    void removeXrunListener() noexcept;
    static OSStatus xrunPropertyChanged(AudioObjectID object, UInt32 addressCount,
                                        const AudioObjectPropertyAddress* addresses,
                                        void* clientData) noexcept;

    RealtimeEventQueue& eventQueue_;
    juce::ScopedJuceInitialiser_GUI juceRuntime_;
    juce::AudioDeviceManager deviceManager_;
    juce::AudioIODeviceType* coreAudioType_ = nullptr;
    mutable RealtimeCheckedMutex controlMutex_;
    std::unique_ptr<juce::AudioIODevice> activeDevice_;
    std::optional<AudioConfiguration> configuration_;
    std::string evidenceInputDeviceUID_;
    std::string evidenceOutputDeviceUID_;
    std::vector<std::string> expectedSubdeviceUIDs_;
    AudioObjectID xrunDeviceID_ = kAudioObjectUnknown;
    std::atomic<bool> configurationValid_{false};
    std::atomic<int> xrunCount_{0};
};

} // namespace shitate
