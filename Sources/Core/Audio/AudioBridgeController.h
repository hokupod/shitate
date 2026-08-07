// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "AudioTypes.h"

#include <memory>
#include <vector>

namespace shitate {

class AudioBridgeController final {
  public:
    AudioBridgeController();
    ~AudioBridgeController();

    AudioBridgeController(const AudioBridgeController&) = delete;
    AudioBridgeController& operator=(const AudioBridgeController&) = delete;

    [[nodiscard]] std::vector<AudioDeviceInfo> enumerateDevices();
    [[nodiscard]] AudioResult configure(const AudioConfiguration& configuration);
    [[nodiscard]] AudioResult start();
    void stop() noexcept;
    void failClosed() noexcept;
    void setMasterMuted(bool muted) noexcept;

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
