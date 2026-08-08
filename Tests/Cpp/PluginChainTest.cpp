// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Audio/PluginChain.h"

#include "PluginRuntimeTestSupport.h"

#include <juce_core/juce_core.h>

namespace {

class PluginChainTest final : public juce::UnitTest {
  public:
    PluginChainTest() : UnitTest("PluginChain", "Shitate") {}

    void runTest() override {
        beginTest("empty through eight slots prepare and the ninth is rejected");
        shitate::RealtimeEventQueue capacityQueue;
        shitate::PluginChain capacity;
        expect(capacity.prepare().succeeded());
        expect(capacity.isPrepared());
        expect(capacity.isSessionComplete());
        for (std::uint8_t id = 1; id <= shitate::PluginChain::maximumSlots; ++id) {
            expect(capacity.addSlot(shitate::test::makeSlot(capacityQueue, id)).succeeded());
        }
        expectEquals(static_cast<int>(capacity.size()),
                     static_cast<int>(shitate::PluginChain::maximumSlots));
        expect(capacity.validateAdd(shitate::test::slotID(9)).error ==
               shitate::plugins::PluginRuntimeError::chainFull);
        const auto ninth = capacity.addSlot(shitate::test::makeSlot(capacityQueue, 9));
        expect(ninth.error == shitate::plugins::PluginRuntimeError::chainFull);
        expect(capacity.prepare().succeeded());

        beginTest("slot IDs are unique and every move boundary is deterministic");
        shitate::RealtimeEventQueue orderQueue;
        shitate::PluginChain order;
        expect(order.addSlot(shitate::test::makeSlot(orderQueue, 1)).succeeded());
        expect(order.addSlot(shitate::test::makeSlot(orderQueue, 2)).succeeded());
        expect(order.addSlot(shitate::test::makeSlot(orderQueue, 3)).succeeded());
        expect(order.validateAdd(shitate::test::slotID(2)).error ==
               shitate::plugins::PluginRuntimeError::duplicateSlot);
        const auto duplicate = order.addSlot(shitate::test::makeSlot(orderQueue, 2));
        expect(duplicate.error == shitate::plugins::PluginRuntimeError::duplicateSlot);
        expect(order.moveSlot(shitate::test::slotID(1), 2).succeeded());
        expectIDs(order, {2, 3, 1});
        expect(order.moveSlot(shitate::test::slotID(1), 0).succeeded());
        expectIDs(order, {1, 2, 3});
        expect(order.moveSlot(shitate::test::slotID(2), 1).succeeded());
        expectIDs(order, {1, 2, 3});
        expect(order.moveSlot(shitate::test::slotID(2), 3).error ==
               shitate::plugins::PluginRuntimeError::invalidMove);

        beginTest("prepare failure rolls back every prepared resource");
        shitate::RealtimeEventQueue rollbackQueue;
        shitate::PluginChain rollback;
        auto firstProbe = std::make_shared<shitate::test::ProcessorProbe>();
        auto secondProbe = std::make_shared<shitate::test::ProcessorProbe>();
        expect(rollback.addSlot(shitate::test::makeSlot(rollbackQueue, 1, {.probe = firstProbe}))
                   .succeeded());
        expect(rollback
                   .addSlot(shitate::test::makeSlot(
                       rollbackQueue, 2, {.throwDuringPrepare = true, .probe = secondProbe}))
                   .succeeded());
        expect(!rollback.prepare().succeeded());
        expect(!rollback.isPrepared());
        expect(!rollback.isSessionComplete());
        expectEquals(firstProbe->prepareCalls, 1);
        expectEquals(firstProbe->releaseCalls, 1);
        rollback.releaseResources();
        rollback.releaseResources();
        expectEquals(firstProbe->releaseCalls, 1);

        beginTest("terminal clear releases and destroys every slot exactly once");
        shitate::RealtimeEventQueue clearQueue;
        shitate::PluginChain clearChain;
        auto clearFirstProbe = std::make_shared<shitate::test::ProcessorProbe>();
        auto clearSecondProbe = std::make_shared<shitate::test::ProcessorProbe>();
        expect(
            clearChain.addSlot(shitate::test::makeSlot(clearQueue, 1, {.probe = clearFirstProbe}))
                .succeeded());
        expect(
            clearChain.addSlot(shitate::test::makeSlot(clearQueue, 2, {.probe = clearSecondProbe}))
                .succeeded());
        expect(clearChain.prepare().succeeded());
        clearChain.clearAfterCallbackQuiescence();
        expectEquals(static_cast<int>(clearChain.size()), 0);
        expect(!clearChain.isPrepared());
        expect(clearChain.isSessionComplete());
        expectEquals(clearFirstProbe->releaseCalls, 1);
        expectEquals(clearSecondProbe->releaseCalls, 1);
        expectEquals(clearFirstProbe->destructionCalls, 1);
        expectEquals(clearSecondProbe->destructionCalls, 1);
        clearChain.clearAfterCallbackQuiescence();
        expectEquals(clearFirstProbe->destructionCalls, 1);
        expectEquals(clearSecondProbe->destructionCalls, 1);

        beginTest("three slots process serially and bypass is atomic while running");
        shitate::RealtimeEventQueue processQueue;
        shitate::PluginChain process;
        expect(process
                   .addSlot(shitate::test::makeSlot(processQueue, 1,
                                                    {.multiplier = 2.0F, .offset = 1.0F}))
                   .succeeded());
        expect(process
                   .addSlot(shitate::test::makeSlot(processQueue, 2,
                                                    {.multiplier = 3.0F, .offset = 2.0F}))
                   .succeeded());
        expect(process
                   .addSlot(shitate::test::makeSlot(
                       processQueue, 3, {.multiplier = 4.0F, .offset = 3.0F, .latencySamples = 32}))
                   .succeeded());
        expect(process.prepare().succeeded());
        expectEquals(process.totalLatencySamples(), 32);
        process.setRunning(true);
        juce::AudioBuffer<float> buffer(2, 64);
        juce::MidiBuffer midi;
        shitate::test::fill(buffer, 1.0F, 64);
        process.process(buffer, midi, 64);
        expectWithinAbsoluteError(buffer.getSample(0, 0), 47.0F, 0.0001F);
        expect(process.setBypassed(shitate::test::slotID(2), true).succeeded());
        shitate::test::fill(buffer, 1.0F, 64);
        process.process(buffer, midi, 64);
        expectWithinAbsoluteError(buffer.getSample(0, 0), 15.0F, 0.0001F);
        expect(process.removeSlot(shitate::test::slotID(1)).error ==
               shitate::plugins::PluginRuntimeError::engineRunning);
        process.setRunning(false);
        expect(process.removeSlot(shitate::test::slotID(2)).succeeded());
        expectIDs(process, {1, 3});
    }

  private:
    void expectIDs(const shitate::PluginChain& chain,
                   std::initializer_list<std::uint8_t> expected) {
        const auto snapshots = chain.snapshots();
        expectEquals(snapshots.size(), expected.size());
        std::size_t index = 0;
        for (const auto value : expected) {
            if (index < snapshots.size()) {
                expect(snapshots[index].slotID == shitate::test::slotID(value));
            }
            ++index;
        }
    }
};

PluginChainTest pluginChainTest;

} // namespace
