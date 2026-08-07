// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "AudioEngine.h"

#include "RealtimeSafety.h"

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <limits>
#include <thread>

namespace shitate {
namespace {

class CallbackScope final {
  public:
    explicit CallbackScope(std::atomic<AudioCallbackState>& state) noexcept : state_(state) {
        RealtimeSafety::enterCallback();
    }
    ~CallbackScope() {
        if (!finished_) {
            state_.store(AudioCallbackState::idle, std::memory_order_release);
        }
        RealtimeSafety::leaveCallback();
    }

    [[nodiscard]] bool tryCommit() noexcept {
        auto expected = AudioCallbackState::active;
        finished_ = state_.compare_exchange_strong(expected, AudioCallbackState::idle,
                                                   std::memory_order_acq_rel);
        return finished_;
    }

    void finishCancelled() noexcept {
        state_.store(AudioCallbackState::idle, std::memory_order_release);
        finished_ = true;
    }

  private:
    std::atomic<AudioCallbackState>& state_;
    bool finished_ = false;
};

} // namespace

AudioEngine::AudioEngine(DeviceService& deviceService, RealtimeEventQueue& eventQueue,
                         PluginChain* pluginChain) noexcept
    : deviceService_(&deviceService), eventQueue_(eventQueue), pluginChain_(pluginChain),
      callbackState_(&deviceService.callbackCommitState()) {}

#ifndef NDEBUG
AudioEngine::AudioEngine(RealtimeEventQueue& eventQueue, PluginChain* pluginChain) noexcept
    : eventQueue_(eventQueue), pluginChain_(pluginChain) {}
#endif

AudioEngine::~AudioEngine() {
    cancelOutput();
    running_.store(false, std::memory_order_release);
    if (pluginChain_ != nullptr) {
        pluginChain_->setRunning(false);
    }
    if (deviceService_ != nullptr) {
        deviceService_->stop();
    }
    waitForCallbackQuiescence();
    if (pluginChain_ != nullptr) {
        pluginChain_->releaseResources();
    }
}

AudioResult AudioEngine::configure(const AudioConfiguration& configuration) {
    if (isRunning()) {
        return AudioResult::failure(AudioErrorCode::invalidConfiguration,
                                    "Stop routing before changing audio configuration.");
    }
    if (deviceService_ == nullptr) {
        return AudioResult::failure(AudioErrorCode::invalidConfiguration,
                                    "No production device service is available.");
    }

    outputPermitted_.store(false, std::memory_order_release);
    configured_.store(false, std::memory_order_release);
    if (const auto result = deviceService_->configure(configuration); !result.succeeded()) {
        setStatus(EngineStatus::blocked);
        return result;
    }

    if (!prepareProcessing(configuration.sampleRate)) {
        deviceService_->close();
        setStatus(EngineStatus::blocked);
        return AudioResult::failure(AudioErrorCode::invalidConfiguration,
                                    "The plug-in chain could not be prepared.");
    }
    configured_.store(true, std::memory_order_release);
    recoveryPending_.store(false, std::memory_order_release);
    setStatus(EngineStatus::configured);
    return AudioResult::success();
}

AudioResult AudioEngine::start() {
    if (isRunning()) {
        if (status() == EngineStatus::stopping) {
            return AudioResult::failure(AudioErrorCode::engineStartFailed,
                                        "Routing is still stopping.");
        }
        return AudioResult::success();
    }
    if (!configured_.load(std::memory_order_acquire) || !configurationIsValid() ||
        deviceService_ == nullptr ||
        (pluginChain_ != nullptr &&
         (!pluginChain_->isPrepared() || !pluginChain_->isSessionComplete()))) {
        setStatus(EngineStatus::blocked);
        return AudioResult::failure(AudioErrorCode::engineStartFailed,
                                    "Routing requirements are incomplete.");
    }

    setStatus(EngineStatus::starting);
    masterOutput_.beginStart();
    outputPermitted_.store(false, std::memory_order_release);
    running_.store(true, std::memory_order_release);
    if (pluginChain_ != nullptr) {
        pluginChain_->setRunning(true);
    }
    if (const auto result = deviceService_->start(this); !result.succeeded()) {
        running_.store(false, std::memory_order_release);
        if (pluginChain_ != nullptr) {
            pluginChain_->setRunning(false);
        }
        masterOutput_.beginStop();
        setStatus(EngineStatus::blocked);
        return result;
    }
    if (!running_.load(std::memory_order_acquire) || !configurationIsValid()) {
        deviceService_->stop();
        if (pluginChain_ != nullptr) {
            pluginChain_->setRunning(false);
        }
        configured_.store(false, std::memory_order_release);
        setStatus(EngineStatus::blocked);
        return AudioResult::failure(AudioErrorCode::engineStartFailed,
                                    "CoreAudio started with an invalid format.");
    }

    outputPermitted_.store(true, std::memory_order_release);
    setStatus(masterOutput_.isMuted() ? EngineStatus::muted : EngineStatus::running);
    return AudioResult::success();
}

void AudioEngine::stop() noexcept {
    if (status() == EngineStatus::stopping) {
        return;
    }
    if (!running_.load(std::memory_order_acquire)) {
        outputPermitted_.store(false, std::memory_order_release);
        setStatus(configured_.load(std::memory_order_acquire) ? EngineStatus::configured
                                                              : EngineStatus::stopped);
        return;
    }

    setStatus(EngineStatus::stopping);
    masterOutput_.beginStop();
    stopDeadline_ = std::chrono::steady_clock::now() + std::chrono::milliseconds(50);
}

void AudioEngine::failClosed() noexcept {
    cancelOutput();
    configured_.store(false, std::memory_order_release);
    running_.store(false, std::memory_order_release);
    if (pluginChain_ != nullptr) {
        pluginChain_->setRunning(false);
    }
    if (deviceService_ != nullptr) {
        deviceService_->close();
    }
    waitForCallbackQuiescence();
    if (pluginChain_ != nullptr) {
        pluginChain_->releaseResources();
    }
    setStatus(EngineStatus::blocked);
}

void AudioEngine::setMasterMuted(bool muted) noexcept {
    masterOutput_.setMuted(muted);
    if (isRunning()) {
        setStatus(muted ? EngineStatus::muted : EngineStatus::running);
    }
}

bool AudioEngine::isRunning() const noexcept {
    return running_.load(std::memory_order_acquire);
}

EngineStatus AudioEngine::status() const noexcept {
    return status_.load(std::memory_order_acquire);
}

MeterSnapshot AudioEngine::meterSnapshot() const noexcept {
    const auto currentStatus = status();
    if (currentStatus != EngineStatus::running && currentStatus != EngineStatus::muted &&
        currentStatus != EngineStatus::stopping) {
        return {};
    }

    const auto input = inputMeter_.snapshot();
    const auto output = outputMeter_.snapshot();
    return {
        .inputPeakDb = input.peakDb,
        .inputRmsDb = input.rmsDb,
        .outputPeakDb = output.peakDb,
        .outputRmsDb = output.rmsDb,
        .inputClipping = input.clipping,
        .outputClipping = output.clipping,
        .inputSignalPresent = input.signalPresent,
        .outputSignalPresent = output.signalPresent,
    };
}

EngineDiagnostics AudioEngine::diagnostics() const noexcept {
    auto result = deviceService_ != nullptr ? deviceService_->diagnostics() : EngineDiagnostics{};
    result.pluginLatencySamples = pluginChain_ != nullptr ? pluginChain_->totalLatencySamples() : 0;
    const auto hostLatency =
        static_cast<std::int64_t>(result.inputLatencySamples) + result.outputLatencySamples;
    const auto aggregateLatency = hostLatency + result.pluginLatencySamples;
    result.aggregateLatencySamples =
        static_cast<int>(std::min<std::int64_t>(aggregateLatency, std::numeric_limits<int>::max()));
    result.callbackTimeEmaMicroseconds =
        callbackTimeEmaMicroseconds_.load(std::memory_order_relaxed);
    return result;
}

bool AudioEngine::popEvent(CoreEvent& event) noexcept {
    servicePendingStop();
    if (deviceService_ != nullptr) {
        const auto currentXruns = deviceService_->diagnostics().xrunCount;
        const auto previous = lastReportedXrun_.exchange(currentXruns, std::memory_order_relaxed);
        if (currentXruns > previous && currentXruns > 0) {
            (void)eventQueue_.push({.type = CoreEventType::xrunDetected,
                                    .value = currentXruns,
                                    .error = AudioErrorCode::engineXRun});
        }
    }

    if (!eventQueue_.pop(event)) {
        return false;
    }
    return true;
}

void AudioEngine::audioDeviceAboutToStart(juce::AudioIODevice* device) {
    if (device == nullptr || device->getCurrentSampleRate() != requiredSampleRate ||
        device->getCurrentBufferSizeSamples() <= 0 ||
        device->getCurrentBufferSizeSamples() > maximumCallbackFrames) {
        outputPermitted_.store(false, std::memory_order_release);
        running_.store(false, std::memory_order_release);
        requestRecovery(AudioErrorCode::invalidConfiguration);
    }
}

void AudioEngine::audioDeviceStopped() {
    outputPermitted_.store(false, std::memory_order_release);
    if (pluginChain_ != nullptr) {
        pluginChain_->setRunning(false);
    }
    if (running_.exchange(false, std::memory_order_acq_rel)) {
        configured_.store(false, std::memory_order_release);
        setStatus(EngineStatus::blocked);
        const auto invalidation =
            deviceService_ != nullptr ? deviceService_->invalidationError() : AudioErrorCode::none;
        requestRecovery(invalidation == AudioErrorCode::none ? AudioErrorCode::engineStartFailed
                                                             : invalidation);
    }
}

void AudioEngine::audioDeviceError(const juce::String& message) {
    juce::ignoreUnused(message);
    outputPermitted_.store(false, std::memory_order_release);
    running_.store(false, std::memory_order_release);
    if (pluginChain_ != nullptr) {
        pluginChain_->setRunning(false);
    }
    configured_.store(false, std::memory_order_release);
    if (deviceService_ != nullptr) {
        deviceService_->invalidateFromCallback();
    }
    setStatus(EngineStatus::blocked);
    const auto invalidation =
        deviceService_ != nullptr ? deviceService_->invalidationError() : AudioErrorCode::none;
    requestRecovery(invalidation == AudioErrorCode::none ? AudioErrorCode::engineStartFailed
                                                         : invalidation);
}

void AudioEngine::audioDeviceIOCallbackWithContext(
    const float* const* inputChannelData, int numInputChannels, float* const* outputChannelData,
    int numOutputChannels, int numSamples, const juce::AudioIODeviceCallbackContext& context) {
    juce::ignoreUnused(context);
    const auto started = std::chrono::steady_clock::now();
    const auto framesToClear = std::max(0, numSamples);
    clearOutputs(outputChannelData, numOutputChannels, framesToClear);

    auto expectedState = AudioCallbackState::idle;
    if (!callbackState_->compare_exchange_strong(expectedState, AudioCallbackState::active,
                                                 std::memory_order_acq_rel)) {
        callbackInvariantViolation_.store(true, std::memory_order_release);
        requestRecovery(AudioErrorCode::callbackLayoutInvalid);
        return;
    }
    CallbackScope callbackScope(*callbackState_);
    const auto outputGeneration = outputGeneration_.load(std::memory_order_acquire);

    if (!isRunning() || !outputPermitted_.load(std::memory_order_acquire)) {
        return;
    }
    if (numSamples == 0) {
        return;
    }
    if (numSamples < 0 || numSamples > maximumCallbackFrames) {
        requestRecovery(AudioErrorCode::callbackLayoutInvalid);
        return;
    }
    if (!configurationIsValid()) {
        const auto invalidation =
            deviceService_ != nullptr ? deviceService_->invalidationError() : AudioErrorCode::none;
        requestRecovery(invalidation == AudioErrorCode::none ? AudioErrorCode::invalidConfiguration
                                                             : invalidation);
        return;
    }
    if (inputChannelData == nullptr || numInputChannels < 1 || inputChannelData[0] == nullptr) {
        requestRecovery(AudioErrorCode::inputDeviceMissing);
        return;
    }
    if (outputChannelData == nullptr || numOutputChannels < 2 || outputChannelData[0] == nullptr ||
        outputChannelData[1] == nullptr) {
        requestRecovery(AudioErrorCode::outputDeviceMissing);
        return;
    }

    juce::ScopedNoDenormals noDenormals;
    inputMeter_.beginBlock();
    outputMeter_.beginBlock();
    for (auto offset = 0; offset < numSamples; offset += maximumPluginFrames) {
        const auto chunkFrames = std::min(maximumPluginFrames, numSamples - offset);
        processChunk(inputChannelData[0], outputChannelData[0], outputChannelData[1], offset,
                     chunkFrames);
    }
    inputMeter_.publish();
    outputMeter_.publish();

    const auto elapsed =
        std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - started)
            .count();
    const auto previous = callbackTimeEmaMicroseconds_.load(std::memory_order_relaxed);
    const auto next = previous == 0.0 ? elapsed : previous * 0.9 + elapsed * 0.1;
    callbackTimeEmaMicroseconds_.store(next, std::memory_order_relaxed);

