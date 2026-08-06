// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include <iostream>
#include <juce_core/juce_core.h>

int main() {
    juce::UnitTestRunner runner;
    runner.setAssertOnFailure(false);
    runner.runTestsInCategory("Shitate", 0x53484954);

    if (runner.getNumResults() == 0) {
        std::cerr << "no Shitate JUCE unit tests were registered\n";
        return 1;
    }

    auto failures = 0;
    for (auto index = 0; index < runner.getNumResults(); ++index) {
        if (const auto* result = runner.getResult(index); result != nullptr) {
            failures += result->failures;
        }
    }

    return failures == 0 ? 0 : 1;
}
