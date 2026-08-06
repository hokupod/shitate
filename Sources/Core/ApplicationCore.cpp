// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "ApplicationCore.h"

#include <stdexcept>

#ifndef SHITATE_DISPLAY_VERSION
#error "SHITATE_DISPLAY_VERSION must be provided by CMake"
#endif

namespace shitate {

std::string ApplicationCore::displayVersion() {
    return SHITATE_DISPLAY_VERSION;
}

void ApplicationCore::throwForTesting() {
    throw std::runtime_error("bridge exception mapping test");
}

} // namespace shitate
