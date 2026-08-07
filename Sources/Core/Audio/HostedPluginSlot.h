// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "AudioTypes.h"
#include "PluginChainTypes.h"
#include "Plugins/PluginRuntimeTypes.h"
#include "Plugins/PluginScanTypes.h"

#include <atomic>
#include <cstddef>
#include <juce_audio_processors/juce_audio_processors.h>
#include <memory>

namespace shitate {

class RealtimeEventQueue;

class HostedPluginSlot final {
  public:
    static constexpr std::size_t maximumStateBytes = 4U * 1024U * 1024U;

    HostedPluginSlot(plugins::SlotId id, plugins::CatalogEntry identity,
                     std::unique_ptr<juce::AudioProcessor> processor,
                     RealtimeEventQueue& eventQueue);
    ~HostedPluginSlot();

    HostedPluginSlot(const HostedPluginSlot&) = delete;
    HostedPluginSlot& operator=(const HostedPluginSlot&) = delete;

    [[nodiscard]] const plugins::SlotId& id() const noexcept;
    [[nodiscard]] const plugins::CatalogEntry& identity() const noexcept;
    [[nodiscard]] plugins::PluginRuntimeResult prepare(double sampleRate, int maximumBlockSize);
    void process(juce::AudioBuffer<float>& buffer, juce::MidiBuffer& midi, int frames) noexcept;
    void releaseResources() noexcept;
    void setBypassed(bool bypassed) noexcept;
    [[nodiscard]] bool isBypassed() const noexcept;
    [[nodiscard]] bool hasRuntimeFault() const noexcept;
    void clearRuntimeFault() noexcept;
    [[nodiscard]] int latencySamples() const noexcept;
    [[nodiscard]] bool hasEditor() const noexcept;
    [[nodiscard]] juce::AudioProcessorEditor* createEditorIfNeeded();
    [[nodiscard]] SerializedPluginState serializeState();
    [[nodiscard]] plugins::PluginRuntimeResult restoreState(const void* data, std::size_t size);
    [[nodiscard]] plugins::PluginRuntimeResult setParameterNormalized(int parameterIndex,
                                                                      float value);
    void setEventKey(int key) noexcept;
    [[nodiscard]] int eventKey() const noexcept;

  private:
    [[nodiscard]] bool outputIsFinite(const juce::AudioBuffer<float>& buffer,
                                      int frames) const noexcept;
    void restoreBackup(juce::AudioBuffer<float>& buffer, int frames) noexcept;
    void markFault() noexcept;

    const plugins::SlotId id_;
    const plugins::CatalogEntry identity_;
    std::unique_ptr<juce::AudioProcessor> processor_;
    RealtimeEventQueue& eventQueue_;
    juce::AudioBuffer<float> backup_;
    std::atomic<bool> bypassed_{false};
    std::atomic<bool> faulted_{false};
    std::atomic<bool> faultEventSent_{false};
    std::atomic<int> eventKey_{0};
    std::atomic<int> latencySamples_{0};
    bool prepared_{false};
};

static_assert(std::atomic<bool>::is_always_lock_free);
static_assert(std::atomic<int>::is_always_lock_free);

} // namespace shitate
