// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "AudioBridgeController.h"

#include "AudioEngine.h"
#include "DeviceService.h"
#include "RealtimeEventQueue.h"

namespace shitate {

class AudioBridgeController::Impl final {
  public:
    RealtimeEventQueue eventQueue;
    DeviceService deviceService{eventQueue};
    AudioEngine engine{deviceService, eventQueue};
};

AudioBridgeController::AudioBridgeController() : impl_(std::make_unique<Impl>()) {}
AudioBridgeController::~AudioBridgeController() = default;

std::vector<AudioDeviceInfo> AudioBridgeController::enumerateDevices() {
    return impl_->deviceService.enumerateDevices();
}

AudioResult AudioBridgeController::configure(const AudioConfiguration& configuration) {
    return impl_->engine.configure(configuration);
}

AudioResult AudioBridgeController::start() {
    return impl_->engine.start();
}

void AudioBridgeController::stop() noexcept {
    impl_->engine.stop();
}

void AudioBridgeController::failClosed() noexcept {
    impl_->engine.failClosed();
}

void AudioBridgeController::setMasterMuted(bool muted) noexcept {
    impl_->engine.setMasterMuted(muted);
}

EngineStatus AudioBridgeController::status() const noexcept {
    return impl_->engine.status();
}

MeterSnapshot AudioBridgeController::meterSnapshot() const noexcept {
    return impl_->engine.meterSnapshot();
}

EngineDiagnostics AudioBridgeController::diagnostics() const noexcept {
    return impl_->engine.diagnostics();
}

AggregateEvidence AudioBridgeController::activeAggregateEvidence() const {
    return impl_->deviceService.activeAggregateEvidence();
}

bool AudioBridgeController::popEvent(CoreEvent& event) noexcept {
    return impl_->engine.popEvent(event);
}

} // namespace shitate
