// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Audio/AudioBridgeController.h"

#include <algorithm>
#include <charconv>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <optional>
#include <string_view>
#include <thread>

namespace {

constexpr int skipped = 77;

bool enabled() {
    const auto* value = std::getenv("SHITATE_RUN_AUDIO_HARDWARE_TESTS");
    return value != nullptr && std::string_view(value) == "1";
}

bool previewEnabled() {
    const auto* value = std::getenv("SHITATE_TEST_PREVIEW");
    return value != nullptr && std::string_view(value) == "1";
}

const shitate::AudioDeviceInfo* findByUID(const std::vector<shitate::AudioDeviceInfo>& devices,
                                          std::string_view uid) {
    const auto found = std::find_if(devices.begin(), devices.end(),
                                    [uid](const auto& device) { return device.uid == uid; });
    return found == devices.end() ? nullptr : &*found;
}

const shitate::AudioDeviceInfo*
findUniquePhysicalInputByName(const std::vector<shitate::AudioDeviceInfo>& devices,
                              std::string_view name) {
    const shitate::AudioDeviceInfo* result = nullptr;
    for (const auto& device : devices) {
        if (!device.alive || !device.hasInputs() || device.aggregate || !device.physical ||
            device.displayName != name) {
            continue;
        }
        if (result != nullptr) {
            return nullptr;
        }
        result = &device;
    }
    return result;
}

const shitate::AudioDeviceInfo*
findBlackHole(const std::vector<shitate::AudioDeviceInfo>& devices) {
    const shitate::AudioDeviceInfo* result = nullptr;
    for (const auto& device : devices) {
        if (!device.alive || !device.hasOutputs() || device.displayName != "BlackHole 2ch") {
            continue;
        }
        if (result != nullptr) {
            return nullptr;
        }
        result = &device;
    }
    return result;
}

int preferredBuffer(const shitate::AudioDeviceInfo& input, const shitate::AudioDeviceInfo& output) {
    for (const auto candidate : {256, 128, 512}) {
        if (std::find(input.allowedBufferFrames.begin(), input.allowedBufferFrames.end(),
                      candidate) != input.allowedBufferFrames.end() &&
            std::find(output.allowedBufferFrames.begin(), output.allowedBufferFrames.end(),
                      candidate) != output.allowedBufferFrames.end()) {
            return candidate;
        }
    }
    return 0;
}

int requestedBuffer() {
    const auto* value = std::getenv("SHITATE_TEST_BUFFER_FRAMES");
    if (value == nullptr || std::string_view(value).empty()) {
        return 0;
    }

    const auto text = std::string_view(value);
    auto parsed = 0;
    const auto result = std::from_chars(text.data(), text.data() + text.size(), parsed);
    if (result.ec != std::errc{} || result.ptr != text.data() + text.size() ||
        (parsed != 128 && parsed != 256 && parsed != 512)) {
        return -1;
    }
    return parsed;
}

} // namespace

