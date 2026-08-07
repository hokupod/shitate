// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "TestPluginProcessor.h"

#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <stdexcept>
#include <string_view>
#include <thread>

#ifndef SHITATE_TEST_PLUGIN_KIND
#error "SHITATE_TEST_PLUGIN_KIND must be provided by CMake"
#endif

namespace {

enum TestPluginKind {
    gain = 0,
    latency = 1,
    nonFinite = 2,
    throwing = 3,
    crashing = 4,
    hanging = 5,
    monoOnly = 6,
    instrument = 7,
};

constexpr auto kind = static_cast<TestPluginKind>(SHITATE_TEST_PLUGIN_KIND);

[[maybe_unused, nodiscard]] bool dangerousBehaviorEnabled(std::string_view expected) {
    const auto* value = std::getenv("SHITATE_TEST_PLUGIN_BEHAVIOR");
    return value != nullptr && std::string_view(value) == expected;
}

} // namespace

juce::AudioProcessor::BusesProperties ShitateTestPluginProcessor::buses() {
    BusesProperties properties;
    if constexpr (kind == instrument) {
        return properties.withOutput("Output", juce::AudioChannelSet::stereo(), true);
    }
    if constexpr (kind == monoOnly) {
        return properties.withInput("Input", juce::AudioChannelSet::mono(), true)
            .withOutput("Output", juce::AudioChannelSet::mono(), true);
    }
    if constexpr (kind == gain) {
        return properties.withInput("Input", juce::AudioChannelSet::mono(), true)
            .withOutput("Output", juce::AudioChannelSet::mono(), true);
    }
    return properties.withInput("Input", juce::AudioChannelSet::stereo(), true)
        .withOutput("Output", juce::AudioChannelSet::stereo(), true);
}

ShitateTestPluginProcessor::ShitateTestPluginProcessor() : AudioProcessor(buses()) {
    if constexpr (kind == gain) {
        gainParameter_ = new juce::AudioParameterFloat(
            juce::ParameterID{"gain", 1}, "Gain", juce::NormalisableRange<float>{0.0F, 2.0F}, 0.5F);
        addParameter(gainParameter_);
    }
}

void ShitateTestPluginProcessor::prepareToPlay(double, int) {
    if constexpr (kind == latency) {
        setLatencySamples(64);
    }
}

void ShitateTestPluginProcessor::releaseResources() {}

bool ShitateTestPluginProcessor::isBusesLayoutSupported(const BusesLayout& layouts) const {
    if constexpr (kind == instrument) {
        return layouts.getMainInputChannelSet().isDisabled() &&
               layouts.getMainOutputChannelSet() == juce::AudioChannelSet::stereo();
    }
    if constexpr (kind == gain) {
        const auto input = layouts.getMainInputChannelSet();
        return input == layouts.getMainOutputChannelSet() &&
               (input == juce::AudioChannelSet::mono() || input == juce::AudioChannelSet::stereo());
    }
    const auto expected =
        kind == monoOnly ? juce::AudioChannelSet::mono() : juce::AudioChannelSet::stereo();
    return layouts.getMainInputChannelSet() == expected &&
           layouts.getMainOutputChannelSet() == expected;
}

void ShitateTestPluginProcessor::processBlock(juce::AudioBuffer<float>& buffer, juce::MidiBuffer&) {
    juce::ScopedNoDenormals noDenormals;
    if constexpr (kind == gain) {
        buffer.applyGain(gainParameter_ != nullptr ? gainParameter_->get() : 0.5F);
    } else if constexpr (kind == nonFinite) {
        if (buffer.getNumChannels() > 0 && buffer.getNumSamples() > 0) {
            buffer.setSample(0, 0, std::numeric_limits<float>::quiet_NaN());
        }
    } else if constexpr (kind == throwing) {
        throw std::runtime_error("intentional scanner fixture exception");
    } else if constexpr (kind == crashing) {
        if (dangerousBehaviorEnabled("Crash")) {
            std::abort();
        }
    } else if constexpr (kind == hanging) {
        if (dangerousBehaviorEnabled("Hang")) {
            while (true) {
                std::this_thread::sleep_for(std::chrono::seconds(1));
            }
        }
    } else if constexpr (kind == instrument) {
        buffer.clear();
    }
}

juce::AudioProcessorEditor* ShitateTestPluginProcessor::createEditor() {
    return nullptr;
}

bool ShitateTestPluginProcessor::hasEditor() const {
    return false;
}

const juce::String ShitateTestPluginProcessor::getName() const {
    return JucePlugin_Name;
}

bool ShitateTestPluginProcessor::acceptsMidi() const {
    return false;
}

bool ShitateTestPluginProcessor::producesMidi() const {
    return false;
}

bool ShitateTestPluginProcessor::isMidiEffect() const {
    return false;
}

double ShitateTestPluginProcessor::getTailLengthSeconds() const {
    return 0.0;
}

int ShitateTestPluginProcessor::getNumPrograms() {
    return 1;
}

int ShitateTestPluginProcessor::getCurrentProgram() {
    return 0;
}

void ShitateTestPluginProcessor::setCurrentProgram(int) {}

const juce::String ShitateTestPluginProcessor::getProgramName(int) {
    return "Default";
}

void ShitateTestPluginProcessor::changeProgramName(int, const juce::String&) {}

void ShitateTestPluginProcessor::getStateInformation(juce::MemoryBlock& destinationData) {
    if constexpr (kind == gain) {
        const auto gainValue = gainParameter_ != nullptr ? gainParameter_->get() : 0.5F;
        destinationData.replaceAll(&gainValue, sizeof(gainValue));
        return;
    }
    const std::uint8_t state = static_cast<std::uint8_t>(kind);
    destinationData.replaceAll(&state, sizeof(state));
}

void ShitateTestPluginProcessor::setStateInformation(const void* data, int sizeInBytes) {
    if constexpr (kind == gain) {
        if (data == nullptr || sizeInBytes != static_cast<int>(sizeof(float))) {
            return;
        }
        float restored = 0.0F;
        std::memcpy(&restored, data, sizeof(restored));
        if (gainParameter_ != nullptr && std::isfinite(restored) && restored >= 0.0F &&
            restored <= 2.0F) {
            *gainParameter_ = restored;
        }
    }
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter() {
    return new ShitateTestPluginProcessor();
}
