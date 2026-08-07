// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include <iostream>
#include <juce_core/juce_core.h>
#include <juce_gui_basics/juce_gui_basics.h>
#include <string_view>

int main(int argc, char* argv[]) {
    juce::ScopedJuceInitialiser_GUI guiInitialiser;
    juce::UnitTestRunner runner;
    runner.setAssertOnFailure(false);

    if (argc == 3 && std::string_view(argv[1]) == "--test") {
        runner.runTestsWithName(argv[2], 0x53484954);
    } else if (argc == 1) {
        runner.runTestsInCategory("Shitate", 0x53484954);
    } else {
        std::cerr << "usage: ShitateCppTests [--test <name>]\n";
        return 2;
    }

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
