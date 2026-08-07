// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "PluginRuntimeTypes.h"

#include <string>

namespace shitate::plugins {

struct PluginLoadJournalEntry final {
    SlotId slotID;
    std::string fingerprint;
    std::string pluginName;
};

class PluginLoadJournal {
  public:
    virtual ~PluginLoadJournal() = default;
    [[nodiscard]] virtual PluginRuntimeResult begin(const PluginLoadJournalEntry& entry) = 0;
    [[nodiscard]] virtual PluginRuntimeResult fail(const PluginLoadJournalEntry& entry,
                                                   PluginRuntimeError cause) = 0;
    [[nodiscard]] virtual PluginRuntimeResult clear() = 0;
};

class FilePluginLoadJournal final : public PluginLoadJournal {
  public:
    explicit FilePluginLoadJournal(std::string filePath);

    [[nodiscard]] PluginRuntimeResult begin(const PluginLoadJournalEntry& entry) override;
    [[nodiscard]] PluginRuntimeResult fail(const PluginLoadJournalEntry& entry,
                                           PluginRuntimeError cause) override;
    [[nodiscard]] PluginRuntimeResult clear() override;

  private:
    [[nodiscard]] PluginRuntimeResult write(std::string json) const;

    std::string filePath_;
};

} // namespace shitate::plugins
