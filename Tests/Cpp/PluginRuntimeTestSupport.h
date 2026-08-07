// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include "Audio/HostedPluginSlot.h"
#include "Audio/RealtimeEventQueue.h"
#include "Plugins/PluginCatalog.h"

#include <array>
#include <atomic>
#include <cmath>
#include <cstring>
#include <juce_audio_processors/juce_audio_processors.h>
#include <limits>
#include <memory>
#include <stdexcept>
#include <thread>

namespace shitate::test {

struct ProcessorProbe final {
    int prepareCalls{0};
    int releaseCalls{0};
    int processCalls{0};
    int maximumFrames{0};
};

struct TestProcessorOptions final {
    float multiplier{1.0F};
    float offset{0.0F};
    bool emitNonFinite{false};
    bool throwDuringProcess{false};
    bool throwDuringPrepare{false};
    bool supportsStereo{true};
    bool providesEditor{false};
    int editorWidth{640};
    int editorHeight{480};
    int latencySamples{0};
    std::shared_ptr<ProcessorProbe> probe;
    std::atomic<bool>* processEntered{nullptr};
    std::atomic<bool>* processRelease{nullptr};
    std::atomic<bool>* releaseEntered{nullptr};
};

class TestProcessorEditor final : public juce::AudioProcessorEditor {
  public:
    TestProcessorEditor(juce::AudioProcessor& processor, int width, int height)
        : AudioProcessorEditor(processor) {
        setSize(width, height);
    }
};

class TestRuntimeProcessor final : public juce::AudioProcessor {
  public:
    explicit TestRuntimeProcessor(TestProcessorOptions options)
        : AudioProcessor(stereoBuses()), options_(std::move(options)) {}

    void prepareToPlay(double, int maximumBlockSize) override {
        if (options_.probe != nullptr) {
            ++options_.probe->prepareCalls;
            options_.probe->maximumFrames =
                std::max(options_.probe->maximumFrames, maximumBlockSize);
        }
        if (options_.throwDuringPrepare) {
            throw std::runtime_error("intentional prepare failure");
        }
        setLatencySamples(std::max(0, options_.latencySamples));
    }

    void releaseResources() override {
        if (options_.releaseEntered != nullptr) {
            options_.releaseEntered->store(true, std::memory_order_release);
        }
        if (options_.probe != nullptr) {
            ++options_.probe->releaseCalls;
        }
    }

    [[nodiscard]] bool isBusesLayoutSupported(const BusesLayout& layout) const override {
        return options_.supportsStereo &&
               layout.getMainInputChannelSet() == juce::AudioChannelSet::stereo() &&
               layout.getMainOutputChannelSet() == juce::AudioChannelSet::stereo();
    }

