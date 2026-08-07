// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "ApplicationCore.h"

#include <juce_core/juce_core.h>

namespace {

class CoreVersionTest final : public juce::UnitTest {
  public:
    CoreVersionTest() : juce::UnitTest("Core display version", "Shitate") {}

    void runTest() override {
        beginTest("returns the repository display version");
        expect(shitate::ApplicationCore::displayVersion() == "0.2.0-dev");
    }
};

CoreVersionTest coreVersionTest;

} // namespace
