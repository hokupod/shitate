// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Plugins/PluginCatalog.h"
#include "Plugins/PluginScanCoordinator.h"

#include <chrono>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <set>
#include <string>
#include <string_view>

#ifndef SHITATE_SCANNER_PATH
#error "SHITATE_SCANNER_PATH must be provided by CMake"
#endif
#ifndef SHITATE_SCANNER_PROTOCOL_FIXTURE_PATH
#error "SHITATE_SCANNER_PROTOCOL_FIXTURE_PATH must be provided by CMake"
#endif

namespace {

using namespace shitate::plugins;

class EnvironmentValue final {
  public:
    EnvironmentValue(const char* name, const char* value) : name_(name) {
        if (const auto* existing = std::getenv(name); existing != nullptr) {
            previous_ = existing;
        }
        static_cast<void>(::setenv(name, value, 1));
    }
    ~EnvironmentValue() {
        if (previous_.has_value()) {
            static_cast<void>(::setenv(name_.c_str(), previous_->c_str(), 1));
        } else {
            static_cast<void>(::unsetenv(name_.c_str()));
        }
    }

  private:
    std::string name_;
    std::optional<std::string> previous_;
};

[[nodiscard]] bool require(bool condition, std::string_view message) {
    if (!condition) {
        std::cerr << message << '\n';
    }
    return condition;
}

[[nodiscard]] const ScannedPlugin* firstPlugin(const ScanOutcome& outcome) {
    if (!outcome.result.has_value() || outcome.result->plugins.empty()) {
        return nullptr;
    }
    return &outcome.result->plugins.front();
}

void describeFailure(const ScanOutcome& outcome) {
    std::cerr << " outcome=" << static_cast<int>(outcome.kind) << " exit=" << outcome.childExitCode
              << " signal=" << outcome.terminationSignal
              << " diagnostic=" << outcome.diagnosticCode;
    if (const auto* plugin = firstPlugin(outcome); plugin != nullptr) {
        std::cerr << " plugin=" << plugin->name << " compatible=" << plugin->compatible
                  << " reason=" << plugin->reason.value_or("none");
    }
    std::cerr << '\n';
}

[[nodiscard]] bool scanCompatibilityFixtures(const PluginScanCoordinator& coordinator) {
    const auto gain = coordinator.scan(SHITATE_SCANNER_PATH, SHITATE_GAIN_PLUGIN_PATH);
    const auto* gainPlugin = firstPlugin(gain);
    if (!require(gain.kind == ScanOutcomeKind::success && gainPlugin != nullptr &&
                     gainPlugin->compatible && gainPlugin->classUID.size() == 32 &&
                     gainPlugin->inputChannels == 2 && gainPlugin->outputChannels == 2,
                 "GainPlugin must scan as compatible")) {
        describeFailure(gain);
        return false;
    }

    PluginCatalog catalog;
    if (!require(catalog.replaceBundle(*gain.result, {}, "2026-08-07T00:00:00Z"),
                 "GainPlugin catalog insertion failed")) {
        return false;
    }
    if (gain.result->bundle.signatureKind == SignatureKind::adHoc) {
        const auto fingerprint = catalog.entries().front().fingerprint;
        if (!require(catalog.entries().front().compatibility == PluginCompatibility::blocked,
                     "ad-hoc GainPlugin must be blocked before exact approval") ||
            !require(catalog.replaceBundle(*gain.result, {fingerprint}, "2026-08-07T00:00:01Z"),
                     "approved GainPlugin catalog insertion failed")) {
            return false;
        }
    }
    if (!require(catalog.entries().front().compatibility == PluginCompatibility::compatible,
                 "GainPlugin must catalog as compatible after policy")) {
        return false;
    }

    const auto latency = coordinator.scan(SHITATE_SCANNER_PATH, SHITATE_LATENCY_PLUGIN_PATH);
    const auto* latencyPlugin = firstPlugin(latency);
    if (!require(latency.kind == ScanOutcomeKind::success && latencyPlugin != nullptr &&
                     latencyPlugin->compatible && latencyPlugin->latencySamples == 64,
                 "LatencyPlugin must report deterministic latency")) {
        return false;
    }

    const auto nonFinite = coordinator.scan(SHITATE_SCANNER_PATH, SHITATE_NAN_PLUGIN_PATH);
    const auto* nonFinitePlugin = firstPlugin(nonFinite);
    if (!require(nonFinite.kind == ScanOutcomeKind::success && nonFinitePlugin != nullptr &&
                     !nonFinitePlugin->compatible && nonFinitePlugin->reason == "nonFiniteOutput",
                 "NaNPlugin must reject non-finite output")) {
        return false;
    }

    const auto throwing = coordinator.scan(SHITATE_SCANNER_PATH, SHITATE_THROW_PLUGIN_PATH);
    const auto* throwingPlugin = firstPlugin(throwing);
    if (!require(throwing.kind == ScanOutcomeKind::success && throwingPlugin != nullptr &&
                     !throwingPlugin->compatible && throwingPlugin->reason == "processingException",
                 "ThrowPlugin must reject processing exceptions")) {
        return false;
    }

    const auto mono = coordinator.scan(SHITATE_SCANNER_PATH, SHITATE_MONO_PLUGIN_PATH);
    const auto* monoPlugin = firstPlugin(mono);
    if (!require(mono.kind == ScanOutcomeKind::success && monoPlugin != nullptr &&
                     !monoPlugin->compatible && monoPlugin->reason == "unsupportedLayout",
                 "MonoOnlyPlugin must reject with stable layout reason")) {
        return false;
    }

    const auto instrument = coordinator.scan(SHITATE_SCANNER_PATH, SHITATE_INSTRUMENT_PLUGIN_PATH);
    const auto* instrumentPlugin = firstPlugin(instrument);
    return require(instrument.kind == ScanOutcomeKind::success && instrumentPlugin != nullptr &&
                       !instrumentPlugin->compatible &&
                       instrumentPlugin->reason == "instrumentUnsupported",
                   "InstrumentPlugin must reject with stable category reason");
}

[[nodiscard]] bool scanIsolationFixtures(const PluginScanCoordinator& coordinator) {
    {
        const EnvironmentValue behavior("SHITATE_TEST_PLUGIN_BEHAVIOR", "Crash");
        const auto crashed = coordinator.scan(SHITATE_SCANNER_PATH, SHITATE_CRASH_PLUGIN_PATH);
        if (!require(crashed.kind == ScanOutcomeKind::crashed && crashed.terminationSignal != 0,
                     "CrashPlugin must terminate only its helper")) {
            describeFailure(crashed);
            return false;
        }
    }

    const auto startedAt = std::chrono::steady_clock::now();
    {
        const EnvironmentValue behavior("SHITATE_TEST_PLUGIN_BEHAVIOR", "Hang");
        const auto timedOut = coordinator.scan(SHITATE_SCANNER_PATH, SHITATE_HANG_PLUGIN_PATH);
        if (!require(timedOut.kind == ScanOutcomeKind::timedOut,
                     "HangPlugin must be terminated and reaped as timedOut")) {
            describeFailure(timedOut);
            return false;
        }
    }
    const auto elapsed = std::chrono::steady_clock::now() - startedAt;
    return require(elapsed < std::chrono::seconds(3),
                   "HangPlugin supervision exceeded its bounded margin");
}

[[nodiscard]] bool scanFloodFixture() {
    ScanCoordinatorConfiguration configuration;
    configuration.timeout = std::chrono::milliseconds(250);
    configuration.terminationGrace = std::chrono::milliseconds(100);
    configuration.inheritedEnvironmentKeys = {"SHITATE_TEST_SCANNER_FLOOD"};
    PluginScanCoordinator coordinator(std::make_shared<PluginSignatureVerifier>(), configuration);

    const auto startedAt = std::chrono::steady_clock::now();
    EnvironmentValue flood("SHITATE_TEST_SCANNER_FLOOD", "1");
    const auto outcome =
        coordinator.scan(SHITATE_SCANNER_PROTOCOL_FIXTURE_PATH, SHITATE_GAIN_PLUGIN_PATH);
    const auto elapsed = std::chrono::steady_clock::now() - startedAt;
    return require(outcome.kind == ScanOutcomeKind::timedOut,
                   "flooding scanner must be terminated as timedOut") &&
           require(elapsed < std::chrono::seconds(2),
                   "pipe flooding must not defeat the supervision deadline");
}

} // namespace