    void processBlock(juce::AudioBuffer<float>& buffer, juce::MidiBuffer&) override {
        if (options_.processEntered != nullptr) {
            options_.processEntered->store(true, std::memory_order_release);
        }
        while (options_.processRelease != nullptr &&
               !options_.processRelease->load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
        if (options_.probe != nullptr) {
            ++options_.probe->processCalls;
            options_.probe->maximumFrames =
                std::max(options_.probe->maximumFrames, buffer.getNumSamples());
        }
        if (options_.throwDuringProcess) {
            throw std::runtime_error("intentional process failure");
        }
        for (int channel = 0; channel < buffer.getNumChannels(); ++channel) {
            auto* samples = buffer.getWritePointer(channel);
            for (int frame = 0; frame < buffer.getNumSamples(); ++frame) {
                samples[frame] = samples[frame] * options_.multiplier + options_.offset;
            }
        }
        if (options_.emitNonFinite && buffer.getNumChannels() > 0 && buffer.getNumSamples() > 0) {
            buffer.setSample(0, 0, std::numeric_limits<float>::quiet_NaN());
        }
    }

    [[nodiscard]] juce::AudioProcessorEditor* createEditor() override {
        return options_.providesEditor
                   ? new TestProcessorEditor(*this, options_.editorWidth, options_.editorHeight)
                   : nullptr;
    }

    [[nodiscard]] bool hasEditor() const override {
        return options_.providesEditor;
    }

    [[nodiscard]] const juce::String getName() const override {
        return "RuntimeTestProcessor";
    }

    [[nodiscard]] bool acceptsMidi() const override {
        return false;
    }

    [[nodiscard]] bool producesMidi() const override {
        return false;
    }

    [[nodiscard]] bool isMidiEffect() const override {
        return false;
    }

    [[nodiscard]] double getTailLengthSeconds() const override {
        return 0.0;
    }

    [[nodiscard]] int getNumPrograms() override {
        return 1;
    }

    [[nodiscard]] int getCurrentProgram() override {
        return 0;
    }

    void setCurrentProgram(int) override {}

    [[nodiscard]] const juce::String getProgramName(int) override {
        return "Default";
    }

    void changeProgramName(int, const juce::String&) override {}

    void getStateInformation(juce::MemoryBlock& destinationData) override {
        const std::array state{options_.multiplier, options_.offset};
        destinationData.replaceAll(state.data(), sizeof(state));
    }

    void setStateInformation(const void* data, int sizeInBytes) override {
        if (data == nullptr || sizeInBytes != static_cast<int>(sizeof(float) * 2U)) {
            throw std::runtime_error("invalid test state");
        }
        std::array<float, 2> state{};
        std::memcpy(state.data(), data, sizeof(state));
        if (!std::isfinite(state[0]) || !std::isfinite(state[1])) {
            throw std::runtime_error("non-finite test state");
        }
        options_.multiplier = state[0];
        options_.offset = state[1];
    }

  private:
    [[nodiscard]] static BusesProperties stereoBuses() {
        return BusesProperties()
            .withInput("Input", juce::AudioChannelSet::stereo(), true)
            .withOutput("Output", juce::AudioChannelSet::stereo(), true);
    }

    TestProcessorOptions options_;
};

[[nodiscard]] inline plugins::SlotId slotID(std::uint8_t value) {
    std::array<std::uint8_t, plugins::SlotId::byteCount> bytes{};
    bytes.back() = value == 0 ? 1 : value;
    return plugins::SlotId(bytes);
}

[[nodiscard]] inline plugins::CatalogEntry catalogEntry(std::string path = "/tmp/Test.vst3") {
    plugins::CatalogEntry entry;
    entry.bundlePath = std::move(path);
    entry.classUID = "0123456789abcdef0123456789abcdef";
    entry.name = "Runtime Test";
    entry.manufacturer = "Shi-tate Tests";
    entry.version = "1.0.0";
    entry.codeDirectoryHash = "0123456789abcdef0123456789abcdef01234567";
    entry.teamIdentifier = "SHITATETEST";
    entry.signatureKind = plugins::SignatureKind::developerID;
    entry.architectures = {"arm64"};
    entry.inputChannels = plugins::requiredInputChannels;
    entry.outputChannels = plugins::requiredOutputChannels;
    entry.compatibility = plugins::PluginCompatibility::compatible;
    entry.bundleModificationTime = 1;
    entry.scannerProtocol = plugins::scannerProtocolVersion;
    entry.compatibleAppVersion = "0.1";
    entry.lastScannedAt = "2026-08-07T00:00:00Z";
    entry.fingerprint = plugins::pluginFingerprint(entry.bundlePath, entry.classUID,
                                                   entry.codeDirectoryHash, "arm64");
    return entry;
}

[[nodiscard]] inline std::unique_ptr<HostedPluginSlot>
makeSlot(RealtimeEventQueue& queue, std::uint8_t id, TestProcessorOptions options = {}) {
    return std::make_unique<HostedPluginSlot>(
        slotID(id), catalogEntry(), std::make_unique<TestRuntimeProcessor>(std::move(options)),
        queue);
}

inline void fill(juce::AudioBuffer<float>& buffer, float value, int frames) {
    for (int channel = 0; channel < buffer.getNumChannels(); ++channel) {
        for (int frame = 0; frame < frames; ++frame) {
            buffer.setSample(channel, frame, value);
        }
    }
}

} // namespace shitate::test
