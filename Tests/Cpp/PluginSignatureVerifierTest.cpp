// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Plugins/PluginSignatureVerifier.h"

#include <juce_core/juce_core.h>

namespace {

using namespace shitate::plugins;

[[nodiscard]] SignatureInfo signature(SignatureKind kind,
                                      std::vector<std::string> architectures = {"arm64"}) {
    SignatureInfo info;
    info.kind = kind;
    info.architectures = std::move(architectures);
    return info;
}

class PluginSignatureVerifierTest final : public juce::UnitTest {
  public:
    PluginSignatureVerifierTest() : UnitTest("PluginSignatureVerifier", "Shitate") {}

    void runTest() override {
        beginTest("valid Apple and Developer ID signatures are allowed");
        expect(evaluateSignaturePolicy(signature(SignatureKind::apple), false) ==
               SignaturePolicyDecision::allow);
        expect(evaluateSignaturePolicy(signature(SignatureKind::developerID), false) ==
               SignaturePolicyDecision::allow);

        beginTest("ad-hoc approval is exact and explicit");
        expect(evaluateSignaturePolicy(signature(SignatureKind::adHoc), false) ==
               SignaturePolicyDecision::requireExplicitApproval);
        expect(evaluateSignaturePolicy(signature(SignatureKind::adHoc), true) ==
               SignaturePolicyDecision::allow);

        beginTest("unsigned, invalid, and Intel-only signatures reject");
        expect(evaluateSignaturePolicy(signature(SignatureKind::unsignedCode), true) ==
               SignaturePolicyDecision::reject);
        expect(evaluateSignaturePolicy(signature(SignatureKind::invalid), true) ==
               SignaturePolicyDecision::reject);
        expect(evaluateSignaturePolicy(signature(SignatureKind::developerID, {"x86_64"}), true) ==
               SignaturePolicyDecision::reject);

        beginTest("Security.framework errors expose stable redacted codes");
        const PluginSignatureVerifier verifier;
        const auto inspected = verifier.inspect("/private/tmp/not-a-secret-name.vst3");
        expect(inspected.kind == SignatureKind::invalid ||
               inspected.kind == SignatureKind::unsignedCode);
        expect(!inspected.errorCode.empty());
        expect(inspected.errorCode.find("/private/") == std::string::npos);
    }
};

PluginSignatureVerifierTest pluginSignatureVerifierTest;

} // namespace
