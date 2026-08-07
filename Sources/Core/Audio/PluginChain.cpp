// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "PluginChain.h"

#include <algorithm>
#include <limits>

namespace shitate {

plugins::PluginRuntimeResult PluginChain::prepare(double sampleRate, int maximumBlockSize) {
    if (isRunning()) {
        return plugins::PluginRuntimeResult::failure(
            plugins::PluginRuntimeError::engineRunning,
            "Stop routing before preparing the plug-in chain.");
    }

    prepared_ = false;
    sessionComplete_ = false;
    for (std::size_t index = 0; index < size_; ++index) {
        auto result = slots_[index]->prepare(sampleRate, maximumBlockSize);
        if (!result.succeeded()) {
            for (std::size_t releaseIndex = 0; releaseIndex < size_; ++releaseIndex) {
                slots_[releaseIndex]->releaseResources();
            }
            return result;
        }
    }
    prepared_ = true;
    sessionComplete_ = true;
    return plugins::PluginRuntimeResult::success();
}

void PluginChain::releaseResources() noexcept {
    running_.store(false, std::memory_order_release);
    for (std::size_t index = 0; index < size_; ++index) {
        slots_[index]->releaseResources();
    }
    prepared_ = false;
}

void PluginChain::process(juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi,
                          int frames) noexcept {
    if (!running_.load(std::memory_order_acquire) || !prepared_ || !sessionComplete_) {
        return;
    }
    midi.clear();
    for (std::size_t index = 0; index < size_; ++index) {
        slots_[index]->process(buffer, midi, frames);
    }
}

plugins::PluginRuntimeResult PluginChain::addSlot(std::unique_ptr<HostedPluginSlot> slot) {
    if (slot == nullptr) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::invalidDescriptor,
                                                     "The plug-in slot is invalid.");
    }
    if (auto validation = validateAdd(slot->id()); !validation.succeeded()) {
        return validation;
    }
    slot->setEventKey(allocateEventKey());
    slots_[size_++] = std::move(slot);
    prepared_ = false;
    sessionComplete_ = true;
    return plugins::PluginRuntimeResult::success();
}

plugins::PluginRuntimeResult PluginChain::validateAdd(const plugins::SlotId& id) const noexcept {
    if (isRunning()) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::engineRunning,
                                                     "Stop routing before adding a plug-in slot.");
    }
    if (!id.isValid()) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::invalidDescriptor,
                                                     "The plug-in slot is invalid.");
    }
    if (size_ >= maximumSlots) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::chainFull,
                                                     "The plug-in chain is full.");
    }
    if (indexOf(id) != maximumSlots) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::duplicateSlot,
                                                     "The plug-in slot ID is already present.");
    }
    return plugins::PluginRuntimeResult::success();
}

plugins::PluginRuntimeResult PluginChain::removeSlot(const plugins::SlotId& id) {
    if (isRunning()) {
        return plugins::PluginRuntimeResult::failure(
            plugins::PluginRuntimeError::engineRunning,
            "Stop routing before removing a plug-in slot.");
    }
    std::size_t index = maximumSlots;
    auto removed = takeSlot(id, index);
    if (removed == nullptr) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::slotNotFound,
                                                     "The plug-in slot was not found.");
    }
    removed->releaseResources();
    return plugins::PluginRuntimeResult::success();
}

std::unique_ptr<HostedPluginSlot> PluginChain::takeSlot(const plugins::SlotId& id,
                                                        std::size_t& previousIndex) {
    previousIndex = maximumSlots;
    if (isRunning()) {
        return nullptr;
    }
    const auto index = indexOf(id);
    if (index == maximumSlots) {
        return nullptr;
    }
    previousIndex = index;
    auto removed = std::move(slots_[index]);
    for (auto current = index; current + 1 < size_; ++current) {
        slots_[current] = std::move(slots_[current + 1]);
    }
    slots_[--size_].reset();
    prepared_ = false;
    sessionComplete_ = true;
    return removed;
}

plugins::PluginRuntimeResult PluginChain::insertSlotAt(std::unique_ptr<HostedPluginSlot> slot,
                                                       std::size_t index) {
    if (isRunning()) {
        return plugins::PluginRuntimeResult::failure(
            plugins::PluginRuntimeError::engineRunning,
            "Stop routing before restoring a plug-in slot.");
    }
    if (slot == nullptr || index > size_ || size_ >= maximumSlots ||
        indexOf(slot->id()) != maximumSlots) {
        return plugins::PluginRuntimeResult::failure(
            plugins::PluginRuntimeError::invalidDescriptor,
            "The plug-in slot could not be restored at its previous position.");
    }
    for (auto current = size_; current > index; --current) {
        slots_[current] = std::move(slots_[current - 1]);
    }
    slots_[index] = std::move(slot);
    ++size_;
    prepared_ = false;
    sessionComplete_ = true;
    return plugins::PluginRuntimeResult::success();
}

