// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Audio/AudioEngine.h"
#include "PluginRuntimeTestSupport.h"
#include "TestAllocationTracker.h"

#include <algorithm>
#include <array>
#include <juce_core/juce_core.h>

namespace {

class PluginRuntimeAudioTest final : public juce::UnitTest {
  public:
    PluginRuntimeAudioTest() : UnitTest("PluginRuntimeAudio", "Shitate") {}

    void runTest() override {
        beginTest("runtime chain prepares through the AudioEngine insertion point");
        shitate::RealtimeEventQueue queue;
        shitate::PluginChain chain;
        auto firstProbe = std::make_shared<shitate::test::ProcessorProbe>();
        auto secondProbe = std::make_shared<shitate::test::ProcessorProbe>();
        expect(chain
                   .addSlot(shitate::test::makeSlot(
                       queue, 1, {.multiplier = 0.5F, .latencySamples = 32, .probe = firstProbe}))
                   .succeeded());
        expect(chain
                   .addSlot(shitate::test::makeSlot(
                       queue, 2, {.multiplier = 0.5F, .latencySamples = 64, .probe = secondProbe}))
                   .succeeded());
        shitate::AudioEngine engine(queue, &chain);
        engine.prepareForTesting(shitate::requiredSampleRate);
        engine.setRunningForTesting(true);

        std::array<float, shitate::maximumCallbackFrames> input{};
        std::array<float, shitate::maximumCallbackFrames> left{};
        std::array<float, shitate::maximumCallbackFrames> right{};
        input.fill(0.4F);
        const float* inputs[]{input.data()};
        float* outputs[]{left.data(), right.data()};
        const juce::AudioIODeviceCallbackContext context{};
        engine.audioDeviceIOCallbackWithContext(inputs, 1, outputs, 2, 512, context);

        beginTest("runtime chain processes every callback boundary in chunks of at most 512");
        for (const auto frames : {128, 256, 512, 513, 1024}) {
            left.fill(-1.0F);
            right.fill(-1.0F);
            engine.audioDeviceIOCallbackWithContext(inputs, 1, outputs, 2, frames, context);
            for (int frame = 0; frame < frames; ++frame) {
                expectWithinAbsoluteError(left[static_cast<std::size_t>(frame)], 0.1F, 0.0001F);
                expectWithinAbsoluteError(right[static_cast<std::size_t>(frame)], 0.1F, 0.0001F);
            }
        }
        expect(firstProbe->maximumFrames <= shitate::maximumPluginFrames);
        expect(secondProbe->maximumFrames <= shitate::maximumPluginFrames);
        expect(firstProbe->processCalls > 5);
        expect(secondProbe->processCalls > 5);

        beginTest("plugin and aggregate latency remain separately observable");
        const auto diagnostics = engine.diagnostics();
        expectEquals(diagnostics.pluginLatencySamples, 96);
        expectEquals(diagnostics.aggregateLatencySamples,
                     diagnostics.inputLatencySamples + diagnostics.outputLatencySamples + 96);

        beginTest("full callback with a prepared chain performs no allocation");
        const auto before = shitate::test::allocationCount();
        engine.audioDeviceIOCallbackWithContext(inputs, 1, outputs, 2, 1024, context);
        const auto after = shitate::test::allocationCount();
        expectEquals(after, before);
        engine.setRunningForTesting(false);

        beginTest("NaN and C++ throw slots each restore their input before later processing");
        shitate::RealtimeEventQueue faultQueue;
        shitate::PluginChain faultChain;
        expect(faultChain.addSlot(shitate::test::makeSlot(faultQueue, 3, {.emitNonFinite = true}))
                   .succeeded());
        expect(
            faultChain.addSlot(shitate::test::makeSlot(faultQueue, 4, {.throwDuringProcess = true}))
                .succeeded());
        expect(faultChain.addSlot(shitate::test::makeSlot(faultQueue, 5, {.multiplier = 0.5F}))
                   .succeeded());
        shitate::AudioEngine faultEngine(faultQueue, &faultChain);
        faultEngine.prepareForTesting(shitate::requiredSampleRate);
        faultEngine.setRunningForTesting(true);
        faultEngine.audioDeviceIOCallbackWithContext(inputs, 1, outputs, 2, 512, context);
        left.fill(-1.0F);
        right.fill(-1.0F);
        faultEngine.audioDeviceIOCallbackWithContext(inputs, 1, outputs, 2, 513, context);
        for (int frame = 0; frame < 513; ++frame) {
            expectWithinAbsoluteError(left[static_cast<std::size_t>(frame)], 0.2F, 0.0001F);
            expectWithinAbsoluteError(right[static_cast<std::size_t>(frame)], 0.2F, 0.0001F);
        }
        const auto snapshots = faultChain.snapshots();
        expect(snapshots[0].faulted);
        expect(snapshots[1].faulted);
        expect(!snapshots[2].faulted);
        shitate::CoreEvent event;
        auto faults = 0;
        while (faultEngine.popEvent(event)) {
            faults += event.type == shitate::CoreEventType::pluginSlotFaulted ? 1 : 0;
        }
        expectEquals(faults, 2);

        beginTest("overflow coalesces fault notifications without losing faulted slot identities");
        shitate::RealtimeEventQueue overflowQueue;
        for (std::size_t index = 0; index < shitate::RealtimeEventQueue::capacity; ++index) {
            expect(overflowQueue.push({.type = shitate::CoreEventType::devicesChanged,
                                       .value = static_cast<int>(index)}));
        }
        shitate::PluginChain overflowChain;
        expect(overflowChain
                   .addSlot(shitate::test::makeSlot(overflowQueue, 6, {.emitNonFinite = true}))
                   .succeeded());
        expect(overflowChain
                   .addSlot(shitate::test::makeSlot(overflowQueue, 7, {.throwDuringProcess = true}))
                   .succeeded());
        expect(overflowChain.prepare().succeeded());
        overflowChain.setRunning(true);
        juce::AudioBuffer<float> overflowBuffer(2, 128);
        juce::MidiBuffer overflowMidi;
        shitate::test::fill(overflowBuffer, 0.25F, 128);
        overflowChain.process(overflowBuffer, overflowMidi, 128);
        const auto overflowSnapshots = overflowChain.snapshots();
        expect(overflowSnapshots[0].faulted);
        expect(overflowSnapshots[1].faulted);
        auto invalidations = 0;
        while (overflowQueue.pop(event)) {
            invalidations += event.type == shitate::CoreEventType::pluginSlotFaulted ? 1 : 0;
        }
        expectEquals(invalidations, 1);
    }
};

PluginRuntimeAudioTest pluginRuntimeAudioTest;

} // namespace
