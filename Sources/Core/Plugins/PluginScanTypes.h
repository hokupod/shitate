// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace shitate::plugins {

inline constexpr int scannerProtocolVersion = 1;
inline constexpr std::size_t maximumRequestBytes = 64U * 1024U;
inline constexpr std::size_t maximumResultBytes = 1024U * 1024U;
inline constexpr double scannerSampleRate = 48'000.0;
inline constexpr int scannerMaximumBlockFrames = 512;
inline constexpr int requiredInputChannels = 2;
inline constexpr int requiredOutputChannels = 2;

enum class SignatureKind {
    apple,
    developerID,
    adHoc,
    unsignedCode,
    invalid,
};

enum class PluginCompatibility {
    compatible,
    incompatible,
    blocked,
};

struct SignatureInfo final {
    SignatureKind kind{SignatureKind::invalid};
    std::string canonicalPath;
    std::string signingIdentifier;
    std::string teamIdentifier;
    std::string codeDirectoryHash;
    std::uint32_t flags{0};
    std::vector<std::string> architectures;
    std::string bundleVersion;
    std::int64_t modificationTime{0};
    std::string errorCode;
};

struct RequiredLayout final {
    int inputChannels{requiredInputChannels};
    int outputChannels{requiredOutputChannels};
};

struct ScanRequest final {
    int protocolVersion{scannerProtocolVersion};
    std::string requestID;
    std::string pluginBundlePath;
    std::string expectedCodeDirectoryHash;
    double sampleRate{scannerSampleRate};
    int maximumBlockFrames{scannerMaximumBlockFrames};
    RequiredLayout requiredLayout;
};

struct ScannedPlugin final {
    std::string classUID;
    std::string name;
    std::string manufacturer;
    std::string version;
    std::string category;
    int inputChannels{0};
    int outputChannels{0};
    int latencySamples{0};
    bool hasEditor{false};
    bool compatible{false};
    std::optional<std::string> reason;
};

struct ScannedBundle final {
    std::string path;
    std::string codeDirectoryHash;
    std::string teamIdentifier;
    SignatureKind signatureKind{SignatureKind::invalid};
    std::vector<std::string> architectures;
    std::int64_t modificationTime{0};
    std::string bundleVersion;
};

struct ScanResult final {
    int protocolVersion{scannerProtocolVersion};
    std::string requestID;
    std::string status;
    ScannedBundle bundle;
    std::vector<ScannedPlugin> plugins;
    std::int64_t durationMilliseconds{0};
};

enum class ScanOutcomeKind {
    success,
    invalidRequest,
    invalidSignature,
    bundleLoadFailure,
    factoryFailure,
    noSupportedClass,
    resultWriteFailure,
    internalError,
    crashed,
    timedOut,
    invalidResult,
    spawnFailure,
};

struct ScanOutcome final {
    ScanOutcomeKind kind{ScanOutcomeKind::internalError};
    std::optional<ScanResult> result;
    int childExitCode{-1};
    int terminationSignal{0};
    std::string diagnosticCode;
};

struct CatalogEntry final {
    std::string fingerprint;
    std::string bundlePath;
    std::string classUID;
    std::string name;
    std::string manufacturer;
    std::string version;
    std::string codeDirectoryHash;
    std::string teamIdentifier;
    SignatureKind signatureKind{SignatureKind::invalid};
    std::vector<std::string> architectures;
    int inputChannels{0};
    int outputChannels{0};
    int latencySamples{0};
    bool hasEditor{false};
    PluginCompatibility compatibility{PluginCompatibility::incompatible};
    std::optional<std::string> reason;
    std::int64_t bundleModificationTime{0};
    int scannerProtocol{scannerProtocolVersion};
    std::string compatibleAppVersion{"0.1"};
    std::string lastScannedAt;
};

} // namespace shitate::plugins
