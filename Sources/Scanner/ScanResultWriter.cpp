// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "ScanResultWriter.h"

#include "Plugins/PluginScanProtocol.h"

#include <cerrno>
#include <fcntl.h>
#include <filesystem>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace shitate::scanner {
namespace {

[[nodiscard]] bool writeAll(int descriptor, const std::string& contents) {
    std::size_t offset = 0;
    while (offset < contents.size()) {
        const auto written =
            ::write(descriptor, contents.data() + offset, contents.size() - offset);
        if (written < 0 && errno == EINTR) {
            continue;
        }
        if (written <= 0) {
            return false;
        }
        offset += static_cast<std::size_t>(written);
    }
    return true;
}

} // namespace

bool ScanResultWriter::write(const std::string& resultPath,
                             const plugins::ScanResult& result) noexcept {
    try {
        const std::filesystem::path path(resultPath);
        if (!path.is_absolute() || path.filename() != "result.json") {
            return false;
        }
        const auto temporaryName = "result.json.tmp-" + std::to_string(::getpid());
        const auto contents = plugins::serializeScanResult(result);
        if (contents.empty() || contents.size() > plugins::maximumResultBytes) {
            return false;
        }

        const auto directory =
            ::open(path.parent_path().c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (directory < 0) {
            return false;
        }
        struct stat directoryStatus{};
        if (::fstat(directory, &directoryStatus) != 0 || !S_ISDIR(directoryStatus.st_mode) ||
            directoryStatus.st_uid != ::getuid() ||
            (directoryStatus.st_mode & static_cast<mode_t>(0777)) != 0700) {
            ::close(directory);
            return false;
        }

        const auto output = ::openat(directory, temporaryName.c_str(),
                                     O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (output < 0) {
            ::close(directory);
            return false;
        }
        const auto written = writeAll(output, contents) && ::fsync(output) == 0;
        const auto closeStatus = ::close(output);
        if (!written || closeStatus != 0 ||
            ::renameat(directory, temporaryName.c_str(), directory, "result.json") != 0 ||
            ::fsync(directory) != 0) {
            static_cast<void>(::unlinkat(directory, temporaryName.c_str(), 0));
            ::close(directory);
            return false;
        }
        ::close(directory);
        return true;
    } catch (...) {
        return false;
    }
}

} // namespace shitate::scanner
