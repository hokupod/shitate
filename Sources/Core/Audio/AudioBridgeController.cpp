// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "AudioBridgeController.h"

#include "AudioEngine.h"
#include "DeviceService.h"
#include "HostedPluginSlot.h"
#include "PluginChain.h"
#include "Plugins/PluginEditorWindowManager.h"
#include "Plugins/PluginFactory.h"
#include "RealtimeEventQueue.h"

#include <algorithm>
#include <iterator>
#include <juce_gui_basics/juce_gui_basics.h>
#include <utility>

namespace shitate {

class AudioBridgeController::Impl final {
  public:
    explicit Impl(std::shared_ptr<plugins::PluginLoadJournal> loadJournal)
        : factory(eventQueue, std::make_shared<plugins::PluginSignatureVerifier>(),
                  std::make_shared<plugins::JuceVST3PluginInstanceCreator>(),
                  std::move(loadJournal)),
          engine(deviceService, eventQueue, &pluginChain) {}

    ~Impl() {
        engine.failClosed();
        editorWindows.closeAll();
        pluginChain.releaseResources();
    }

    juce::ScopedJuceInitialiser_GUI guiInitialiser;
    RealtimeEventQueue eventQueue;
    DeviceService deviceService{eventQueue};
    PluginChain pluginChain;
    plugins::PluginFactory factory;
    plugins::PluginEditorWindowManager editorWindows;
    AudioEngine engine;
};

AudioBridgeController::AudioBridgeController() : AudioBridgeController(nullptr) {}
AudioBridgeController::AudioBridgeController(
    std::shared_ptr<plugins::PluginLoadJournal> loadJournal)
    : impl_(std::make_unique<Impl>(std::move(loadJournal))) {}
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

plugins::PluginRuntimeResult
AudioBridgeController::validatePluginAdd(const plugins::SlotId& slotID) const noexcept {
    if (impl_->engine.isRunning() || impl_->engine.status() == EngineStatus::stopping) {
        return plugins::PluginRuntimeResult::failure(
            plugins::PluginRuntimeError::engineRunning,
            "Stop routing before changing the plug-in chain.");
    }
    return impl_->pluginChain.validateAdd(slotID);
}

plugins::PluginRuntimeResult AudioBridgeController::addPlugin(const plugins::CatalogEntry& entry,
                                                              const plugins::SlotId& slotID,
                                                              const void* stateData,
                                                              std::size_t stateSize) {
    if (auto validation = validatePluginAdd(slotID); !validation.succeeded()) {
        return validation;
    }
    auto created = impl_->factory.create(entry, slotID, stateData, stateSize);
    if (!created.result.succeeded()) {
        return created.result;
    }
    if (auto added = impl_->pluginChain.addSlot(std::move(created.slot)); !added.succeeded()) {
        return added;
    }
    if (auto prepared = impl_->pluginChain.prepare(); !prepared.succeeded()) {
        std::size_t index = PluginChain::maximumSlots;
        auto failedSlot = impl_->pluginChain.takeSlot(slotID, index);
        failedSlot.reset();
        static_cast<void>(impl_->pluginChain.prepare());
        return prepared;
    }
    return plugins::PluginRuntimeResult::success();
}

plugins::PluginRuntimeResult AudioBridgeController::removePlugin(const plugins::SlotId& slotID) {
    if (impl_->engine.isRunning() || impl_->engine.status() == EngineStatus::stopping) {
        return plugins::PluginRuntimeResult::failure(
            plugins::PluginRuntimeError::engineRunning,
            "Stop routing before changing the plug-in chain.");
    }
    if (auto closed = impl_->editorWindows.close(slotID); !closed.succeeded()) {
        return closed;
    }
    std::size_t previousIndex = PluginChain::maximumSlots;
    auto removed = impl_->pluginChain.takeSlot(slotID, previousIndex);
    if (removed == nullptr) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::slotNotFound,
                                                     "The plug-in slot was not found.");
    }
    if (auto prepared = impl_->pluginChain.prepare(); !prepared.succeeded()) {
        static_cast<void>(impl_->pluginChain.insertSlotAt(std::move(removed), previousIndex));
        static_cast<void>(impl_->pluginChain.prepare());
        return prepared;
    }
    return plugins::PluginRuntimeResult::success();
}

