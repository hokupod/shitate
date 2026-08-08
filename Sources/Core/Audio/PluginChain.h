// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "HostedPluginSlot.h"
#include "PluginChainTypes.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <memory>
#include <vector>

namespace shitate {

class PluginChain final {
  public:
    static constexpr std::size_t maximumSlots = 8;

    [[nodiscard]] plugins::PluginRuntimeResult prepare(double sampleRate = requiredSampleRate,
                                                       int maximumBlockSize = maximumPluginFrames);
    void releaseResources() noexcept;
    /// The caller must stop routing and wait for every process callback before calling this.
    void clearAfterCallbackQuiescence() noexcept;
    void process(juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi, int frames) noexcept;
    [[nodiscard]] plugins::PluginRuntimeResult
    validateAdd(const plugins::SlotId& id) const noexcept;
    [[nodiscard]] plugins::PluginRuntimeResult addSlot(std::unique_ptr<HostedPluginSlot> slot);
    [[nodiscard]] plugins::PluginRuntimeResult removeSlot(const plugins::SlotId& id);
    [[nodiscard]] std::unique_ptr<HostedPluginSlot> takeSlot(const plugins::SlotId& id,
                                                             std::size_t& previousIndex);
    [[nodiscard]] plugins::PluginRuntimeResult insertSlotAt(std::unique_ptr<HostedPluginSlot> slot,
                                                            std::size_t index);
    [[nodiscard]] plugins::PluginRuntimeResult moveSlot(const plugins::SlotId& id,
                                                        std::size_t destinationIndex);
    [[nodiscard]] plugins::PluginRuntimeResult setBypassed(const plugins::SlotId& id,
                                                           bool bypassed) noexcept;
    void setRunning(bool running) noexcept;

    [[nodiscard]] bool isRunning() const noexcept;
    [[nodiscard]] bool isPrepared() const noexcept;
    [[nodiscard]] bool isSessionComplete() const noexcept;
    [[nodiscard]] std::size_t size() const noexcept;
    [[nodiscard]] int totalLatencySamples() const noexcept;
    [[nodiscard]] HostedPluginSlot* slot(const plugins::SlotId& id) noexcept;
    [[nodiscard]] const HostedPluginSlot* slot(const plugins::SlotId& id) const noexcept;
    [[nodiscard]] const HostedPluginSlot* slotForEventKey(int eventKey) const noexcept;
    [[nodiscard]] std::vector<PluginSlotSnapshot> snapshots() const;

  private:
    [[nodiscard]] std::size_t indexOf(const plugins::SlotId& id) const noexcept;
    [[nodiscard]] int allocateEventKey() noexcept;

    std::array<std::unique_ptr<HostedPluginSlot>, maximumSlots> slots_{};
    std::size_t size_{0};
    std::atomic<bool> running_{false};
    bool prepared_{false};
    bool sessionComplete_{true};
    int nextEventKey_{1};
};

} // namespace shitate
