// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "PluginScanTypes.h"

#include <set>
#include <string>
#include <vector>

namespace shitate::plugins {

[[nodiscard]] std::string pluginFingerprint(const std::string& canonicalPath,
                                            const std::string& classUID,
                                            const std::string& codeDirectoryHash,
                                            const std::string& architecture);

class PluginCatalog final {
  public:
    [[nodiscard]] bool replaceBundle(const ScanResult& result,
                                     const std::set<std::string>& approvedAdHocFingerprints,
                                     const std::string& scannedAt);
    [[nodiscard]] bool hasValidCache(const std::string& canonicalPath,
                                     const std::string& codeDirectoryHash,
                                     std::int64_t modificationTime, int protocolVersion,
                                     const std::string& compatibleAppVersion) const;
    void removeStalePaths(const std::set<std::string>& currentCanonicalPaths);

    [[nodiscard]] const std::vector<CatalogEntry>& entries() const noexcept;
    void clear() noexcept;

  private:
    std::vector<CatalogEntry> entries_;
};

} // namespace shitate::plugins
