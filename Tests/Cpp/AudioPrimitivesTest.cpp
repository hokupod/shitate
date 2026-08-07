// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Audio/InputMapper.h"
#include "Audio/MasterOutputStage.h"
#include "Audio/MeterAccumulator.h"
#include "Audio/OutputSafetyProcessor.h"

#include <array>
#include <cmath>
#include <juce_core/juce_core.h>
#include <limits>

namespace {

class InputMapperTest final : public juce::UnitTest {
  public:
    InputMapperTest() : juce::UnitTest("InputMapper", "Shitate") {}

    void runTest() override {
        shitate::InputMapper mapper;
        mapper.prepare(1024);
        juce::AudioBuffer<float> buffer(2, 1024);
        const std::array source{0.25F, -0.5F, 1.0F};

        beginTest("copies selected mono input to both output channels");
        mapper.mapMonoToDualMono(source.data(), static_cast<int>(source.size()), buffer);
        for (auto channel = 0; channel < 2; ++channel) {
            for (std::size_t frame = 0; frame < source.size(); ++frame) {
                expectEquals(buffer.getSample(channel, static_cast<int>(frame)), source[frame]);
            }
        }

        beginTest("null input is silence");
        buffer.applyGain(0, 3, 2.0F);
        mapper.mapMonoToDualMono(nullptr, 3, buffer);
        expect(buffer.getMagnitude(0, 3) == 0.0F);

        beginTest("zero frames does not touch storage");
        buffer.setSample(0, 0, 0.75F);
        mapper.mapMonoToDualMono(source.data(), 0, buffer);
        expectEquals(buffer.getSample(0, 0), 0.75F);
    }
};

class MeterTest final : public juce::UnitTest {
  public:
    MeterTest() : juce::UnitTest("Meter", "Shitate") {}

    void runTest() override {
        shitate::MeterAccumulator meter;
        meter.prepare();
        juce::AudioBuffer<float> buffer(2, 4);

        beginTest("reports peak RMS and signal at the dBFS floor");
        buffer.clear();
        buffer.applyGain(0.5F);
        for (auto channel = 0; channel < 2; ++channel) {
            for (auto frame = 0; frame < 4; ++frame) {
                buffer.setSample(channel, frame, 0.5F);
            }
        }
        meter.process(buffer, 4);
        const auto half = meter.snapshot();
        expectWithinAbsoluteError(half.peakDb, -6.0206F, 0.001F);
        expectWithinAbsoluteError(half.rmsDb, -6.0206F, 0.001F);
        expect(half.signalPresent);
        expect(!half.clipping);

        beginTest("silence uses minus 96 dBFS");
        buffer.clear();
        meter.process(buffer, 4);
        const auto silence = meter.snapshot();
        expectEquals(silence.peakDb, -96.0F);
        expectEquals(silence.rmsDb, -96.0F);
        expect(!silence.signalPresent);

        beginTest("non-finite values do not poison metering");
        buffer.setSample(0, 0, std::numeric_limits<float>::quiet_NaN());
        buffer.setSample(1, 0, 1.0F);
        meter.process(buffer, 1);
        const auto finite = meter.snapshot();
        expect(std::isfinite(finite.peakDb));
        expect(finite.clipping);
    }
};

class OutputSafetyTest final : public juce::UnitTest {
  public:
    OutputSafetyTest() : juce::UnitTest("OutputSafety", "Shitate") {}

    void runTest() override {
        shitate::OutputSafetyProcessor safety;
        safety.prepare(1024);
        juce::AudioBuffer<float> buffer(2, 6);
        const std::array values{
            std::numeric_limits<float>::quiet_NaN(),
            std::numeric_limits<float>::infinity(),
            std::numeric_limits<float>::denorm_min(),
            2.0F,
            -2.0F,
            0.5F,
        };
        for (auto channel = 0; channel < 2; ++channel) {
            for (std::size_t frame = 0; frame < values.size(); ++frame) {
                buffer.setSample(channel, static_cast<int>(frame), values[frame]);
            }
        }

        beginTest("replaces non-finite and denormal values then clamps");
        safety.process(buffer, static_cast<int>(values.size()));
        for (auto channel = 0; channel < 2; ++channel) {
            expectEquals(buffer.getSample(channel, 0), 0.0F);
            expectEquals(buffer.getSample(channel, 1), 0.0F);
            expectEquals(buffer.getSample(channel, 2), 0.0F);
            expectEquals(buffer.getSample(channel, 3), 1.0F);
            expectEquals(buffer.getSample(channel, 4), -1.0F);
            expectEquals(buffer.getSample(channel, 5), 0.5F);
        }
    }
};

class MasterOutputTest final : public juce::UnitTest {
  public:
    MasterOutputTest() : juce::UnitTest("MasterOutput", "Shitate") {}

    void runTest() override {
        shitate::MasterOutputStage stage;
        stage.prepare(1000.0);
        juce::AudioBuffer<float> buffer(2, 10);

        beginTest("start fade reaches unity in ten milliseconds");
        fill(buffer, 1.0F, 10);
        stage.beginStart();
        stage.process(buffer, 10);
        expectWithinAbsoluteError(buffer.getSample(0, 0), 0.1F, 0.0001F);
        expectWithinAbsoluteError(buffer.getSample(0, 9), 1.0F, 0.0001F);
        expect(!stage.isTransportSilent());

        beginTest("mute fade reaches silence in five milliseconds");
        fill(buffer, 1.0F, 5);
        stage.setMuted(true);
        stage.process(buffer, 5);
        expectWithinAbsoluteError(buffer.getSample(0, 4), 0.0F, 0.0001F);
        expect(stage.isMuted());

        beginTest("unmute and stop ramps preserve continuity");
        fill(buffer, 1.0F, 5);
        stage.setMuted(false);
        stage.process(buffer, 5);
        expectWithinAbsoluteError(buffer.getSample(0, 4), 1.0F, 0.0001F);
        fill(buffer, 1.0F, 10);
        stage.beginStop();
        stage.process(buffer, 10);
        expectWithinAbsoluteError(buffer.getSample(0, 9), 0.0F, 0.0001F);
        expect(stage.isTransportSilent());
    }

  private:
    static void fill(juce::AudioBuffer<float>& buffer, float value, int frames) {
        for (auto channel = 0; channel < buffer.getNumChannels(); ++channel) {
            for (auto frame = 0; frame < frames; ++frame) {
                buffer.setSample(channel, frame, value);
            }
        }
    }
};

InputMapperTest inputMapperTest;
MeterTest meterTest;
OutputSafetyTest outputSafetyTest;
MasterOutputTest masterOutputTest;

} // namespace
