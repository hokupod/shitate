// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "HostedPluginSlot.h"

#include "RealtimeEventQueue.h"

#include <algorithm>
#include <cmath>

namespace shitate {

HostedPluginSlot::HostedPluginSlot(plugins::SlotId id, plugins::CatalogEntry identity,
                                   std::unique_ptr<juce::AudioProcessor> processor,
                                   RealtimeEventQueue& eventQueue)
    : id_(id), identity_(std::move(identity)), processor_(std::move(processor)),
      eventQueue_(eventQueue), backup_(plugins::requiredOutputChannels, maximumPluginFrames) {
    backup_.clear();
}

HostedPluginSlot::~HostedPluginSlot() {
    releaseResources();
}

const plugins::SlotId& HostedPluginSlot::id() const noexcept {
    return id_;
}

const plugins::CatalogEntry& HostedPluginSlot::identity() const noexcept {
    return identity_;
}

plugins::PluginRuntimeResult HostedPluginSlot::prepare(double sampleRate, int maximumBlockSize) {
    if (processor_ == nullptr || sampleRate != requiredSampleRate ||
        maximumBlockSize != maximumPluginFrames) {
        return plugins::PluginRuntimeResult::failure(
            plugins::PluginRuntimeError::prepareFailed,
            "The plug-in runtime format does not match the v0.1 contract.");
    }
    try {
        if (prepared_) {
            processor_->releaseResources();
        }
        processor_->setNonRealtime(false);
        processor_->setRateAndBufferSizeDetails(sampleRate, maximumBlockSize);
        processor_->prepareToPlay(sampleRate, maximumBlockSize);
        latencySamples_.store(std::max(0, processor_->getLatencySamples()),
                              std::memory_order_release);
        prepared_ = true;
        return plugins::PluginRuntimeResult::success();
    } catch (...) {
        prepared_ = false;
        latencySamples_.store(0, std::memory_order_release);
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::prepareFailed,
                                                     "The plug-in could not be prepared.");
    }
}

void HostedPluginSlot::process(juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi,
                               int frames) noexcept {
    if (!prepared_ || processor_ == nullptr || bypassed_.load(std::memory_order_relaxed) ||
        faulted_.load(std::memory_order_relaxed)) {
        return;
    }
    if (buffer.getNumChannels() < plugins::requiredOutputChannels || frames <= 0 ||
        frames > maximumPluginFrames || buffer.getNumSamples() < frames) {
        markFault();
        return;
    }

    for (int channel = 0; channel < plugins::requiredOutputChannels; ++channel) {
        juce::FloatVectorOperations::copy(backup_.getWritePointer(channel),
                                          buffer.getReadPointer(channel), frames);
    }

    std::array<float*, plugins::requiredOutputChannels> channels{
        buffer.getWritePointer(0),
        buffer.getWritePointer(1),
    };
    juce::AudioBuffer<float> view(channels.data(), static_cast<int>(channels.size()), frames);
    try {
        processor_->processBlock(view, midi);
    } catch (...) {
        restoreBackup(buffer, frames);
        markFault();
        return;
    }
    if (!outputIsFinite(buffer, frames)) {
        restoreBackup(buffer, frames);
        markFault();
    }
}

void HostedPluginSlot::releaseResources() noexcept {
    if (processor_ != nullptr && prepared_) {
        try {
            processor_->releaseResources();
        } catch (...) {
        }
    }
    prepared_ = false;
    latencySamples_.store(0, std::memory_order_release);
}

void HostedPluginSlot::setBypassed(bool bypassed) noexcept {
    bypassed_.store(bypassed, std::memory_order_release);
}

bool HostedPluginSlot::isBypassed() const noexcept {
    return bypassed_.load(std::memory_order_acquire);
}

bool HostedPluginSlot::hasRuntimeFault() const noexcept {
    return faulted_.load(std::memory_order_acquire);
}

void HostedPluginSlot::clearRuntimeFault() noexcept {
    faulted_.store(false, std::memory_order_release);
    faultEventSent_.store(false, std::memory_order_release);
}

int HostedPluginSlot::latencySamples() const noexcept {
    return latencySamples_.load(std::memory_order_acquire);
}

bool HostedPluginSlot::hasEditor() const noexcept {
    return processor_ != nullptr && processor_->hasEditor();
}