int main() {
    ScanCoordinatorConfiguration compatibilityConfiguration;
    compatibilityConfiguration.timeout = std::chrono::seconds(5);
    PluginScanCoordinator compatibilityCoordinator(std::make_shared<PluginSignatureVerifier>(),
                                                   compatibilityConfiguration);

    ScanCoordinatorConfiguration isolationConfiguration;
    isolationConfiguration.timeout = std::chrono::seconds(2);
    isolationConfiguration.terminationGrace = std::chrono::milliseconds(100);
    isolationConfiguration.inheritedEnvironmentKeys = {"SHITATE_TEST_PLUGIN_BEHAVIOR"};
    PluginScanCoordinator isolationCoordinator(std::make_shared<PluginSignatureVerifier>(),
                                               isolationConfiguration);

    if (!scanCompatibilityFixtures(compatibilityCoordinator) ||
        !scanIsolationFixtures(isolationCoordinator) || !scanFloodFixture()) {
        return 1;
    }

    const EnvironmentValue secret("SHITATE_TEST_SECRET", "must-not-reach-helper");
    const auto missing =
        isolationCoordinator.scan(SHITATE_SCANNER_PROTOCOL_FIXTURE_PATH, SHITATE_GAIN_PLUGIN_PATH);
    if (!require(missing.kind == ScanOutcomeKind::invalidResult,
                 "zero exit without result must classify as invalidResult")) {
        return 1;
    }
    return 0;
}
