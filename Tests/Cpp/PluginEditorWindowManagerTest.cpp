// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Plugins/PluginEditorWindowManager.h"

#include "PluginRuntimeTestSupport.h"

#include <juce_core/juce_core.h>
#include <thread>

namespace {

class PluginEditorWindowManagerTest final : public juce::UnitTest {
  public:
    PluginEditorWindowManagerTest() : UnitTest("PluginEditorWindowManager", "Shitate") {}

    void runTest() override {
        shitate::RealtimeEventQueue queue;
        shitate::plugins::PluginEditorWindowManager manager(false);

        beginTest("editor opens once and clamps undersized content");
        auto small = shitate::test::makeSlot(
            queue, 1, {.providesEditor = true, .editorWidth = 100, .editorHeight = 100});
        expect(manager.open(*small).succeeded());
        expect(manager.open(*small).succeeded());
        expectEquals(static_cast<int>(manager.size()), 1);
        const auto smallSize = manager.windowSizeForTesting(small->id());
        expect(smallSize.has_value());
        if (smallSize.has_value()) {
            expectEquals(smallSize->first,
                         shitate::plugins::PluginEditorWindowManager::minimumWidth);
            expectEquals(smallSize->second,
                         shitate::plugins::PluginEditorWindowManager::minimumHeight);
        }

        beginTest("oversized editor is clamped to the maximum window bounds");
        auto large = shitate::test::makeSlot(
            queue, 2, {.providesEditor = true, .editorWidth = 2400, .editorHeight = 1800});
        expect(manager.open(*large).succeeded());
        const auto largeSize = manager.windowSizeForTesting(large->id());
        expect(largeSize.has_value());
        if (largeSize.has_value()) {
            expectEquals(largeSize->first,
                         shitate::plugins::PluginEditorWindowManager::maximumWidth);
            expectEquals(largeSize->second,
                         shitate::plugins::PluginEditorWindowManager::maximumHeight);
        }

        beginTest("plug-in without editor and off-main-thread open are rejected");
        auto noEditor = shitate::test::makeSlot(queue, 3);
        const auto unavailable = manager.open(*noEditor);
        expect(unavailable.error == shitate::plugins::PluginRuntimeError::editorUnavailable);
        shitate::plugins::PluginRuntimeResult offMain;
        std::thread background([&] { offMain = manager.open(*large); });
        background.join();
        expect(offMain.error == shitate::plugins::PluginRuntimeError::editorThreadInvalid);

        beginTest("visible editor attaches to the desktop");
        shitate::plugins::PluginEditorWindowManager visibleManager;
        auto visible = shitate::test::makeSlot(
            queue, 4, {.providesEditor = true, .editorWidth = 480, .editorHeight = 320});
        expect(visibleManager.open(*visible).succeeded());
        expect(visibleManager.windowIsOnDesktopForTesting(visible->id()).value_or(false));
        visibleManager.closeAll();

        beginTest("slot removal and shutdown close every native editor");
        expect(manager.close(small->id()).succeeded());
        expect(!manager.isOpen(small->id()));
        expectEquals(static_cast<int>(manager.size()), 1);
        manager.closeAll();
        expectEquals(static_cast<int>(manager.size()), 0);
        expect(!manager.isOpen(large->id()));
        expect(manager.close(large->id()).succeeded());
    }
};

PluginEditorWindowManagerTest pluginEditorWindowManagerTest;

} // namespace