juce::AudioProcessorEditor* HostedPluginSlot::createEditorIfNeeded() {
    if (processor_ == nullptr || !processor_->hasEditor()) {
        return nullptr;
    }
    return processor_->createEditorAndMakeActive();
}

SerializedPluginState HostedPluginSlot::serializeState() {
    SerializedPluginState state;
    if (processor_ == nullptr) {
        state.result = plugins::PluginRuntimeResult::failure(
            plugins::PluginRuntimeError::stateInvalid, "The plug-in state is unavailable.");
        return state;
    }
    try {
        juce::MemoryBlock data;
        processor_->getStateInformation(data);
        if (data.getSize() > maximumStateBytes) {
            state.result = plugins::PluginRuntimeResult::failure(
                plugins::PluginRuntimeError::stateInvalid, "The plug-in state is too large.");
            return state;
        }
        if (data.getSize() > 0) {
            const auto* bytes = static_cast<const std::uint8_t*>(data.getData());
            state.data.assign(bytes, bytes + data.getSize());
        }
        state.result = plugins::PluginRuntimeResult::success();
        return state;
    } catch (...) {
        state.data.clear();
        state.result = plugins::PluginRuntimeResult::failure(
            plugins::PluginRuntimeError::stateInvalid, "The plug-in state could not be saved.");
        return state;
    }
}

plugins::PluginRuntimeResult HostedPluginSlot::restoreState(const void* data, std::size_t size) {
    if (processor_ == nullptr || (data == nullptr && size != 0) || size > maximumStateBytes) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::stateInvalid,
                                                     "The plug-in state is invalid.");
    }
    try {
        processor_->setStateInformation(data, static_cast<int>(size));
        return plugins::PluginRuntimeResult::success();
    } catch (...) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::stateInvalid,
                                                     "The plug-in state could not be restored.");
    }
}

plugins::PluginRuntimeResult HostedPluginSlot::setParameterNormalized(int parameterIndex,
                                                                      float value) {
    if (processor_ == nullptr || parameterIndex < 0 || !std::isfinite(value) || value < 0.0F ||
        value > 1.0F) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::stateInvalid,
                                                     "The plug-in parameter value is invalid.");
    }
    auto& parameters = processor_->getParameters();
    if (parameterIndex >= parameters.size() || parameters[parameterIndex] == nullptr) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::stateInvalid,
                                                     "The plug-in parameter is unavailable.");
    }
    try {
        parameters[parameterIndex]->beginChangeGesture();
        parameters[parameterIndex]->setValueNotifyingHost(value);
        parameters[parameterIndex]->endChangeGesture();
        return plugins::PluginRuntimeResult::success();
    } catch (...) {
        return plugins::PluginRuntimeResult::failure(
            plugins::PluginRuntimeError::stateInvalid,
            "The plug-in parameter could not be changed safely.");
    }
}

void HostedPluginSlot::setEventKey(int key) noexcept {
    eventKey_.store(key, std::memory_order_release);
}

int HostedPluginSlot::eventKey() const noexcept {
    return eventKey_.load(std::memory_order_acquire);
}

bool HostedPluginSlot::outputIsFinite(const juce::AudioBuffer<float>& buffer,
                                      int frames) const noexcept {
    for (int channel = 0; channel < plugins::requiredOutputChannels; ++channel) {
        const auto* samples = buffer.getReadPointer(channel);
        for (int frame = 0; frame < frames; ++frame) {
            if (!std::isfinite(samples[frame])) {
                return false;
            }
        }
    }
    return true;
}

void HostedPluginSlot::restoreBackup(juce::AudioBuffer<float>& buffer, int frames) noexcept {
    for (int channel = 0; channel < plugins::requiredOutputChannels; ++channel) {
        juce::FloatVectorOperations::copy(buffer.getWritePointer(channel),
                                          backup_.getReadPointer(channel), frames);
    }
}

void HostedPluginSlot::markFault() noexcept {
    faulted_.store(true, std::memory_order_release);
    if (!faultEventSent_.exchange(true, std::memory_order_acq_rel)) {
        static_cast<void>(eventQueue_.push({.type = CoreEventType::pluginSlotFaulted,
                                            .value = eventKey_.load(std::memory_order_acquire)}));
    }
}

} // namespace shitate