int main() {
    if (!enabled()) {
        std::cerr << "SKIP: set SHITATE_RUN_AUDIO_HARDWARE_TESTS=1 for explicit hardware QA\n";
        return skipped;
    }

    const auto* inputUID = std::getenv("SHITATE_TEST_INPUT_UID");
    const auto* inputName = std::getenv("SHITATE_TEST_INPUT_NAME");
    if ((inputUID == nullptr || std::string_view(inputUID).empty()) &&
        (inputName == nullptr || std::string_view(inputName).empty())) {
        std::cerr << "SKIP: set one private input selector; selectors are never printed\n";
        return skipped;
    }

    shitate::AudioBridgeController controller;
    const auto devices = controller.enumerateDevices();
    const auto* input = inputUID != nullptr && !std::string_view(inputUID).empty()
                            ? findByUID(devices, inputUID)
                            : findUniquePhysicalInputByName(devices, inputName);
    const auto* blackHole = findBlackHole(devices);
    if (input == nullptr || !input->alive || !input->hasInputs() || input->aggregate ||
        !input->physical) {
        const auto requestedName =
            inputName == nullptr ? std::string_view{} : std::string_view(inputName);
        const auto matchingNames =
            std::count_if(devices.begin(), devices.end(),
                          [&](const auto& device) { return device.displayName == requestedName; });
        const auto matchingPhysicalInputs =
            std::count_if(devices.begin(), devices.end(), [&](const auto& device) {
                return device.displayName == requestedName && device.alive && device.hasInputs() &&
                       !device.aggregate && device.physical;
            });
        std::cerr << "SKIP: requested physical input is unavailable; nameMatches=" << matchingNames
                  << " usableMatches=" << matchingPhysicalInputs << '\n';
        return skipped;
    }
    if (blackHole == nullptr) {
        std::cerr << "SKIP: BlackHole 2ch is unavailable\n";
        return skipped;
    }

    const auto preview = previewEnabled();
    const auto defaultOutput =
        preview ? controller.defaultOutputDevice() : std::optional<shitate::AudioDeviceInfo>{};
    const auto* output = preview && defaultOutput.has_value() ? &*defaultOutput : blackHole;
    if (preview &&
        (!defaultOutput.has_value() || !output->alive || !output->physical || output->aggregate ||
         output->outputChannelNames.size() < 2 || output->uid == blackHole->uid)) {
        std::cerr << "SKIP: the current macOS default output is not a supported Preview target\n";
        return skipped;
    }
    const auto requestedBufferFrames = requestedBuffer();
    if (requestedBufferFrames < 0) {
        std::cerr << "FAIL: SHITATE_TEST_BUFFER_FRAMES must be 128, 256, or 512\n";
        return 1;
    }
    const auto bufferFrames =
        requestedBufferFrames == 0 ? preferredBuffer(*input, *output) : requestedBufferFrames;
    if (bufferFrames == 0) {
        std::cerr << "SKIP: input and selected output have no shared allowed buffer\n";
        return skipped;
    }
    if (std::find(input->allowedBufferFrames.begin(), input->allowedBufferFrames.end(),
                  bufferFrames) == input->allowedBufferFrames.end() ||
        std::find(output->allowedBufferFrames.begin(), output->allowedBufferFrames.end(),
                  bufferFrames) == output->allowedBufferFrames.end()) {
        std::cerr << "SKIP: requested buffer is unsupported by this hardware pair\n";
        return skipped;
    }

    const shitate::AudioConfiguration configuration{
        .outputTarget = preview ? shitate::AudioOutputTarget::systemPreview
                                : shitate::AudioOutputTarget::blackHole,
        .inputDeviceUID = input->uid,
        .outputDeviceUID = output->uid,
        .blackHoleDeviceUID = blackHole->uid,
        .inputChannelIndex = 0,
        .sampleRate = shitate::requiredSampleRate,
        .bufferFrames = bufferFrames,
    };
    if (const auto result = controller.configure(configuration); !result.succeeded()) {
        std::cerr << "FAIL: automatic aggregate configuration failed with code "
                  << static_cast<int>(result.code) << '\n';
        return 1;
    }

    const auto evidence = controller.activeAggregateEvidence();
    std::cout << "aggregateFound=" << evidence.aggregateFound
              << " private=" << evidence.privateDevice
              << " outputClock=" << evidence.outputOwnsClock
              << " inputDrift=" << evidence.inputDriftCompensated
              << " inputPresent=" << evidence.inputPresent
              << " outputPresent=" << evidence.outputPresent
              << " subdevicesMatch=" << evidence.subdevicesMatch << '\n';
    if (!evidence.aggregateFound || !evidence.privateDevice || !evidence.outputOwnsClock ||
        !evidence.inputDriftCompensated || !evidence.inputPresent || !evidence.outputPresent ||
        !evidence.subdevicesMatch) {
        std::cerr << "FAIL: private aggregate evidence is incomplete\n";
        return 1;
    }

    if (preview) {
        controller.setMasterMuted(true);
    }
    if (const auto result = controller.start(); !result.succeeded()) {
        std::cerr << "FAIL: hardware routing start failed with code "
                  << static_cast<int>(result.code) << '\n';
        return 1;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(250));
    const auto diagnostics = controller.diagnostics();
    std::cout << "target=" << (preview ? "preview" : "blackhole") << " masterMuted=" << preview
              << " sampleRate=" << diagnostics.sampleRate
              << " bufferFrames=" << diagnostics.bufferFrames
              << " inputLatencySamples=" << diagnostics.inputLatencySamples
              << " outputLatencySamples=" << diagnostics.outputLatencySamples
              << " xruns=" << diagnostics.xrunCount << '\n';
    if (diagnostics.sampleRate != shitate::requiredSampleRate ||
        diagnostics.bufferFrames != bufferFrames || diagnostics.xrunCount != 0) {
        controller.failClosed();
        std::cerr << "FAIL: CoreAudio did not preserve the requested short-run contract\n";
        return 1;
    }

    controller.stop();
    std::this_thread::sleep_for(std::chrono::milliseconds(60));
    shitate::CoreEvent event;
    while (controller.popEvent(event)) {
    }

    if (controller.status() != shitate::EngineStatus::configured) {
        std::cerr << "FAIL: asynchronous stop did not complete\n";
        return 1;
    }
    return 0;
}