plugins::PluginRuntimeResult AudioBridgeController::movePlugin(const plugins::SlotId& slotID,
                                                               std::size_t destinationIndex) {
    if (impl_->engine.isRunning() || impl_->engine.status() == EngineStatus::stopping) {
        return plugins::PluginRuntimeResult::failure(
            plugins::PluginRuntimeError::engineRunning,
            "Stop routing before changing the plug-in chain.");
    }
    const auto snapshots = impl_->pluginChain.snapshots();
    const auto previous = std::find_if(snapshots.begin(), snapshots.end(),
                                       [&](const auto& value) { return value.slotID == slotID; });
    if (previous == snapshots.end()) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::slotNotFound,
                                                     "The plug-in slot was not found.");
    }
    const auto previousIndex = static_cast<std::size_t>(std::distance(snapshots.begin(), previous));
    if (auto moved = impl_->pluginChain.moveSlot(slotID, destinationIndex); !moved.succeeded()) {
        return moved;
    }
    if (auto prepared = impl_->pluginChain.prepare(); !prepared.succeeded()) {
        static_cast<void>(impl_->pluginChain.moveSlot(slotID, previousIndex));
        static_cast<void>(impl_->pluginChain.prepare());
        return prepared;
    }
    return plugins::PluginRuntimeResult::success();
}

plugins::PluginRuntimeResult AudioBridgeController::setPluginBypassed(const plugins::SlotId& slotID,
                                                                      bool bypassed) noexcept {
    return impl_->pluginChain.setBypassed(slotID, bypassed);
}

SerializedPluginState AudioBridgeController::serializePluginState(const plugins::SlotId& slotID) {
    if (impl_->engine.isRunning() || impl_->engine.status() == EngineStatus::stopping) {
        return {.result = plugins::PluginRuntimeResult::failure(
                    plugins::PluginRuntimeError::engineRunning,
                    "Saving plug-in state requires an explicit routing interruption.")};
    }
    auto* slot = impl_->pluginChain.slot(slotID);
    if (slot == nullptr) {
        return {.result = plugins::PluginRuntimeResult::failure(
                    plugins::PluginRuntimeError::slotNotFound, "The plug-in slot was not found.")};
    }
    return slot->serializeState();
}

plugins::PluginRuntimeResult
AudioBridgeController::restorePluginState(const plugins::SlotId& slotID, const void* data,
                                          std::size_t size) {
    if (impl_->engine.isRunning() || impl_->engine.status() == EngineStatus::stopping) {
        return plugins::PluginRuntimeResult::failure(
            plugins::PluginRuntimeError::engineRunning,
            "Restoring plug-in state requires stopped routing.");
    }
    auto* slot = impl_->pluginChain.slot(slotID);
    if (slot == nullptr) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::slotNotFound,
                                                     "The plug-in slot was not found.");
    }
    const auto previous = slot->serializeState();
    if (!previous.result.succeeded()) {
        return previous.result;
    }
    impl_->pluginChain.releaseResources();
    if (auto restored = slot->restoreState(data, size); !restored.succeeded()) {
        static_cast<void>(slot->restoreState(previous.data.data(), previous.data.size()));
        static_cast<void>(impl_->pluginChain.prepare());
        return restored;
    }
    if (auto prepared = impl_->pluginChain.prepare(); !prepared.succeeded()) {
        static_cast<void>(slot->restoreState(previous.data.data(), previous.data.size()));
        static_cast<void>(impl_->pluginChain.prepare());
        return prepared;
    }
    return plugins::PluginRuntimeResult::success();
}

plugins::PluginRuntimeResult
AudioBridgeController::openPluginEditor(const plugins::SlotId& slotID) {
    auto* slot = impl_->pluginChain.slot(slotID);
    if (slot == nullptr) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::slotNotFound,
                                                     "The plug-in slot was not found.");
    }
    return impl_->editorWindows.open(*slot);
}

plugins::PluginRuntimeResult
AudioBridgeController::closePluginEditor(const plugins::SlotId& slotID) {
    return impl_->editorWindows.close(slotID);
}

void AudioBridgeController::closeAllPluginEditors() noexcept {
    impl_->editorWindows.closeAll();
}

std::vector<PluginSlotSnapshot> AudioBridgeController::pluginSlots() const {
    return impl_->pluginChain.snapshots();
}

std::optional<plugins::SlotId> AudioBridgeController::slotIDForEventKey(int eventKey) const {
    const auto* slot = impl_->pluginChain.slotForEventKey(eventKey);
    return slot != nullptr ? std::optional<plugins::SlotId>{slot->id()} : std::nullopt;
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
