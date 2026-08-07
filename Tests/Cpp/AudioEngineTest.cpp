// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Audio/AudioEngine.h"

#include "Audio/RealtimeSafety.h"
#include "TestAllocationTracker.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <juce_core/juce_core.h>
#include <limits>
#include <thread>

namespace {

class AudioEngineTest final : public juce::UnitTest {
  public:
    AudioEngineTest() : juce::UnitTest("AudioEngine", "Shitate") {}

    void runTest() override {
        shitate::RealtimeEventQueue queue;
        shitate::AudioEngine engine(queue);
        engine.prepareForTesting(48000.0);
        engine.setRunningForTesting(true);

        std::array<float, 1025> input{};
        std::array<float, 1025> left{};
        std::array<float, 1025> right{};
        input.fill(0.25F);
        const float* inputChannels[]{input.data()};
        float* outputChannels[]{left.data(), right.data()};
        const juce::AudioIODeviceCallbackContext context{};
        const auto resetEngine = [&] {
            engine.setRunningForTesting(false);
            engine.prepareForTesting(48000.0);
            engine.setRunningForTesting(true);
            engine.audioDeviceIOCallbackWithContext(inputChannels, 1, outputChannels, 2, 512,
                                                    context);
        };
        resetEngine();

        beginTest("handles every supported callback boundary and chunks above 512");
        for (const auto frames : {0, 1, 128, 256, 512, 513, 1024}) {
            left.fill(-1.0F);
            right.fill(-1.0F);
            engine.audioDeviceIOCallbackWithContext(inputChannels, 1, outputChannels, 2, frames,
                                                    context);
            for (auto frame = 0; frame < frames; ++frame) {
                expectWithinAbsoluteError(left[static_cast<std::size_t>(frame)], 0.25F, 0.0001F);
                expectWithinAbsoluteError(right[static_cast<std::size_t>(frame)], 0.25F, 0.0001F);
            }
        }

        beginTest("callbacks above 1024 are entirely silent");
        left.fill(1.0F);
        right.fill(1.0F);
        engine.audioDeviceIOCallbackWithContext(inputChannels, 1, outputChannels, 2, 1025, context);
        expect(std::all_of(left.begin(), left.end(), [](float sample) { return sample == 0.0F; }));
        expect(
            std::all_of(right.begin(), right.end(), [](float sample) { return sample == 0.0F; }));

        beginTest("recovery latches silence until explicit reconfiguration");
        left.fill(1.0F);
        right.fill(1.0F);
        engine.audioDeviceIOCallbackWithContext(inputChannels, 1, outputChannels, 2, 128, context);
        expect(std::all_of(left.begin(), left.begin() + 128,
                           [](float sample) { return sample == 0.0F; }));
        expect(std::all_of(right.begin(), right.begin() + 128,
                           [](float sample) { return sample == 0.0F; }));
        resetEngine();

        beginTest("null input and insufficient output fail closed");
        left.fill(1.0F);
        right.fill(1.0F);
        const float* nullInput[]{nullptr};
        engine.audioDeviceIOCallbackWithContext(nullInput, 1, outputChannels, 2, 128, context);
        expect(std::all_of(left.begin(), left.begin() + 128,
                           [](float sample) { return sample == 0.0F; }));
        resetEngine();
        left.fill(1.0F);
        engine.audioDeviceIOCallbackWithContext(inputChannels, 1, outputChannels, 1, 128, context);
        expect(std::all_of(left.begin(), left.begin() + 128,
                           [](float sample) { return sample == 0.0F; }));
        resetEngine();

        beginTest("non-finite input cannot reach output");
        input[0] = std::numeric_limits<float>::quiet_NaN();
        engine.audioDeviceIOCallbackWithContext(inputChannels, 1, outputChannels, 2, 1, context);
        expectEquals(left[0], 0.0F);
        expectEquals(right[0], 0.0F);
        input[0] = 0.25F;

        beginTest("debug lock assertion detects a control lock attempt");
        shitate::RealtimeSafety::resetLockAssertionForTesting();
        shitate::RealtimeCheckedMutex checkedMutex;
        shitate::RealtimeSafety::enterCallback();
        const auto acquired = checkedMutex.try_lock();
        shitate::RealtimeSafety::leaveCallback();
        if (acquired) {
            checkedMutex.unlock();
        }
        expect(shitate::RealtimeSafety::lockAttemptedForTesting());

        beginTest("callback performs no allocation, lock attempt, or blocking re-entry");
        shitate::RealtimeSafety::resetLockAssertionForTesting();
        const auto before = shitate::test::allocationCount();
        engine.audioDeviceIOCallbackWithContext(inputChannels, 1, outputChannels, 2, 512, context);
        const auto after = shitate::test::allocationCount();
        expectEquals(after, before);
        expect(!shitate::RealtimeSafety::lockAttemptedForTesting());
        expect(!engine.callbackInvariantViolationForTesting());

        beginTest("meters preserve accumulation across chunk boundaries");
        input.fill(0.5F);
        input[0] = 1.0F;
        engine.audioDeviceIOCallbackWithContext(inputChannels, 1, outputChannels, 2, 513, context);
        const auto meters = engine.meterSnapshot();
        expectWithinAbsoluteError(meters.inputPeakDb, 0.0F, 0.0001F);
        expect(meters.inputClipping);
        expect(std::isfinite(meters.inputRmsDb));

        beginTest("reentrant callback cancels every in-flight output before recovery");
        resetEngine();
        shitate::CoreEvent event;
        while (engine.popEvent(event)) {
        }
        std::array<float, 512> firstLeft{};
        std::array<float, 512> firstRight{};
        std::array<float, 512> secondLeft{};
        std::array<float, 512> secondRight{};
        firstLeft.fill(1.0F);
        firstRight.fill(1.0F);
        secondLeft.fill(1.0F);
        secondRight.fill(1.0F);
        float* firstOutputs[]{firstLeft.data(), firstRight.data()};
        float* secondOutputs[]{secondLeft.data(), secondRight.data()};
        std::atomic<bool> callbackEntered{false};
        std::atomic<bool> releaseCallback{false};
        engine.setCallbackBarrierForTesting(&callbackEntered, &releaseCallback);
        std::thread firstCallback([&] {
            engine.audioDeviceIOCallbackWithContext(inputChannels, 1, firstOutputs, 2, 512,
                                                    context);
        });
        while (!callbackEntered.load(std::memory_order_acquire)) {
            std::this_thread::yield();
        }
        engine.audioDeviceIOCallbackWithContext(inputChannels, 1, secondOutputs, 2, 512, context);
        releaseCallback.store(true, std::memory_order_release);
        firstCallback.join();
        engine.setCallbackBarrierForTesting(nullptr, nullptr);
        expect(std::all_of(firstLeft.begin(), firstLeft.end(),
                           [](float sample) { return sample == 0.0F; }));
        expect(std::all_of(firstRight.begin(), firstRight.end(),
                           [](float sample) { return sample == 0.0F; }));
        expect(std::all_of(secondLeft.begin(), secondLeft.end(),
                           [](float sample) { return sample == 0.0F; }));
        expect(std::all_of(secondRight.begin(), secondRight.end(),
                           [](float sample) { return sample == 0.0F; }));
        auto recoveryEvents = 0;
        while (engine.popEvent(event)) {
            recoveryEvents += event.type == shitate::CoreEventType::recoveryRequested ? 1 : 0;
        }
        expectEquals(recoveryEvents, 1);
        expect(engine.callbackInvariantViolationForTesting());
        resetEngine();

        beginTest("stop fade completes asynchronously without blocking the control thread");
        engine.stop();
        expect(engine.status() == shitate::EngineStatus::stopping);
        expect(engine.isRunning());
        engine.audioDeviceIOCallbackWithContext(inputChannels, 1, outputChannels, 2, 512, context);
        (void)engine.popEvent(event);
        expect(!engine.isRunning());
        expect(engine.status() == shitate::EngineStatus::configured);
        const auto stoppedMeters = engine.meterSnapshot();
        expectEquals(stoppedMeters.inputPeakDb, -96.0F);
        expectEquals(stoppedMeters.inputRmsDb, -96.0F);
        expectEquals(stoppedMeters.outputPeakDb, -96.0F);
        expectEquals(stoppedMeters.outputRmsDb, -96.0F);

        beginTest("unexpected device stop requests fail-closed recovery");
        resetEngine();
        while (engine.popEvent(event)) {
        }
        engine.audioDeviceStopped();
        expect(engine.status() == shitate::EngineStatus::blocked);
        auto sawRecovery = false;
        while (engine.popEvent(event)) {
            sawRecovery = sawRecovery || event.type == shitate::CoreEventType::recoveryRequested;
        }
        expect(sawRecovery);
    }
};

AudioEngineTest audioEngineTest;

} // namespace
