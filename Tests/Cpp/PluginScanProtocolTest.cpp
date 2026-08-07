// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Plugins/PluginScanProtocol.h"

#include <juce_core/juce_core.h>

namespace {

using namespace shitate::plugins;

[[nodiscard]] ScanRequest requestFixture() {
    ScanRequest request;
    request.requestID = "01234567-89ab-cdef-0123-456789abcdef";
    request.pluginBundlePath = "/Library/Audio/Plug-Ins/VST3/Test.vst3";
    request.expectedCodeDirectoryHash = "0123456789abcdef0123456789abcdef01234567";
    return request;
}

[[nodiscard]] ScanResult resultFixture() {
    ScanResult result;
    result.requestID = requestFixture().requestID;
    result.status = "compatible";
    result.bundle.path = requestFixture().pluginBundlePath;
    result.bundle.codeDirectoryHash = requestFixture().expectedCodeDirectoryHash;
    result.bundle.teamIdentifier = "TEAMID";
    result.bundle.signatureKind = SignatureKind::developerID;
    result.bundle.architectures = {"arm64"};
    result.bundle.modificationTime = 42;
    result.bundle.bundleVersion = "1.0.0";
    ScannedPlugin plugin;
    plugin.classUID = "1234abcd1234abcd1234abcd1234abcd";
    plugin.name = "Gain";
    plugin.manufacturer = "Shi-tate Tests";
    plugin.version = "1.0.0";
    plugin.category = "Fx";
    plugin.inputChannels = 2;
    plugin.outputChannels = 2;
    plugin.compatible = true;
    result.plugins.push_back(plugin);
    result.durationMilliseconds = 7;
    return result;
}

[[nodiscard]] std::string replacing(std::string value, const std::string& target,
                                    const std::string& replacement) {
    if (const auto position = value.find(target); position != std::string::npos) {
        value.replace(position, target.size(), replacement);
    }
    return value;
}

class PluginScanProtocolTest final : public juce::UnitTest {
  public:
    PluginScanProtocolTest() : UnitTest("PluginScanProtocol", "Shitate") {}

    void runTest() override {
        beginTest("request schema round-trips exact protocol v1");
        const auto request = requestFixture();
        ScanRequest decoded;
        std::string error;
        expect(parseScanRequest(serializeScanRequest(request), decoded, error));
        expectEquals(decoded.requestID, request.requestID);
        expectEquals(decoded.pluginBundlePath, request.pluginBundlePath);
        expectEquals(decoded.maximumBlockFrames, scannerMaximumBlockFrames);

        beginTest("request rejects unknown, missing, malformed, and oversized fields");
        const auto validRequest = serializeScanRequest(request);
        expect(!parseScanRequest(
            replacing(validRequest, "\"protocolVersion\": 1", "\"protocolVersion\": 2"), decoded,
            error));
        expect(!parseScanRequest(replacing(validRequest, "\"requestID\"", "\"unknownRequestID\""),
                                 decoded, error));
        expect(!parseScanRequest(replacing(validRequest, request.requestID, "not-a-uuid"), decoded,
                                 error));
        expect(!parseScanRequest(std::string(maximumRequestBytes + 1, 'x'), decoded, error));

        beginTest("result allows additive fields and round-trips all required values");
        const auto result = resultFixture();
        ScanResult decodedResult;
        const auto additive =
            replacing(serializeScanResult(result), "{", "{\n  \"futureField\": true,");
        expect(parseScanResult(additive, decodedResult, error));
        expectEquals(decodedResult.requestID, result.requestID);
        expectEquals(static_cast<int>(decodedResult.plugins.size()), 1);
        expect(decodedResult.plugins.front().compatible);

        beginTest("result fails closed on invalid values and inconsistent status");
        const auto validResult = serializeScanResult(result);
        expect(!parseScanResult(
            replacing(validResult, "\"status\": \"compatible\"", "\"status\": \"unknown\""),
            decodedResult, error));
        expect(!parseScanResult(
            replacing(validResult, "\"status\": \"compatible\"", "\"status\": \"incompatible\""),
            decodedResult, error));
        expect(!parseScanResult(replacing(validResult, result.requestID, "bad-id"), decodedResult,
                                error));
        expect(!parseScanResult(replacing(validResult, result.plugins.front().classUID, "1234abcd"),
                                decodedResult, error));
        expect(!parseScanResult(std::string(maximumResultBytes + 1, 'x'), decodedResult, error));
    }
};

PluginScanProtocolTest pluginScanProtocolTest;

} // namespace
