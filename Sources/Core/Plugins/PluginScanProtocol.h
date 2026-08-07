// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "PluginScanTypes.h"

#include <string>
#include <string_view>

namespace shitate::plugins {

[[nodiscard]] std::string signatureKindName(SignatureKind kind);
[[nodiscard]] bool parseSignatureKind(std::string_view value, SignatureKind& kind);
[[nodiscard]] std::string compatibilityName(PluginCompatibility compatibility);

[[nodiscard]] bool parseScanRequest(std::string_view json, ScanRequest& request,
                                    std::string& errorCode);
[[nodiscard]] std::string serializeScanRequest(const ScanRequest& request);

[[nodiscard]] bool parseScanResult(std::string_view json, ScanResult& result,
                                   std::string& errorCode);
[[nodiscard]] std::string serializeScanResult(const ScanResult& result);

[[nodiscard]] bool isCanonicalUUID(std::string_view value);
[[nodiscard]] bool isHex(std::string_view value, std::size_t minimumLength,
                         std::size_t maximumLength);

} // namespace shitate::plugins
