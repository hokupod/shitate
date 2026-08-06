// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "ApplicationCore.h"

#include <iostream>
#include <string_view>

int main(int argc, char* argv[]) {
    if (argc == 2 && std::string_view(argv[1]) == "--version") {
        std::cout << "ShitatePluginScanner " << shitate::ApplicationCore::displayVersion() << '\n';
        return 0;
    }

    std::cerr << "usage: ShitatePluginScanner --version\n";
    return 2;
}