plugins::PluginRuntimeResult PluginChain::moveSlot(const plugins::SlotId& id,
                                                   std::size_t destinationIndex) {
    if (isRunning()) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::engineRunning,
                                                     "Stop routing before moving a plug-in slot.");
    }
    const auto sourceIndex = indexOf(id);
    if (sourceIndex == maximumSlots) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::slotNotFound,
                                                     "The plug-in slot was not found.");
    }
    if (destinationIndex >= size_) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::invalidMove,
                                                     "The destination slot index is invalid.");
    }
    if (sourceIndex == destinationIndex) {
        return plugins::PluginRuntimeResult::success();
    }

    auto moving = std::move(slots_[sourceIndex]);
    if (sourceIndex < destinationIndex) {
        for (auto index = sourceIndex; index < destinationIndex; ++index) {
            slots_[index] = std::move(slots_[index + 1]);
        }
    } else {
        for (auto index = sourceIndex; index > destinationIndex; --index) {
            slots_[index] = std::move(slots_[index - 1]);
        }
    }
    slots_[destinationIndex] = std::move(moving);
    return plugins::PluginRuntimeResult::success();
}

plugins::PluginRuntimeResult PluginChain::setBypassed(const plugins::SlotId& id,
                                                      bool bypassed) noexcept {
    auto* value = slot(id);
    if (value == nullptr) {
        return plugins::PluginRuntimeResult::failure(plugins::PluginRuntimeError::slotNotFound,
                                                     "The plug-in slot was not found.");
    }
    value->setBypassed(bypassed);
    return plugins::PluginRuntimeResult::success();
}

void PluginChain::setRunning(bool running) noexcept {
    running_.store(running && prepared_ && sessionComplete_, std::memory_order_release);
}

bool PluginChain::isRunning() const noexcept {
    return running_.load(std::memory_order_acquire);
}

bool PluginChain::isPrepared() const noexcept {
    return prepared_;
}

bool PluginChain::isSessionComplete() const noexcept {
    return sessionComplete_;
}

std::size_t PluginChain::size() const noexcept {
    return size_;
}

int PluginChain::totalLatencySamples() const noexcept {
    int total = 0;
    for (std::size_t index = 0; index < size_; ++index) {
        const auto latency = slots_[index]->latencySamples();
        if (latency > std::numeric_limits<int>::max() - total) {
            return std::numeric_limits<int>::max();
        }
        total += latency;
    }
    return total;
}

HostedPluginSlot* PluginChain::slot(const plugins::SlotId& id) noexcept {
    const auto index = indexOf(id);
    return index == maximumSlots ? nullptr : slots_[index].get();
}

const HostedPluginSlot* PluginChain::slot(const plugins::SlotId& id) const noexcept {
    const auto index = indexOf(id);
    return index == maximumSlots ? nullptr : slots_[index].get();
}

const HostedPluginSlot* PluginChain::slotForEventKey(int eventKey) const noexcept {
    for (std::size_t index = 0; index < size_; ++index) {
        if (slots_[index]->eventKey() == eventKey) {
            return slots_[index].get();
        }
    }
    return nullptr;
}

std::vector<PluginSlotSnapshot> PluginChain::snapshots() const {
    std::vector<PluginSlotSnapshot> result;
    result.reserve(size_);
    for (std::size_t index = 0; index < size_; ++index) {
        const auto* current = slots_[index].get();
        result.push_back({.slotID = current->id(),
                          .identity = current->identity(),
                          .bypassed = current->isBypassed(),
                          .faulted = current->hasRuntimeFault(),
                          .latencySamples = current->latencySamples(),
                          .eventKey = current->eventKey()});
    }
    return result;
}

std::size_t PluginChain::indexOf(const plugins::SlotId& id) const noexcept {
    for (std::size_t index = 0; index < size_; ++index) {
        if (slots_[index]->id() == id) {
            return index;
        }
    }
    return maximumSlots;
}

int PluginChain::allocateEventKey() noexcept {
    if (nextEventKey_ <= 0) {
        nextEventKey_ = 1;
    }
    return nextEventKey_++;
}

} // namespace shitate
