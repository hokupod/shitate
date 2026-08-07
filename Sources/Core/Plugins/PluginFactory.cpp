// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "PluginFactory.h"

#include "Audio/HostedPluginSlot.h"
#include "Audio/RealtimeEventQueue.h"
#include "PluginCatalog.h"

#include <algorithm>
#include <cstdint>
#include <juce_audio_processors_headless/format_types/VST3_SDK/pluginterfaces/vst/ivstaudioprocessor.h>
#include <juce_audio_processors_headless/format_types/VST3_SDK/public.sdk/source/vst/hosting/module.h>
#include <optional>
#include <utility>
#include <vector>

namespace shitate::plugins {
namespace {

struct RuntimeClassIdentity final {
    std::string name;
    std::string classUID;
    int deprecatedUID{0};
};

[[nodiscard]] int legacyUIDHash(const Steinberg::TUID& value) noexcept {
    std::uint32_t hash = 0;
    for (const auto byte : value) {
        hash = (hash * 31U) + static_cast<std::uint32_t>(byte);
    }
    return static_cast<int>(hash);
}

[[nodiscard]] std::optional<RuntimeClassIdentity> resolveClass(const CatalogEntry& entry) {
    std::string error;
    auto module = VST3::Hosting::Module::create(entry.bundlePath, error);
    if (module == nullptr) {
        return std::nullopt;
    }

    std::optional<RuntimeClassIdentity> match;
    for (const auto& info : module->getFactory().classInfos()) {
        if (info.category() != kVstAudioEffectClass || info.ID().toString() != entry.classUID) {
            continue;
        }
        if (match.has_value()) {
            return std::nullopt;
        }
        match = RuntimeClassIdentity{
            juce::String::fromUTF8(info.name().c_str()).trim().toStdString(),
            info.ID().toString(),
            legacyUIDHash(info.ID().data()),
        };
    }
    return match;
}

[[nodiscard]] bool configureExactStereo(juce::AudioProcessor& processor) {
    if (processor.getBusCount(true) < 1 || processor.getBusCount(false) < 1) {
        return false;
    }
    auto layout = processor.getBusesLayout();
    for (int index = 0; index < layout.inputBuses.size(); ++index) {
        layout.inputBuses.getReference(index) =
            index == 0 ? juce::AudioChannelSet::stereo() : juce::AudioChannelSet::disabled();
    }
    for (int index = 0; index < layout.outputBuses.size(); ++index) {
        layout.outputBuses.getReference(index) =
            index == 0 ? juce::AudioChannelSet::stereo() : juce::AudioChannelSet::disabled();
    }
    if (!processor.checkBusesLayoutSupported(layout) || !processor.setBusesLayout(layout) ||
        processor.getTotalNumInputChannels() != requiredInputChannels ||
        processor.getTotalNumOutputChannels() != requiredOutputChannels) {
        return false;
    }
    const auto applied = processor.getBusesLayout();
    for (int index = 1; index < applied.inputBuses.size(); ++index) {
        if (!applied.inputBuses[index].isDisabled()) {
            return false;
        }
    }
    for (int index = 1; index < applied.outputBuses.size(); ++index) {
        if (!applied.outputBuses[index].isDisabled()) {
            return false;
        }
    }
    return applied.getMainInputChannelSet() == juce::AudioChannelSet::stereo() &&
           applied.getMainOutputChannelSet() == juce::AudioChannelSet::stereo();
}

[[nodiscard]] bool sameLiveIdentity(const SignatureInfo& left,
                                    const SignatureInfo& right) noexcept {
    return left.kind == right.kind && left.canonicalPath == right.canonicalPath &&
           left.signingIdentifier == right.signingIdentifier &&
           left.teamIdentifier == right.teamIdentifier &&
           left.codeDirectoryHash == right.codeDirectoryHash && left.flags == right.flags &&
           left.architectures == right.architectures && left.bundleVersion == right.bundleVersion &&
           left.modificationTime == right.modificationTime;
}

} // namespace

PluginInstanceResult JuceVST3PluginInstanceCreator::create(const CatalogEntry& entry) {
    try {
        const auto identity = resolveClass(entry);
        if (!identity.has_value() || identity->name != entry.name) {
            return {PluginRuntimeResult::failure(PluginRuntimeError::instanceCreationFailed,
                                                 "The VST3 class identity no longer matches."),
                    nullptr};
        }

        juce::VST3PluginFormat format;
        juce::OwnedArray<juce::PluginDescription> descriptions;
        format.findAllTypesForFile(descriptions, juce::String::fromUTF8(entry.bundlePath.c_str()));
        juce::PluginDescription* selected = nullptr;
        for (auto* description : descriptions) {
            if (description == nullptr || description->isInstrument ||
                description->name.trim().toStdString() != identity->name ||
                description->deprecatedUid != identity->deprecatedUID) {
                continue;
            }
            if (selected != nullptr) {
                return {PluginRuntimeResult::failure(
                            PluginRuntimeError::instanceCreationFailed,
                            "The VST3 class identity is ambiguous at runtime."),
                        nullptr};
            }
            selected = description;
        }
        if (selected == nullptr) {
            return {PluginRuntimeResult::failure(PluginRuntimeError::instanceCreationFailed,
                                                 "The VST3 class is unavailable at runtime."),
                    nullptr};
        }

        juce::String creationError;
        auto instance = format.createInstanceFromDescription(
            *selected, scannerSampleRate, scannerMaximumBlockFrames, creationError);
        if (instance == nullptr) {
            return {PluginRuntimeResult::failure(PluginRuntimeError::instanceCreationFailed,
                                                 "The VST3 instance could not be created."),
                    nullptr};
        }
        return {PluginRuntimeResult::success(), std::move(instance)};
    } catch (...) {
        return {PluginRuntimeResult::failure(PluginRuntimeError::instanceCreationFailed,
                                             "The VST3 factory failed safely."),
                nullptr};
    }
}

PluginFactory::PluginFactory(RealtimeEventQueue& eventQueue,
                             std::shared_ptr<const SignatureInspector> signatureInspector,
                             std::shared_ptr<PluginInstanceCreator> instanceCreator,
                             std::shared_ptr<PluginLoadJournal> loadJournal)
    : eventQueue_(eventQueue), signatureInspector_(std::move(signatureInspector)),
      instanceCreator_(std::move(instanceCreator)), loadJournal_(std::move(loadJournal)) {}

PluginCreationResult PluginFactory::create(const CatalogEntry& entry, SlotId slotID,
                                           const void* stateData, std::size_t stateSize) const {
    SignatureInfo preflight;
    if (auto result = validateIdentity(entry, preflight); !result.succeeded()) {
        return {std::move(result), nullptr};
    }
    if (!slotID.isValid() || (stateData == nullptr && stateSize != 0) ||
        stateSize > HostedPluginSlot::maximumStateBytes || instanceCreator_ == nullptr ||
        loadJournal_ == nullptr) {
        return {PluginRuntimeResult::failure(PluginRuntimeError::invalidDescriptor,
                                             "The runtime plug-in request is invalid."),
                nullptr};
    }

    const PluginLoadJournalEntry journalEntry{
        .slotID = slotID,
        .fingerprint = entry.fingerprint,
        .pluginName = entry.name,
    };
    if (auto journal = loadJournal_->begin(journalEntry); !journal.succeeded()) {
        return {std::move(journal), nullptr};
    }
    const auto failed = [&](PluginRuntimeResult result) -> PluginCreationResult {
        if (auto recorded = loadJournal_->fail(journalEntry, result.error); !recorded.succeeded()) {
            return {std::move(recorded), nullptr};
        }
        return {std::move(result), nullptr};
    };

    auto created = instanceCreator_->create(entry);
    if (!created.result.succeeded() || created.instance == nullptr) {
        auto result =
            created.result.succeeded()
                ? PluginRuntimeResult::failure(PluginRuntimeError::instanceCreationFailed,
                                               "The plug-in factory returned no instance.")
                : std::move(created.result);
        created.instance.reset();
        return failed(std::move(result));
    }

    const auto postflight = signatureInspector_->inspect(entry.bundlePath);
    if (!sameLiveIdentity(preflight, postflight)) {
        created.instance.reset();
        return failed(PluginRuntimeResult::failure(PluginRuntimeError::identityChanged,
                                                   "The plug-in changed while it was loading."));
    }
    if (!configureExactStereo(*created.instance)) {
        created.instance.reset();
        return failed(PluginRuntimeResult::failure(PluginRuntimeError::unsupportedLayout,
                                                   "The plug-in no longer supports exact stereo."));
    }

    auto slot =
        std::make_unique<HostedPluginSlot>(slotID, entry, std::move(created.instance), eventQueue_);
    if (stateSize > 0) {
        if (auto state = slot->restoreState(stateData, stateSize); !state.succeeded()) {
            slot.reset();
            return failed(std::move(state));
        }
    }
    if (auto prepared = slot->prepare(scannerSampleRate, scannerMaximumBlockFrames);
        !prepared.succeeded()) {
        slot.reset();
        return failed(std::move(prepared));
    }
    if (auto cleared = loadJournal_->clear(); !cleared.succeeded()) {
        return {std::move(cleared), nullptr};
    }
    return {PluginRuntimeResult::success(), std::move(slot)};
}

PluginRuntimeResult PluginFactory::validateIdentity(const CatalogEntry& entry,
                                                    SignatureInfo& liveIdentity) const {
    if (signatureInspector_ == nullptr || entry.compatibility != PluginCompatibility::compatible ||
        entry.reason.has_value() || entry.bundlePath.empty() || entry.classUID.size() != 32 ||
        entry.codeDirectoryHash.empty() || entry.name.empty() || entry.inputChannels != 2 ||
        entry.outputChannels != 2 || entry.scannerProtocol != scannerProtocolVersion ||
        entry.compatibleAppVersion != "0.1" ||
        !std::count(entry.architectures.begin(), entry.architectures.end(), "arm64")) {
        return PluginRuntimeResult::failure(PluginRuntimeError::invalidDescriptor,
                                            "The catalog descriptor is not runtime-compatible.");
    }
    const auto expectedFingerprint =
        pluginFingerprint(entry.bundlePath, entry.classUID, entry.codeDirectoryHash, "arm64");
    if (entry.fingerprint != expectedFingerprint) {
        return PluginRuntimeResult::failure(PluginRuntimeError::invalidDescriptor,
                                            "The catalog fingerprint is invalid.");
    }

    liveIdentity = signatureInspector_->inspect(entry.bundlePath);
    const auto fingerprintApproved = entry.signatureKind == SignatureKind::adHoc;
    if (evaluateSignaturePolicy(liveIdentity, fingerprintApproved) !=
            SignaturePolicyDecision::allow ||
        !supportsRequiredArchitecture(liveIdentity) ||
        liveIdentity.canonicalPath != entry.bundlePath ||
        liveIdentity.codeDirectoryHash != entry.codeDirectoryHash ||
        liveIdentity.teamIdentifier != entry.teamIdentifier ||
        liveIdentity.kind != entry.signatureKind ||
        liveIdentity.architectures != entry.architectures ||
        liveIdentity.modificationTime != entry.bundleModificationTime) {
        return PluginRuntimeResult::failure(PluginRuntimeError::identityChanged,
                                            "The plug-in identity changed after cataloging.");
    }
    return PluginRuntimeResult::success();
}

} // namespace shitate::plugins
