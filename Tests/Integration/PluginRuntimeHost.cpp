// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Audio/PluginChain.h"
#include "Audio/RealtimeEventQueue.h"
#include "Plugins/PluginCatalog.h"
#include "Plugins/PluginFactory.h"
#include "Plugins/PluginLoadJournal.h"
#include "Plugins/PluginScanCoordinator.h"
#include "Plugins/PluginSignatureVerifier.h"

#include <array>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <juce_gui_basics/juce_gui_basics.h>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <sys/stat.h>
#include <vector>

#ifndef SHITATE_SCANNER_PATH
#error "SHITATE_SCANNER_PATH must be provided by CMake"
#endif

#ifndef SHITATE_GAIN_PLUGIN_PATH
#error "SHITATE_GAIN_PLUGIN_PATH must be provided by CMake"
#endif

namespace {

class TemporaryRuntimeDirectory final {
  public:
    TemporaryRuntimeDirectory()
        : path(std::filesystem::temp_directory_path() /
               ("shitate-runtime-host-" + juce::Uuid().toString().toStdString())) {
        std::filesystem::create_directory(path);
        static_cast<void>(::chmod(path.c_str(), 0700));
    }

    ~TemporaryRuntimeDirectory() {
        std::error_code error;
        std::filesystem::remove_all(path, error);
    }

    std::filesystem::path path;
};

[[nodiscard]] bool approximately(float left, float right) noexcept {
    return std::abs(left - right) <= 0.0001F;
}

[[nodiscard]] std::optional<shitate::plugins::CatalogEntry>
scanGainPlugin(const std::shared_ptr<shitate::plugins::PluginSignatureVerifier>& verifier) {
    shitate::plugins::PluginScanCoordinator coordinator(verifier);
    static_cast<void>(coordinator.cleanupStaleTasks());
    const auto outcome = coordinator.scan(SHITATE_SCANNER_PATH, SHITATE_GAIN_PLUGIN_PATH);
    if (outcome.kind != shitate::plugins::ScanOutcomeKind::success || !outcome.result.has_value()) {
        std::cerr << "runtime host scan failed: " << outcome.diagnosticCode << '\n';
        return std::nullopt;
    }

    std::set<std::string> approvals;
    for (const auto& plugin : outcome.result->plugins) {
        approvals.insert(
            shitate::plugins::pluginFingerprint(outcome.result->bundle.path, plugin.classUID,
                                                outcome.result->bundle.codeDirectoryHash, "arm64"));
    }
    shitate::plugins::PluginCatalog catalog;
    if (!catalog.replaceBundle(*outcome.result, approvals, "2026-08-07T00:00:00Z")) {
        std::cerr << "runtime host could not catalog the validated fixture\n";
        return std::nullopt;
    }
    for (const auto& entry : catalog.entries()) {
        if (entry.compatibility == shitate::plugins::PluginCompatibility::compatible) {
            return entry;
        }
    }
    std::cerr << "runtime host found no compatible Gain fixture class\n";
    return std::nullopt;
}

[[nodiscard]] shitate::plugins::SlotId slotID(std::uint8_t value) {
    std::array<std::uint8_t, shitate::plugins::SlotId::byteCount> bytes{};
    bytes.back() = value;
    return shitate::plugins::SlotId(bytes);
}

struct Runtime final {
    Runtime(std::shared_ptr<shitate::plugins::PluginSignatureVerifier> verifier,
            std::shared_ptr<shitate::plugins::PluginLoadJournal> journal)
        : factory(queue, std::move(verifier),
                  std::make_shared<shitate::plugins::JuceVST3PluginInstanceCreator>(),
                  std::move(journal)) {}

