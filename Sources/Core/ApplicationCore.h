// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#pragma once

#include <string>

namespace shitate {

class ApplicationCore final {
  public:
    [[nodiscard]] static std::string displayVersion();
    static void throwForTesting();
};

} // namespace shitate
