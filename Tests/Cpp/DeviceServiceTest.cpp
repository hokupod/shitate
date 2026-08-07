// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Audio/DeviceService.h"

#include <juce_core/juce_core.h>

namespace {

shitate::AudioDeviceInfo inputDevice(std::string uid, std::string name = "USB Microphone") {
    return {
        .uid = std::move(uid),
        .displayName = std::move(name),
        .inputChannelNames = {"Mic 1", "Mic 2"},
        .sampleRates = {44100.0, 48000.0},
        .allowedBufferFrames = {128, 256, 512},
        .minimumBufferFrames = 64,
        .maximumBufferFrames = 1024,
        .alive = true,
        .physical = true,
    };
}

shitate::AudioDeviceInfo blackHole(std::string uid) {
    return {
        .uid = std::move(uid),
        .displayName = "BlackHole 2ch",
        .outputChannelNames = {"BlackHole 1", "BlackHole 2"},
        .sampleRates = {48000.0},
        .allowedBufferFrames = {128, 256, 512},
        .minimumBufferFrames = 64,
        .maximumBufferFrames = 1024,
        .alive = true,
        .physical = false,
    };
}

shitate::AudioDeviceInfo systemOutput(std::string uid) {
    return {
        .uid = std::move(uid),
        .displayName = "MacBook Pro Speakers",
        .outputChannelNames = {"Left", "Right"},
        .sampleRates = {44100.0, 48000.0},
        .allowedBufferFrames = {128, 256, 512},
        .minimumBufferFrames = 32,
        .maximumBufferFrames = 1024,
        .alive = true,
        .physical = true,
    };
}

shitate::AudioConfiguration validConfiguration() {
    return {
        .inputDeviceUID = "input-a",
        .outputDeviceUID = "blackhole-a",
        .blackHoleDeviceUID = "blackhole-a",
        .inputChannelIndex = 1,
        .sampleRate = 48000.0,
        .bufferFrames = 256,
    };
}

shitate::AudioConfiguration validPreviewConfiguration() {
    auto configuration = validConfiguration();
    configuration.outputTarget = shitate::AudioOutputTarget::systemPreview;
    configuration.outputDeviceUID = "speakers-a";
    return configuration;
}

class DeviceServiceTest final : public juce::UnitTest {
  public:
    DeviceServiceTest() : juce::UnitTest("DeviceService", "Shitate") {}