    shitate::RealtimeEventQueue queue;
    shitate::plugins::PluginFactory factory;
    shitate::PluginChain chain;
};

[[nodiscard]] bool addGain(Runtime& runtime, const shitate::plugins::CatalogEntry& entry,
                           std::uint8_t id, float gain) {
    auto created = runtime.factory.create(entry, slotID(id));
    if (!created.result.succeeded() || created.slot == nullptr) {
        std::cerr << "runtime host failed to instantiate slot " << static_cast<int>(id) << ": "
                  << created.result.message << '\n';
        return false;
    }
    const auto parameter = created.slot->setParameterNormalized(0, gain / 2.0F);
    if (!parameter.succeeded()) {
        std::cerr << "runtime host failed to set Gain state: " << parameter.message << '\n';
        return false;
    }
    const auto added = runtime.chain.addSlot(std::move(created.slot));
    if (!added.succeeded()) {
        std::cerr << "runtime host failed to add slot: " << added.message << '\n';
        return false;
    }
    return true;
}

[[nodiscard]] std::optional<float> process(Runtime& runtime) {
    if (const auto prepared = runtime.chain.prepare(); !prepared.succeeded()) {
        std::cerr << "runtime host chain preparation failed: " << prepared.message << '\n';
        return std::nullopt;
    }
    runtime.chain.setRunning(true);
    juce::AudioBuffer<float> buffer(2, 512);
    for (int channel = 0; channel < buffer.getNumChannels(); ++channel) {
        juce::FloatVectorOperations::fill(buffer.getWritePointer(channel), 0.8F, 512);
    }
    juce::MidiBuffer midi;
    runtime.chain.process(buffer, midi, 512);
    runtime.chain.setRunning(false);
    const auto output = buffer.getSample(0, 0);
    for (int channel = 0; channel < buffer.getNumChannels(); ++channel) {
        for (int frame = 0; frame < buffer.getNumSamples(); ++frame) {
            if (!approximately(buffer.getSample(channel, frame), output)) {
                std::cerr << "runtime host produced non-deterministic audio\n";
                return std::nullopt;
            }
        }
    }
    return output;
}

} // namespace

int main() {
    juce::ScopedJuceInitialiser_GUI guiInitialiser;
    TemporaryRuntimeDirectory directory;
    auto verifier = std::make_shared<shitate::plugins::PluginSignatureVerifier>();
    const auto entry = scanGainPlugin(verifier);
    if (!entry.has_value()) {
        return 1;
    }
    auto journal = std::make_shared<shitate::plugins::FilePluginLoadJournal>(
        (directory.path / "plugin-load-journal.json").string());

    std::array<std::vector<std::uint8_t>, 3> savedStates;
    std::optional<float> firstOutput;
    {
        Runtime first(verifier, journal);
        if (!addGain(first, *entry, 1, 0.5F) || !addGain(first, *entry, 2, 0.25F) ||
            !addGain(first, *entry, 3, 0.8F)) {
            return 1;
        }
        firstOutput = process(first);
        if (!firstOutput.has_value() || !approximately(*firstOutput, 0.08F)) {
            std::cerr << "runtime host first chain output mismatch\n";
            return 1;
        }
        for (std::uint8_t index = 0; index < savedStates.size(); ++index) {
            auto* slot = first.chain.slot(slotID(index + 1));
            if (slot == nullptr) {
                return 1;
            }
            auto state = slot->serializeState();
            if (!state.result.succeeded()) {
                std::cerr << "runtime host state serialization failed\n";
                return 1;
            }
            savedStates[index] = std::move(state.data);
        }
    }

    Runtime restored(verifier, journal);
    for (std::uint8_t index = 0; index < savedStates.size(); ++index) {
        auto created = restored.factory.create(*entry, slotID(index + 1), savedStates[index].data(),
                                               savedStates[index].size());
        if (!created.result.succeeded() || created.slot == nullptr ||
            !restored.chain.addSlot(std::move(created.slot)).succeeded()) {
            std::cerr << "runtime host state restoration failed\n";
            return 1;
        }
    }
    const auto restoredOutput = process(restored);
    if (!restoredOutput.has_value() || !approximately(*restoredOutput, *firstOutput)) {
        std::cerr << "runtime host restored chain output mismatch\n";
        return 1;
    }
    const auto snapshots = restored.chain.snapshots();
    if (snapshots.size() != savedStates.size() || snapshots[0].slotID != slotID(1) ||
        snapshots[1].slotID != slotID(2) || snapshots[2].slotID != slotID(3)) {
        std::cerr << "runtime host restored chain order mismatch\n";
        return 1;
    }
    return 0;
}
