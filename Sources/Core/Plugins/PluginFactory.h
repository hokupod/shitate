// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "PluginLoadJournal.h"
#include "PluginScanTypes.h"
#include "PluginSignatureVerifier.h"

#include <juce_audio_processors/juce_audio_processors.h>
#include <memory>
#include <string>

namespace shitate {
class HostedPluginSlot;
class RealtimeEventQueue;
} // namespace shitate

namespace shitate::plugins {

struct PluginInstanceResult final {
    PluginRuntimeResult result;
    std::unique_ptr<juce::AudioProcessor> instance;
};

class PluginInstanceCreator {
  public:
    virtual ~PluginInstanceCreator() = default;
    [[nodiscard]] virtual PluginInstanceResult create(const CatalogEntry& entry) = 0;
};

class JuceVST3PluginInstanceCreator final : public PluginInstanceCreator {
  public:
    [[nodiscard]] PluginInstanceResult create(const CatalogEntry& entry) override;
};

struct PluginCreationResult final {
    PluginRuntimeResult result;
    std::unique_ptr<HostedPluginSlot> slot;
};

class PluginFactory final {
  public:
    PluginFactory(RealtimeEventQueue& eventQueue,
                  std::shared_ptr<const SignatureInspector> signatureInspector,
                  std::shared_ptr<PluginInstanceCreator> instanceCreator,
                  std::shared_ptr<PluginLoadJournal> loadJournal);

    [[nodiscard]] PluginCreationResult create(const CatalogEntry& entry, SlotId slotID,
                                              const void* stateData = nullptr,
                                              std::size_t stateSize = 0) const;

  private:
    [[nodiscard]] PluginRuntimeResult validateIdentity(const CatalogEntry& entry,
                                                       SignatureInfo& liveIdentity) const;

    RealtimeEventQueue& eventQueue_;
    std::shared_ptr<const SignatureInspector> signatureInspector_;
    std::shared_ptr<PluginInstanceCreator> instanceCreator_;
    std::shared_ptr<PluginLoadJournal> loadJournal_;
};

} // namespace shitate::plugins
