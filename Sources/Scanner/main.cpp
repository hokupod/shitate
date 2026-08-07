// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "ApplicationCore.h"
#include "Plugins/PluginSignatureVerifier.h"
#include "ScanRequest.h"
#include "ScanResultWriter.h"
#include "VST3Scanner.h"

#include <iostream>
#include <juce_gui_basics/juce_gui_basics.h>
#include <string_view>

namespace {

[[nodiscard]] bool sameBundleIdentity(const shitate::plugins::SignatureInfo& left,
                                      const shitate::plugins::SignatureInfo& right) {
    return left.kind == right.kind && left.canonicalPath == right.canonicalPath &&
           left.signingIdentifier == right.signingIdentifier &&
           left.teamIdentifier == right.teamIdentifier &&
           left.codeDirectoryHash == right.codeDirectoryHash && left.flags == right.flags &&
           left.architectures == right.architectures && left.bundleVersion == right.bundleVersion &&
           left.modificationTime == right.modificationTime;
}

[[nodiscard]] int exitCode(shitate::scanner::VST3ScanStatus status) {
    switch (status) {
    case shitate::scanner::VST3ScanStatus::success:
        return 0;
    case shitate::scanner::VST3ScanStatus::bundleLoadFailure:
        return 30;
    case shitate::scanner::VST3ScanStatus::factoryFailure:
        return 31;
    case shitate::scanner::VST3ScanStatus::noSupportedClass:
        return 32;
    case shitate::scanner::VST3ScanStatus::internalError:
        return 50;
    }
    return 50;
}

} // namespace

int main(int argc, char* argv[]) {
    if (argc == 2 && std::string_view(argv[1]) == "--version") {
        std::cout << "ShitatePluginScanner " << shitate::ApplicationCore::displayVersion() << '\n';
        return 0;
    }
    if (argc != 3 || std::string_view(argv[1]) != "--request") {
        std::cerr << "usage: ShitatePluginScanner --request <request-json-path>\n";
        return argc == 1 || (argc == 2 && std::string_view(argv[1]) != "--request") ? 2 : 10;
    }

    shitate::plugins::ScanRequest request;
    std::string requestError;
    if (!shitate::scanner::ScanRequestLoader::load(argv[2], request, requestError)) {
        std::cerr << "scanner: invalid request (" << requestError << ")\n";
        return 10;
    }

    const shitate::plugins::PluginSignatureVerifier verifier;
    const auto signature = verifier.inspect(request.pluginBundlePath);
    if (shitate::plugins::evaluateSignaturePolicy(signature, false) ==
            shitate::plugins::SignaturePolicyDecision::reject ||
        signature.canonicalPath != request.pluginBundlePath ||
        signature.codeDirectoryHash != request.expectedCodeDirectoryHash) {
        std::cerr << "scanner: signature verification failed\n";
        return 20;
    }

    juce::ScopedJuceInitialiser_GUI juceInitialiser;
    const shitate::scanner::VST3Scanner scanner;
    auto outcome = scanner.scan(request, signature);
    if (outcome.status != shitate::scanner::VST3ScanStatus::success ||
        !outcome.result.has_value()) {
        std::cerr << "scanner: scan failed (" << outcome.errorCode << ")\n";
        return exitCode(outcome.status);
    }

    const auto postflightSignature = verifier.inspect(signature.canonicalPath);
    if (!sameBundleIdentity(signature, postflightSignature)) {
        std::cerr << "scanner: bundle changed during scan\n";
        return 20;
    }

    const auto resultPath = shitate::scanner::ScanRequestLoader::resultPathForRequest(argv[2]);
    if (!shitate::scanner::ScanResultWriter::write(resultPath, *outcome.result)) {
        std::cerr << "scanner: result write failed\n";
        return 40;
    }
    return 0;
}