    void runTest() override {
        beginTest("UID distinguishes duplicate display names");
        const std::vector duplicateNames{inputDevice("input-a"), inputDevice("input-b"),
                                         blackHole("blackhole-a")};
        const auto* selected = shitate::DeviceService::findByUID(duplicateNames, "input-b");
        expect(selected != nullptr);
        expectEquals(selected != nullptr ? selected->uid : std::string{}, std::string("input-b"));

        beginTest("format negotiation prefers 256 then 128 then 512");
        auto input = inputDevice("input-a");
        auto output = blackHole("blackhole-a");
        expectEquals(shitate::DeviceService::choosePreferredBuffer(input, output), 256);
        input.allowedBufferFrames = {128, 512};
        expectEquals(shitate::DeviceService::choosePreferredBuffer(input, output), 128);
        input.allowedBufferFrames = {512};
        expectEquals(shitate::DeviceService::choosePreferredBuffer(input, output), 512);
        input.allowedBufferFrames.clear();
        expectEquals(shitate::DeviceService::choosePreferredBuffer(input, output), 0);

        beginTest("validates the exact UID and 48 kHz contract");
        const std::vector devices{inputDevice("input-a"), blackHole("blackhole-a")};
        expect(shitate::DeviceService::validateConfiguration(validConfiguration(), devices)
                   .succeeded());

        auto missingInput = validConfiguration();
        missingInput.inputDeviceUID = "missing";
        expect(shitate::DeviceService::validateConfiguration(missingInput, devices).code ==
               shitate::AudioErrorCode::inputDeviceMissing);

        auto unsupportedRate = devices;
        unsupportedRate[0].sampleRates = {44100.0};
        expect(shitate::DeviceService::validateConfiguration(validConfiguration(), unsupportedRate)
                   .code == shitate::AudioErrorCode::unsupportedSampleRate);

        beginTest("never accepts another output as BlackHole");
        auto wrongOutput = devices;
        wrongOutput[1].displayName = "Mac Speakers";
        expect(
            shitate::DeviceService::validateConfiguration(validConfiguration(), wrongOutput).code ==
            shitate::AudioErrorCode::blackHoleMissing);

        beginTest("changed BlackHole UID blocks the saved configuration");
        const std::vector replaced{inputDevice("input-a"), blackHole("blackhole-b")};
        expect(shitate::DeviceService::findBlackHole(replaced) != nullptr);
        expect(shitate::DeviceService::validateConfiguration(validConfiguration(), replaced).code ==
               shitate::AudioErrorCode::blackHoleMissing);

        beginTest("duplicate or invalid same-UID devices fail the configured snapshot");
        const std::vector duplicateBlackHole{inputDevice("input-a"), blackHole("blackhole-a"),
                                             blackHole("blackhole-b")};
        expect(shitate::DeviceService::findBlackHole(duplicateBlackHole) == nullptr);
        expect(
            shitate::DeviceService::validateConfiguration(validConfiguration(), duplicateBlackHole)
                .code == shitate::AudioErrorCode::blackHoleMissing);
        auto deadInput = devices;
        deadInput[0].alive = false;
        expect(
            shitate::DeviceService::validateConfiguration(validConfiguration(), deadInput).code ==
            shitate::AudioErrorCode::inputDeviceMissing);
        auto deadBlackHole = devices;
        deadBlackHole[1].alive = false;
        expect(shitate::DeviceService::validateConfiguration(validConfiguration(), deadBlackHole)
                   .code == shitate::AudioErrorCode::blackHoleMissing);

        auto wrongSavedBlackHole = validConfiguration();
        wrongSavedBlackHole.blackHoleDeviceUID = "blackhole-b";
        expect(shitate::DeviceService::validateConfiguration(wrongSavedBlackHole, devices).code ==
               shitate::AudioErrorCode::blackHoleMissing);

        auto spoofedBlackHoleUID = validConfiguration();
        spoofedBlackHoleUID.blackHoleDeviceUID = "speakers-a";
        const std::vector spoofedDevices{inputDevice("input-a"), blackHole("blackhole-a"),
                                         systemOutput("speakers-a")};
        expect(shitate::DeviceService::validateConfiguration(spoofedBlackHoleUID, spoofedDevices)
                   .code == shitate::AudioErrorCode::blackHoleMissing);

        beginTest("preview accepts only the exact physical macOS default output");
        const std::vector previewDevices{inputDevice("input-a"), blackHole("blackhole-a"),
                                         systemOutput("speakers-a")};
        expect(shitate::DeviceService::validateConfiguration(validPreviewConfiguration(),
                                                             previewDevices, "speakers-a")
                   .succeeded());
        expect(shitate::DeviceService::validateConfiguration(validPreviewConfiguration(),
                                                             previewDevices, "speakers-b")
                   .code == shitate::AudioErrorCode::previewOutputChanged);
        expect(shitate::DeviceService::validateConfiguration(validPreviewConfiguration(),
                                                             previewDevices)
                   .code == shitate::AudioErrorCode::previewOutputUnavailable);

        beginTest("preview rejects BlackHole, aggregate, dead, mono, and incompatible outputs");
        auto previewToBlackHole = validPreviewConfiguration();
        previewToBlackHole.outputDeviceUID = "blackhole-a";
        expect(shitate::DeviceService::validateConfiguration(previewToBlackHole, previewDevices,
                                                             "blackhole-a")
                   .code == shitate::AudioErrorCode::previewOutputUnavailable);

        auto aggregateOutput = previewDevices;
        aggregateOutput[2].aggregate = true;
        expect(shitate::DeviceService::validateConfiguration(validPreviewConfiguration(),
                                                             aggregateOutput, "speakers-a")
                   .code == shitate::AudioErrorCode::previewOutputUnavailable);

        auto virtualOutput = previewDevices;
        virtualOutput[2].physical = false;
        expect(shitate::DeviceService::validateConfiguration(validPreviewConfiguration(),
                                                             virtualOutput, "speakers-a")
                   .code == shitate::AudioErrorCode::previewOutputUnavailable);

        auto deadOutput = previewDevices;
        deadOutput[2].alive = false;
        expect(shitate::DeviceService::validateConfiguration(validPreviewConfiguration(),
                                                             deadOutput, "speakers-a")
                   .code == shitate::AudioErrorCode::previewOutputUnavailable);

        auto monoOutput = previewDevices;
        monoOutput[2].outputChannelNames = {"Mono"};
        expect(shitate::DeviceService::validateConfiguration(validPreviewConfiguration(),
                                                             monoOutput, "speakers-a")
                   .code == shitate::AudioErrorCode::previewOutputUnavailable);

        auto wrongRate = previewDevices;
        wrongRate[2].sampleRates = {44100.0};
        expect(shitate::DeviceService::validateConfiguration(validPreviewConfiguration(), wrongRate,
                                                             "speakers-a")
                   .code == shitate::AudioErrorCode::unsupportedSampleRate);

        auto wrongBuffer = previewDevices;
        wrongBuffer[2].allowedBufferFrames = {128};
        expect(shitate::DeviceService::validateConfiguration(validPreviewConfiguration(),
                                                             wrongBuffer, "speakers-a")
                   .code == shitate::AudioErrorCode::unsupportedBufferSize);

        auto manualPreview = validPreviewConfiguration();
        manualPreview.mode = shitate::RoutingMode::manualAggregate;
        expect(shitate::DeviceService::validateConfiguration(manualPreview, previewDevices,
                                                             "speakers-a")
                   .code == shitate::AudioErrorCode::invalidConfiguration);

        beginTest("manual mode requires one explicit aggregate and channel offsets");
        auto aggregate = inputDevice("aggregate");
        aggregate.aggregate = true;
        aggregate.outputChannelNames = {"Mic 1", "Mic 2", "BlackHole 1", "BlackHole 2"};
        auto manual = validConfiguration();
        manual.mode = shitate::RoutingMode::manualAggregate;
        manual.inputDeviceUID = "aggregate";
        manual.outputDeviceUID = "aggregate";
        manual.manualOutputChannelStart = 2;
        expect(shitate::DeviceService::validateConfiguration(manual,
                                                             {aggregate, blackHole("blackhole-a")})
                   .succeeded());

        beginTest("manual mode accepts only verified BlackHole-owned output channels");
        const shitate::ManualAggregateEvidence validEvidence{
            .aggregateFound = true,
            .blackHolePresent = true,
            .outputOwnsClock = true,
            .selectedInputIsPhysical = true,
            .inputDriftCompensated = true,
            .outputChannelsOwnedByBlackHole = true,
            .selectedInputSubdeviceUID = "input-a",
            .orderedSubdeviceUIDs = {"input-a", "blackhole-a"},
        };
        expect(shitate::DeviceService::validateManualAggregateEvidence(validEvidence).succeeded());
        auto speakerOutput = validEvidence;
        speakerOutput.outputChannelsOwnedByBlackHole = false;
        expect(shitate::DeviceService::validateManualAggregateEvidence(speakerOutput).code ==
               shitate::AudioErrorCode::invalidConfiguration);
        auto wrongClock = validEvidence;
        wrongClock.outputOwnsClock = false;
        expect(shitate::DeviceService::validateManualAggregateEvidence(wrongClock).code ==
               shitate::AudioErrorCode::invalidConfiguration);

        beginTest("manual routing never requires private automatic aggregate evidence");
        const shitate::AggregateEvidence validAutomaticEvidence{
            .aggregateFound = true,
            .privateDevice = true,
            .outputOwnsClock = true,
            .inputDriftCompensated = true,
            .inputPresent = true,
            .outputPresent = true,
            .subdevicesMatch = true,
        };
        expect(shitate::DeviceService::validateRoutingEvidence(
                   shitate::RoutingMode::automaticPrivateAggregate, validAutomaticEvidence, {})
                   .succeeded());
        expect(shitate::DeviceService::validateRoutingEvidence(
                   shitate::RoutingMode::manualAggregate, {}, validEvidence)
                   .succeeded());
        expect(shitate::DeviceService::validateRoutingEvidence(
                   shitate::RoutingMode::automaticPrivateAggregate, {}, validEvidence)
                   .code == shitate::AudioErrorCode::aggregateDeviceCreationFailed);
        expect(shitate::DeviceService::validateRoutingEvidence(
                   shitate::RoutingMode::manualAggregate, validAutomaticEvidence, speakerOutput)
                   .code == shitate::AudioErrorCode::invalidConfiguration);
    }
};

DeviceServiceTest deviceServiceTest;

} // namespace
