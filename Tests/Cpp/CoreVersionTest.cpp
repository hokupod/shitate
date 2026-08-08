// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "ApplicationCore.h"

#include <juce_core/juce_core.h>

#ifndef SHITATE_EXPECTED_DISPLAY_VERSION
#error "SHITATE_EXPECTED_DISPLAY_VERSION must be provided by CMake"
#endif

namespace {

class CoreVersionTest final : public juce::UnitTest {
  public:
    CoreVersionTest() : juce::UnitTest("Core display version", "Shitate") {}

    void runTest() override {
        beginTest("returns the repository display version");
        expect(shitate::ApplicationCore::displayVersion() == SHITATE_EXPECTED_DISPLAY_VERSION);
    }
};

CoreVersionTest coreVersionTest;

} // namespace
