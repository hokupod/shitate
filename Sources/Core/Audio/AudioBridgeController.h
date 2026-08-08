// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "AudioTypes.h"
#include "PluginChainTypes.h"
#include "Plugins/PluginRuntimeTypes.h"
#include "Plugins/PluginScanTypes.h"

#include <memory>
#include <optional>
#include <vector>

namespace shitate {

namespace plugins {
class PluginLoadJournal;
}

class AudioBridgeController final {
  public:
    AudioBridgeController();
    explicit AudioBridgeController(std::shared_ptr<plugins::PluginLoadJournal> loadJournal);
    ~AudioBridgeController();

    AudioBridgeController(const AudioBridgeController&) = delete;
    AudioBridgeController& operator=(const AudioBridgeController&) = delete;

    [[nodiscard]] std::vector<AudioDeviceInfo> enumerateDevices();
    [[nodiscard]] std::optional<AudioDeviceInfo> defaultOutputDevice();
    [[nodiscard]] AudioResult configure(const AudioConfiguration& configuration);
    [[nodiscard]] AudioResult start();
    void stop() noexcept;
    void failClosed() noexcept;
    /// Terminal shutdown. Call only when the controller will no longer be used.
    void shutdown() noexcept;
    void setMasterMuted(bool muted) noexcept;

    [[nodiscard]] plugins::PluginRuntimeResult
    validatePluginAdd(const plugins::SlotId& slotID) const noexcept;
    [[nodiscard]] plugins::PluginRuntimeResult addPlugin(const plugins::CatalogEntry& entry,
                                                         const plugins::SlotId& slotID,
                                                         const void* stateData = nullptr,
                                                         std::size_t stateSize = 0);
    [[nodiscard]] plugins::PluginRuntimeResult removePlugin(const plugins::SlotId& slotID);
    [[nodiscard]] plugins::PluginRuntimeResult movePlugin(const plugins::SlotId& slotID,
                                                          std::size_t destinationIndex);
    [[nodiscard]] plugins::PluginRuntimeResult setPluginBypassed(const plugins::SlotId& slotID,
                                                                 bool bypassed) noexcept;
    [[nodiscard]] SerializedPluginState serializePluginState(const plugins::SlotId& slotID);
    [[nodiscard]] plugins::PluginRuntimeResult
    restorePluginState(const plugins::SlotId& slotID, const void* data, std::size_t size);
    [[nodiscard]] plugins::PluginRuntimeResult openPluginEditor(const plugins::SlotId& slotID);
    [[nodiscard]] plugins::PluginRuntimeResult closePluginEditor(const plugins::SlotId& slotID);
    void closeAllPluginEditors() noexcept;
    [[nodiscard]] std::vector<PluginSlotSnapshot> pluginSlots() const;
    [[nodiscard]] std::optional<plugins::SlotId> slotIDForEventKey(int eventKey) const;

    [[nodiscard]] EngineStatus status() const noexcept;
    [[nodiscard]] MeterSnapshot meterSnapshot() const noexcept;
    [[nodiscard]] EngineDiagnostics diagnostics() const noexcept;
    [[nodiscard]] AggregateEvidence activeAggregateEvidence() const;
    [[nodiscard]] bool popEvent(CoreEvent& event) noexcept;

  private:
    class Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace shitate
