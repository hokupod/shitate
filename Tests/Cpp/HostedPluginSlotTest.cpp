// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "PluginRuntimeTestSupport.h"
#include "TestAllocationTracker.h"

#include <juce_core/juce_core.h>

namespace {

class HostedPluginSlotTest final : public juce::UnitTest {
  public:
    HostedPluginSlotTest() : UnitTest("HostedPluginSlot", "Shitate") {}

    void runTest() override {
        shitate::RealtimeEventQueue queue;
        juce::AudioBuffer<float> buffer(2, shitate::maximumPluginFrames);
        juce::MidiBuffer midi;

        beginTest("gain, bypass, and state round-trip preserve slot identity");
        auto slot = shitate::test::makeSlot(
            queue, 1, {.multiplier = 0.5F, .offset = 0.125F, .latencySamples = 64});
        expect(
            slot->prepare(shitate::requiredSampleRate, shitate::maximumPluginFrames).succeeded());
        expect(slot->id() == shitate::test::slotID(1));
        expectEquals(slot->latencySamples(), 64);
        shitate::test::fill(buffer, 0.5F, 128);
        slot->process(buffer, midi, 128);
        expectWithinAbsoluteError(buffer.getSample(0, 0), 0.375F, 0.0001F);

        slot->setBypassed(true);
        shitate::test::fill(buffer, 0.25F, 128);
        slot->process(buffer, midi, 128);
        expectWithinAbsoluteError(buffer.getSample(0, 0), 0.25F, 0.0001F);
        slot->setBypassed(false);

        const auto saved = slot->serializeState();
        expect(saved.result.succeeded());
        const std::array<float, 2> replacement{0.25F, 0.0F};
        expect(slot->restoreState(replacement.data(), sizeof(replacement)).succeeded());
        shitate::test::fill(buffer, 0.8F, 128);
        slot->process(buffer, midi, 128);
        expectWithinAbsoluteError(buffer.getSample(0, 0), 0.2F, 0.0001F);
        expect(slot->restoreState(saved.data.data(), saved.data.size()).succeeded());
        shitate::test::fill(buffer, 0.5F, 128);
        slot->process(buffer, midi, 128);
        expectWithinAbsoluteError(buffer.getSample(0, 0), 0.375F, 0.0001F);

        beginTest("non-finite output restores input and coalesces one fault event");
        auto nonFinite = shitate::test::makeSlot(queue, 2, {.emitNonFinite = true});
        nonFinite->setEventKey(42);
        expect(nonFinite->prepare(shitate::requiredSampleRate, shitate::maximumPluginFrames)
                   .succeeded());
        shitate::test::fill(buffer, 0.375F, 512);
        nonFinite->process(buffer, midi, 512);
        expect(nonFinite->hasRuntimeFault());
        expectWithinAbsoluteError(buffer.getSample(0, 0), 0.375F, 0.0001F);
        expectWithinAbsoluteError(buffer.getSample(1, 511), 0.375F, 0.0001F);
        nonFinite->process(buffer, midi, 512);
        shitate::CoreEvent event;
        auto faultEvents = 0;
        while (queue.pop(event)) {
            if (event.type == shitate::CoreEventType::pluginSlotFaulted) {
                ++faultEvents;
                expectEquals(event.value, 42);
            }
        }
        expectEquals(faultEvents, 1);

        beginTest("throwing output restores input and repeated faults remain bypassed");
        auto throwing = shitate::test::makeSlot(queue, 3, {.throwDuringProcess = true});
        throwing->setEventKey(43);
        expect(throwing->prepare(shitate::requiredSampleRate, shitate::maximumPluginFrames)
                   .succeeded());
        shitate::test::fill(buffer, -0.25F, 256);
        throwing->process(buffer, midi, 256);
        expect(throwing->hasRuntimeFault());
        expectWithinAbsoluteError(buffer.getSample(0, 0), -0.25F, 0.0001F);
        throwing->process(buffer, midi, 256);
        faultEvents = 0;
        while (queue.pop(event)) {
            faultEvents += event.type == shitate::CoreEventType::pluginSlotFaulted ? 1 : 0;
        }
        expectEquals(faultEvents, 1);

        beginTest("prepared slot processing performs no allocation");
        auto realtime = shitate::test::makeSlot(queue, 4, {.multiplier = 0.75F});
        expect(realtime->prepare(shitate::requiredSampleRate, shitate::maximumPluginFrames)
                   .succeeded());
        shitate::test::fill(buffer, 0.5F, 512);
        realtime->process(buffer, midi, 512);
        const auto before = shitate::test::allocationCount();
        realtime->process(buffer, midi, 512);
        const auto after = shitate::test::allocationCount();
        expectEquals(after, before);

        beginTest("state size and runtime format are bounded");
        expect(!realtime->restoreState(nullptr, 1).succeeded());
        expect(!realtime->restoreState(nullptr, shitate::HostedPluginSlot::maximumStateBytes + 1)
                    .succeeded());
        expect(!realtime->prepare(44'100.0, shitate::maximumPluginFrames).succeeded());
    }
};

HostedPluginSlotTest hostedPluginSlotTest;

} // namespace
