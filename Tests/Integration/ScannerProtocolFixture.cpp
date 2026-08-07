// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include <array>
#include <cstdlib>
#include <filesystem>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>

int main(int argc, char* argv[]) {
    if (argc != 3 || std::string_view(argv[1]) != "--request" ||
        std::string_view(argv[2]).find(".vst3") != std::string_view::npos ||
        std::getenv("SHITATE_TEST_SECRET") != nullptr) {
        return 50;
    }
    const std::filesystem::path request(argv[2]);
    struct stat requestStatus{};
    struct stat directoryStatus{};
    if (request.filename() != "request.json" || ::lstat(request.c_str(), &requestStatus) != 0 ||
        ::lstat(request.parent_path().c_str(), &directoryStatus) != 0 ||
        !S_ISREG(requestStatus.st_mode) || !S_ISDIR(directoryStatus.st_mode) ||
        requestStatus.st_uid != ::getuid() || directoryStatus.st_uid != ::getuid() ||
        (requestStatus.st_mode & static_cast<mode_t>(0777)) != 0600 ||
        (directoryStatus.st_mode & static_cast<mode_t>(0777)) != 0700) {
        return 50;
    }
    if (std::getenv("SHITATE_TEST_SCANNER_FLOOD") != nullptr) {
        std::array<char, 4096> output{};
        output.fill('x');
        while (true) {
            static_cast<void>(::write(STDOUT_FILENO, output.data(), output.size()));
            static_cast<void>(::write(STDERR_FILENO, output.data(), output.size()));
        }
    }
    return 0;
}
