// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "PluginScanTypes.h"

#include <string>

namespace shitate::plugins {

enum class SignaturePolicyDecision {
    allow,
    requireExplicitApproval,
    reject,
};

class SignatureInspector {
  public:
    virtual ~SignatureInspector() = default;
    [[nodiscard]] virtual SignatureInfo inspect(const std::string& bundlePath) const noexcept = 0;
};

class PluginSignatureVerifier final : public SignatureInspector {
  public:
    [[nodiscard]] SignatureInfo inspect(const std::string& bundlePath) const noexcept override;
};

[[nodiscard]] SignaturePolicyDecision evaluateSignaturePolicy(const SignatureInfo& info,
                                                              bool fingerprintApproved);
[[nodiscard]] bool supportsRequiredArchitecture(const SignatureInfo& info);

} // namespace shitate::plugins
