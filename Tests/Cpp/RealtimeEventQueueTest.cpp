// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Audio/RealtimeEventQueue.h"

#include <juce_core/juce_core.h>

namespace {

class RealtimeEventQueueTest final : public juce::UnitTest {
  public:
    RealtimeEventQueueTest() : juce::UnitTest("RealtimeEventQueue", "Shitate") {}

    void runTest() override {
        shitate::RealtimeEventQueue queue;

        beginTest("preserves FIFO order while capacity remains");
        expect(queue.push({.type = shitate::CoreEventType::engineStateChanged, .value = 1}));
        expect(queue.push({.type = shitate::CoreEventType::engineStateChanged, .value = 2}));
        shitate::CoreEvent event;
        expect(queue.pop(event));
        expectEquals(event.value, 1);
        expect(queue.pop(event));
        expectEquals(event.value, 2);

        beginTest("coalesces overflow without allocation or blocking");
        for (std::size_t index = 0; index < shitate::RealtimeEventQueue::capacity; ++index) {
            expect(queue.push({.type = shitate::CoreEventType::devicesChanged,
                               .value = static_cast<int>(index)}));
        }
        expect(!queue.push({.type = shitate::CoreEventType::fatalError,
                            .value = 99,
                            .error = shitate::AudioErrorCode::callbackLayoutInvalid}));

        auto sawFallback = false;
        while (queue.pop(event)) {
            if (event.type == shitate::CoreEventType::fatalError) {
                sawFallback = true;
                expectEquals(event.value, 99);
                expect(event.error == shitate::AudioErrorCode::callbackLayoutInvalid);
            }
        }
        expect(sawFallback);
    }
};

RealtimeEventQueueTest realtimeEventQueueTest;

} // namespace
