// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "ScanRequest.h"

#include "Plugins/PluginScanProtocol.h"

#include <cerrno>
#include <fcntl.h>
#include <filesystem>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>

namespace shitate::scanner {
namespace {

constexpr std::string_view taskPrefix = "shitate-scan-";

[[nodiscard]] bool exactMode(mode_t actual, mode_t expected) {
    return (actual & static_cast<mode_t>(0777)) == expected;
}

[[nodiscard]] bool isSecureTaskPath(const std::filesystem::path& requestPath) {
    if (!requestPath.is_absolute() || requestPath.filename() != "request.json") {
        return false;
    }
    const auto parent = requestPath.parent_path();
    const auto name = parent.filename().string();
    if (!name.starts_with(taskPrefix) ||
        !plugins::isCanonicalUUID(std::string_view(name).substr(taskPrefix.size()))) {
        return false;
    }

    std::error_code canonicalError;
    const auto canonicalParent = std::filesystem::canonical(parent, canonicalError);
    if (canonicalError || canonicalParent != parent ||
        canonicalParent.parent_path() != "/private/tmp") {
        return false;
    }
    struct stat parentStatus{};
    return ::lstat(parent.c_str(), &parentStatus) == 0 && S_ISDIR(parentStatus.st_mode) &&
           !S_ISLNK(parentStatus.st_mode) && parentStatus.st_uid == ::getuid() &&
           exactMode(parentStatus.st_mode, 0700);
}

} // namespace

bool ScanRequestLoader::load(const std::string& requestPath, plugins::ScanRequest& request,
                             std::string& errorCode) {
    const std::filesystem::path path(requestPath);
    if (!isSecureTaskPath(path)) {
        errorCode = "unsafeRequestPath";
        return false;
    }

    const auto descriptor = ::open(path.c_str(), O_RDONLY | O_NOFOLLOW);
    if (descriptor < 0) {
        errorCode = "requestOpenFailed";
        return false;
    }
    struct stat status{};
    if (::fstat(descriptor, &status) != 0 || !S_ISREG(status.st_mode) ||
        status.st_uid != ::getuid() || !exactMode(status.st_mode, 0600) || status.st_size <= 0 ||
        static_cast<std::uintmax_t>(status.st_size) > plugins::maximumRequestBytes) {
        ::close(descriptor);
        errorCode = "unsafeRequestFile";
        return false;
    }

    std::string contents(static_cast<std::size_t>(status.st_size), '\0');
    std::size_t offset = 0;
    while (offset < contents.size()) {
        const auto count = ::read(descriptor, contents.data() + offset, contents.size() - offset);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            ::close(descriptor);
            errorCode = "requestReadFailed";
            return false;
        }
        offset += static_cast<std::size_t>(count);
    }
    ::close(descriptor);
    return plugins::parseScanRequest(contents, request, errorCode);
}

std::string ScanRequestLoader::resultPathForRequest(const std::string& requestPath) {
    return (std::filesystem::path(requestPath).parent_path() / "result.json").string();
}

} // namespace shitate::scanner