    const auto outputStillPermitted =
        outputPermitted_.load(std::memory_order_acquire) &&
        outputGeneration == outputGeneration_.load(std::memory_order_acquire) &&
        configurationIsValid();

#ifndef NDEBUG
    if (callbackEnteredForTesting_ != nullptr && callbackReleaseForTesting_ != nullptr) {
        callbackEnteredForTesting_->store(true, std::memory_order_release);
        while (!callbackReleaseForTesting_->load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
    }
#endif

    if (!outputStillPermitted || !callbackScope.tryCommit()) {
        clearOutputs(outputChannelData, numOutputChannels, framesToClear);
        callbackScope.finishCancelled();
    }
}

bool AudioEngine::prepareProcessing(double sampleRate) {
    workingBuffer_.setSize(2, maximumCallbackFrames, false, true, false);
    workingBuffer_.clear();
    inputMapper_.prepare(maximumCallbackFrames);
    inputMeter_.prepare();
    outputMeter_.prepare();
    outputSafety_.prepare(maximumCallbackFrames);
    masterOutput_.prepare(sampleRate);
    midiBuffer_.clear();
    midiBuffer_.ensureSize(4096);
    if (pluginChain_ != nullptr) {
        const auto result = pluginChain_->prepare(sampleRate, maximumPluginFrames);
        if (!result.succeeded()) {
            return false;
        }
    }
    return true;
}

void AudioEngine::servicePendingStop() noexcept {
    if (status() != EngineStatus::stopping) {
        return;
    }
    if (masterOutput_.isTransportSilent() || std::chrono::steady_clock::now() >= stopDeadline_) {
        completeStop();
    }
}

void AudioEngine::completeStop() noexcept {
    outputPermitted_.store(false, std::memory_order_release);
    running_.store(false, std::memory_order_release);
    if (pluginChain_ != nullptr) {
        pluginChain_->setRunning(false);
    }
    if (deviceService_ != nullptr) {
        deviceService_->stop();
    }
    waitForCallbackQuiescence();
    setStatus(configured_.load(std::memory_order_acquire) ? EngineStatus::configured
                                                          : EngineStatus::stopped);
}

void AudioEngine::waitForCallbackQuiescence() const noexcept {
    while (callbackState_->load(std::memory_order_acquire) != AudioCallbackState::idle) {
        std::this_thread::yield();
    }
}

void AudioEngine::setStatus(EngineStatus status) noexcept {
    status_.store(status, std::memory_order_release);
    (void)eventQueue_.push(
        {.type = CoreEventType::engineStateChanged, .value = static_cast<int>(status)});
}

void AudioEngine::cancelOutput() noexcept {
    outputPermitted_.store(false, std::memory_order_release);
    outputGeneration_.fetch_add(1, std::memory_order_acq_rel);
    auto expected = AudioCallbackState::active;
    (void)callbackState_->compare_exchange_strong(expected, AudioCallbackState::cancelled,
                                                  std::memory_order_acq_rel);
}

void AudioEngine::requestRecovery(AudioErrorCode error) noexcept {
    cancelOutput();
    configured_.store(false, std::memory_order_release);
    if (pluginChain_ != nullptr) {
        pluginChain_->setRunning(false);
    }
    if (deviceService_ != nullptr) {
        deviceService_->invalidateFromCallback();
    }
    auto expected = false;
    if (recoveryPending_.compare_exchange_strong(expected, true, std::memory_order_acq_rel)) {
        (void)eventQueue_.push({.type = CoreEventType::recoveryRequested, .error = error});
    }
}

void AudioEngine::clearOutputs(float* const* channels, int channelCount, int frames) noexcept {
    if (channels == nullptr || frames <= 0) {
        return;
    }
    for (auto channel = 0; channel < channelCount; ++channel) {
        if (channels[channel] != nullptr) {
            juce::FloatVectorOperations::clear(channels[channel], frames);
        }
    }
}

void AudioEngine::processChunk(const float* input, float* leftOutput, float* rightOutput,
                               int offset, int frames) noexcept {
    inputMapper_.mapMonoToDualMono(input + offset, frames, workingBuffer_);
    inputMeter_.accumulate(workingBuffer_, frames);
    if (pluginChain_ != nullptr) {
        pluginChain_->process(workingBuffer_, midiBuffer_, frames);
    }
    outputSafety_.process(workingBuffer_, frames);
    masterOutput_.process(workingBuffer_, frames);
    outputMeter_.accumulate(workingBuffer_, frames);
    juce::FloatVectorOperations::copy(leftOutput + offset, workingBuffer_.getReadPointer(0),
                                      frames);
    juce::FloatVectorOperations::copy(rightOutput + offset, workingBuffer_.getReadPointer(1),
                                      frames);
}

bool AudioEngine::configurationIsValid() const noexcept {
    return configured_.load(std::memory_order_acquire) &&
           (deviceService_ == nullptr || deviceService_->isConfigurationValid());
}

#ifndef NDEBUG
void AudioEngine::prepareForTesting(double sampleRate) {
    static_cast<void>(prepareProcessing(sampleRate));
    configured_.store(true, std::memory_order_release);
    recoveryPending_.store(false, std::memory_order_release);
    outputPermitted_.store(false, std::memory_order_release);
    callbackState_->store(AudioCallbackState::idle, std::memory_order_release);
    callbackInvariantViolation_.store(false, std::memory_order_release);
}

void AudioEngine::setRunningForTesting(bool running) noexcept {
    if (running) {
        masterOutput_.beginStart();
        outputPermitted_.store(true, std::memory_order_release);
    } else {
        masterOutput_.beginStop();
        outputPermitted_.store(false, std::memory_order_release);
    }
    running_.store(running, std::memory_order_release);
    if (pluginChain_ != nullptr) {
        pluginChain_->setRunning(running);
    }
    setStatus(running ? EngineStatus::running : EngineStatus::configured);
}

void AudioEngine::setCallbackBarrierForTesting(std::atomic<bool>* entered,
                                               std::atomic<bool>* release) noexcept {
    callbackEnteredForTesting_ = entered;
    callbackReleaseForTesting_ = release;
}

void AudioEngine::revokeOutputForTesting() noexcept {
    cancelOutput();
}

bool AudioEngine::callbackInvariantViolationForTesting() const noexcept {
    return callbackInvariantViolation_.load(std::memory_order_acquire);
}
#endif

} // namespace shitate
