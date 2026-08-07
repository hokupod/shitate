// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace shitate {

inline constexpr double requiredSampleRate = 48000.0;
inline constexpr int preferredBufferFrames = 256;
inline constexpr int maximumPluginFrames = 512;
inline constexpr int maximumCallbackFrames = 1024;

enum class AudioErrorCode : int {
    none = 0,
    unknown = 1,
    blackHoleMissing = 100,
    microphonePermissionDenied = 101,
    inputDeviceMissing = 102,
    outputDeviceMissing = 103,
    unsupportedSampleRate = 104,
    unsupportedBufferSize = 105,
    aggregateDeviceCreationFailed = 106,
    engineStartFailed = 107,
    engineXRun = 108,
    invalidConfiguration = 109,
    callbackLayoutInvalid = 110,
};

struct AudioResult {
    AudioErrorCode code = AudioErrorCode::none;
    std::string message;

    [[nodiscard]] bool succeeded() const noexcept {
        return code == AudioErrorCode::none;
    }

    [[nodiscard]] static AudioResult success() {
        return {};
    }

    [[nodiscard]] static AudioResult failure(AudioErrorCode errorCode, std::string detail) {
        return {errorCode, std::move(detail)};
    }
};

enum class RoutingMode : int {
    automaticPrivateAggregate = 0,
    manualAggregate = 1,
};

struct AudioDeviceInfo {
    std::string uid;
    std::string displayName;
    std::string backendInputName;
    std::string backendOutputName;
    std::vector<std::string> inputChannelNames;
    std::vector<std::string> outputChannelNames;
    std::vector<double> sampleRates;
    std::vector<int> allowedBufferFrames;
    int minimumBufferFrames = 0;
    int maximumBufferFrames = 0;
    bool alive = false;
    bool aggregate = false;

    [[nodiscard]] bool hasInputs() const noexcept {
        return !inputChannelNames.empty();
    }
    [[nodiscard]] bool hasOutputs() const noexcept {
        return !outputChannelNames.empty();
    }
};

struct AudioConfiguration {
    RoutingMode mode = RoutingMode::automaticPrivateAggregate;
    std::string inputDeviceUID;
    std::string outputDeviceUID;
    std::string blackHoleDeviceUID;
    int inputChannelIndex = 0;
    int manualOutputChannelStart = 0;
    double sampleRate = requiredSampleRate;
    int bufferFrames = preferredBufferFrames;
};

struct MeterSnapshot {
    float inputPeakDb = -96.0F;
    float inputRmsDb = -96.0F;
    float outputPeakDb = -96.0F;
    float outputRmsDb = -96.0F;
    bool inputClipping = false;
    bool outputClipping = false;
    bool inputSignalPresent = false;
    bool outputSignalPresent = false;
};

struct EngineDiagnostics {
    double sampleRate = 0.0;
    int bufferFrames = 0;
    int inputLatencySamples = 0;
    int outputLatencySamples = 0;
    int xrunCount = 0;
    double callbackTimeEmaMicroseconds = 0.0;
};

enum class EngineStatus : int {
    stopped = 0,
    configured = 1,
    starting = 2,
    running = 3,
    muted = 4,
    stopping = 5,
    blocked = 6,
};

enum class CoreEventType : std::uint8_t {
    engineStateChanged = 0,
    devicesChanged = 1,
    xrunDetected = 2,
    recoveryRequested = 3,
    fatalError = 4,
};

struct CoreEvent {
    CoreEventType type = CoreEventType::engineStateChanged;
    int value = 0;
    AudioErrorCode error = AudioErrorCode::none;
};

struct AggregateEvidence {
    bool aggregateFound = false;
    bool privateDevice = false;
    bool outputOwnsClock = false;
    bool inputDriftCompensated = false;
    bool inputPresent = false;
    bool outputPresent = false;
    bool subdevicesMatch = false;
};

struct ManualAggregateEvidence {
    bool aggregateFound = false;
    bool blackHolePresent = false;
    bool outputOwnsClock = false;
    bool selectedInputIsPhysical = false;
    bool inputDriftCompensated = false;
    bool outputChannelsOwnedByBlackHole = false;
    std::string selectedInputSubdeviceUID;
    std::vector<std::string> orderedSubdeviceUIDs;
};

} // namespace shitate
