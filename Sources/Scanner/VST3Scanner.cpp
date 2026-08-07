// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "VST3Scanner.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_audio_processors_headless/format_types/VST3_SDK/pluginterfaces/vst/ivstaudioprocessor.h>
#include <juce_audio_processors_headless/format_types/VST3_SDK/public.sdk/source/vst/hosting/module.h>
#include <optional>
#include <vector>

namespace shitate::scanner {
namespace {

struct ClassIdentity final {
    std::string name;
    std::string classUID;
    int deprecatedUID{0};
    bool claimed{false};
};

[[nodiscard]] int legacyUIDHash(const Steinberg::TUID& value) noexcept {
    std::uint32_t hash = 0;
    for (const auto byte : value) {
        hash = (hash * 31U) + static_cast<std::uint32_t>(byte);
    }
    return static_cast<int>(hash);
}

[[nodiscard]] std::optional<std::vector<ClassIdentity>>
loadClassIdentities(const std::string& bundlePath) {
    std::string error;
    auto module = VST3::Hosting::Module::create(bundlePath, error);
    if (module == nullptr) {
        return std::nullopt;
    }

    std::vector<ClassIdentity> result;
    for (const auto& info : module->getFactory().classInfos()) {
        if (info.category() != kVstAudioEffectClass) {
            continue;
        }
        result.push_back({juce::String::fromUTF8(info.name().c_str()).trim().toStdString(),
                          info.ID().toString(), legacyUIDHash(info.ID().data()), false});
    }
    return result;
}

[[nodiscard]] std::string claimClassUID(const juce::PluginDescription& description,
                                        std::vector<ClassIdentity>& identities) {
    ClassIdentity* match = nullptr;
    for (auto& identity : identities) {
        if (identity.claimed || identity.name != description.name.trim().toStdString() ||
            identity.deprecatedUID != description.deprecatedUid) {
            continue;
        }
        if (match != nullptr) {
            return {};
        }
        match = &identity;
    }
    if (match == nullptr) {
        return {};
    }
    match->claimed = true;
    return match->classUID;
}

[[nodiscard]] plugins::ScannedPlugin descriptorFor(const juce::PluginDescription& description,
                                                   std::string classUID) {
    plugins::ScannedPlugin plugin;
    plugin.classUID = std::move(classUID);
    plugin.name = description.name.toStdString();
    plugin.manufacturer = description.manufacturerName.toStdString();
    plugin.version = description.version.toStdString();
    plugin.category = description.category.toStdString();
    plugin.inputChannels = std::max(0, description.numInputChannels);
    plugin.outputChannels = std::max(0, description.numOutputChannels);
    return plugin;
}

[[nodiscard]] bool configureStereo(juce::AudioPluginInstance& instance) {
    if (instance.getBusCount(true) < 1 || instance.getBusCount(false) < 1) {
        return false;
    }
    auto layout = instance.getBusesLayout();
    const auto currentLayoutIsExactStereo = [&] {
        if (layout.getMainInputChannelSet() != juce::AudioChannelSet::stereo() ||
            layout.getMainOutputChannelSet() != juce::AudioChannelSet::stereo() ||
            instance.getTotalNumInputChannels() != plugins::requiredInputChannels ||
            instance.getTotalNumOutputChannels() != plugins::requiredOutputChannels) {
            return false;
        }
        for (int index = 1; index < layout.inputBuses.size(); ++index) {
            if (!layout.inputBuses[index].isDisabled()) {
                return false;
            }
        }
        for (int index = 1; index < layout.outputBuses.size(); ++index) {
            if (!layout.outputBuses[index].isDisabled()) {
                return false;
            }
        }
        return true;
    }();
    if (currentLayoutIsExactStereo) {
        return true;
    }
    for (int index = 0; index < layout.inputBuses.size(); ++index) {
        layout.inputBuses.getReference(index) =
            index == 0 ? juce::AudioChannelSet::stereo() : juce::AudioChannelSet::disabled();
    }
    for (int index = 0; index < layout.outputBuses.size(); ++index) {
        layout.outputBuses.getReference(index) =
            index == 0 ? juce::AudioChannelSet::stereo() : juce::AudioChannelSet::disabled();
    }
    return instance.checkBusesLayoutSupported(layout) && instance.setBusesLayout(layout) &&
           instance.getTotalNumInputChannels() == plugins::requiredInputChannels &&
           instance.getTotalNumOutputChannels() == plugins::requiredOutputChannels;
}

[[nodiscard]] bool bufferIsFinite(const juce::AudioBuffer<float>& buffer) {
    for (int channel = 0; channel < buffer.getNumChannels(); ++channel) {
        const auto* samples = buffer.getReadPointer(channel);
        for (int frame = 0; frame < buffer.getNumSamples(); ++frame) {
            if (!std::isfinite(samples[frame])) {
                return false;
            }
        }
    }
    return true;
}

[[nodiscard]] bool exercise(juce::AudioPluginInstance& instance, plugins::ScannedPlugin& plugin) {
    try {
        if (!configureStereo(instance)) {
            plugin.reason = "unsupportedLayout";
            return false;
        }
        plugin.inputChannels = std::max(0, instance.getTotalNumInputChannels());
        plugin.outputChannels = std::max(0, instance.getTotalNumOutputChannels());
        instance.setNonRealtime(true);
        instance.prepareToPlay(plugins::scannerSampleRate, plugins::scannerMaximumBlockFrames);
        juce::AudioBuffer<float> buffer(plugins::requiredOutputChannels,
                                        plugins::scannerMaximumBlockFrames);
        juce::MidiBuffer midi;
        for (int block = 0; block < 3; ++block) {
            buffer.clear();
            midi.clear();
            if (block == 2) {
                buffer.setSample(0, 0, 1.0F);
                buffer.setSample(1, 0, 1.0F);
            }
            instance.processBlock(buffer, midi);
            if (!bufferIsFinite(buffer)) {
                plugin.reason = "nonFiniteOutput";
                instance.releaseResources();
                return false;
            }
        }
        plugin.latencySamples = std::max(0, instance.getLatencySamples());
        plugin.hasEditor = instance.hasEditor();
        instance.releaseResources();
        return true;
    } catch (...) {
        try {
            instance.releaseResources();
        } catch (...) {
        }
        plugin.reason = "processingException";
        return false;
    }
}

} // namespace

VST3ScanOutcome VST3Scanner::scan(const plugins::ScanRequest& request,
                                  const plugins::SignatureInfo& signature) const noexcept {
    const auto startedAt = std::chrono::steady_clock::now();
    try {
        auto identities = loadClassIdentities(request.pluginBundlePath);
        if (!identities.has_value()) {
            return {VST3ScanStatus::bundleLoadFailure, std::nullopt, "classIdentityLoadFailed"};
        }

        juce::VST3PluginFormat format;
        juce::OwnedArray<juce::PluginDescription> descriptions;
        format.findAllTypesForFile(descriptions,
                                   juce::String::fromUTF8(request.pluginBundlePath.c_str()));
        if (descriptions.isEmpty()) {
            return {VST3ScanStatus::noSupportedClass, std::nullopt, "noPluginClass"};
        }

        plugins::ScanResult result;
        result.requestID = request.requestID;
        result.bundle.path = signature.canonicalPath;
        result.bundle.codeDirectoryHash = signature.codeDirectoryHash;
        result.bundle.teamIdentifier = signature.teamIdentifier;
        result.bundle.signatureKind = signature.kind;
        result.bundle.architectures = signature.architectures;
        result.bundle.modificationTime = signature.modificationTime;
        result.bundle.bundleVersion = signature.bundleVersion;

        bool eligibleEffectFound = false;
        bool instanceCreated = false;
        for (const auto* description : descriptions) {
            if (description == nullptr) {
                continue;
            }
            auto uid = claimClassUID(*description, *identities);
            if (uid.empty()) {
                return {VST3ScanStatus::factoryFailure, std::nullopt, "classIdentityMismatch"};
            }
            auto plugin = descriptorFor(*description, std::move(uid));
            if (description->isInstrument) {
                plugin.reason = "instrumentUnsupported";
                result.plugins.push_back(std::move(plugin));
                continue;
            }

            eligibleEffectFound = true;
            juce::String creationError;
            auto instance = format.createInstanceFromDescription(
                *description, request.sampleRate, request.maximumBlockFrames, creationError);
            if (instance == nullptr) {
                plugin.reason = "factoryAcquisitionFailed";
                result.plugins.push_back(std::move(plugin));
                continue;
            }
            instanceCreated = true;
            plugin.inputChannels = std::max(0, instance->getTotalNumInputChannels());
            plugin.outputChannels = std::max(0, instance->getTotalNumOutputChannels());
            plugin.compatible = exercise(*instance, plugin);
            if (!plugin.compatible && !plugin.reason.has_value()) {
                plugin.reason = "scanRejected";
            }
            result.plugins.push_back(std::move(plugin));
        }

        if (eligibleEffectFound && !instanceCreated) {
            return {VST3ScanStatus::factoryFailure, std::nullopt, "factoryAcquisitionFailed"};
        }
        const auto compatible = std::any_of(result.plugins.begin(), result.plugins.end(),
                                            [](const auto& plugin) { return plugin.compatible; });
        result.status = compatible ? "compatible" : "incompatible";
        result.durationMilliseconds = std::chrono::duration_cast<std::chrono::milliseconds>(
                                          std::chrono::steady_clock::now() - startedAt)
                                          .count();
        return {VST3ScanStatus::success, std::move(result), {}};
    } catch (...) {
        return {VST3ScanStatus::bundleLoadFailure, std::nullopt, "bundleScanException"};
    }
}

} // namespace shitate::scanner
