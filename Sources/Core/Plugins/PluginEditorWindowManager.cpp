// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "PluginEditorWindowManager.h"

#include "Audio/HostedPluginSlot.h"

#include <algorithm>

namespace shitate::plugins {
namespace {

class RuntimeEditorWindow final : public juce::DocumentWindow {
  public:
    explicit RuntimeEditorWindow(const juce::String& title)
        : DocumentWindow(title, juce::Colours::black, DocumentWindow::closeButton, false) {
        setUsingNativeTitleBar(true);
        setResizable(true, false);
    }

    void closeButtonPressed() override {
        setVisible(false);
    }
};

} // namespace

PluginEditorWindowManager::PluginEditorWindowManager(bool showWindows) noexcept
    : showWindows_(showWindows) {}

PluginEditorWindowManager::~PluginEditorWindowManager() {
    closeAll();
}

PluginRuntimeResult PluginEditorWindowManager::open(HostedPluginSlot& slot) {
    if (!isMessageThread()) {
        return PluginRuntimeResult::failure(PluginRuntimeError::editorThreadInvalid,
                                            "Plug-in editors must open on the main thread.");
    }
    const auto existing = indexOf(slot.id());
    if (existing != maximumWindows) {
        if (showWindows_) {
            windows_[existing].window->setVisible(true);
            windows_[existing].window->toFront(true);
        }
        return PluginRuntimeResult::success();
    }
    if (size_ >= maximumWindows || !slot.hasEditor()) {
        return PluginRuntimeResult::failure(PluginRuntimeError::editorUnavailable,
                                            "The plug-in does not provide an editor.");
    }

    auto* editor = slot.createEditorIfNeeded();
    if (editor == nullptr) {
        return PluginRuntimeResult::failure(PluginRuntimeError::editorUnavailable,
                                            "The plug-in editor could not be created.");
    }
    auto window =
        std::make_unique<RuntimeEditorWindow>(juce::String::fromUTF8(slot.identity().name.c_str()));
    const auto width = std::clamp(editor->getWidth(), minimumWidth, maximumWidth);
    const auto height = std::clamp(editor->getHeight(), minimumHeight, maximumHeight);
    window->setResizeLimits(minimumWidth, minimumHeight, maximumWidth, maximumHeight);
    window->setContentOwned(editor, true);
    window->centreWithSize(width, height);
    if (showWindows_) {
        window->setVisible(true);
        window->toFront(true);
    }
    windows_[size_++] = {.slotID = slot.id(), .window = std::move(window)};
    return PluginRuntimeResult::success();
}

PluginRuntimeResult PluginEditorWindowManager::close(const SlotId& slotID) {
    if (!isMessageThread()) {
        return PluginRuntimeResult::failure(PluginRuntimeError::editorThreadInvalid,
                                            "Plug-in editors must close on the main thread.");
    }
    const auto index = indexOf(slotID);
    if (index == maximumWindows) {
        return PluginRuntimeResult::success();
    }
    windows_[index].window->setVisible(false);
    windows_[index].window.reset();
    for (auto current = index; current + 1 < size_; ++current) {
        windows_[current] = std::move(windows_[current + 1]);
    }
    windows_[--size_] = {};
    return PluginRuntimeResult::success();
}

void PluginEditorWindowManager::closeAll() noexcept {
    for (std::size_t index = 0; index < size_; ++index) {
        windows_[index].window->setVisible(false);
        windows_[index].window.reset();
    }
    size_ = 0;
}

bool PluginEditorWindowManager::isOpen(const SlotId& slotID) const noexcept {
    return indexOf(slotID) != maximumWindows;
}

std::size_t PluginEditorWindowManager::size() const noexcept {
    return size_;
}

std::optional<std::pair<int, int>>
PluginEditorWindowManager::windowSizeForTesting(const SlotId& slotID) const noexcept {
    const auto index = indexOf(slotID);
    if (index == maximumWindows || windows_[index].window == nullptr) {
        return std::nullopt;
    }
    return std::pair{windows_[index].window->getWidth(), windows_[index].window->getHeight()};
}

bool PluginEditorWindowManager::isMessageThread() const noexcept {
    const auto* manager = juce::MessageManager::getInstanceWithoutCreating();
    return manager != nullptr && manager->isThisTheMessageThread();
}

std::size_t PluginEditorWindowManager::indexOf(const SlotId& slotID) const noexcept {
    for (std::size_t index = 0; index < size_; ++index) {
        if (windows_[index].slotID == slotID) {
            return index;
        }
    }
    return maximumWindows;
}

} // namespace shitate::plugins
