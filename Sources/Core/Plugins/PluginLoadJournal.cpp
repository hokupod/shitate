// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "PluginLoadJournal.h"

#include <cerrno>
#include <fcntl.h>
#include <filesystem>
#include <juce_core/juce_core.h>
#include <string_view>
#include <sys/stat.h>
#include <unistd.h>

namespace shitate::plugins {
namespace {

class FileDescriptor final {
  public:
    explicit FileDescriptor(int descriptor = -1) noexcept : descriptor_(descriptor) {}
    ~FileDescriptor() {
        if (descriptor_ >= 0) {
            static_cast<void>(::close(descriptor_));
        }
    }
    FileDescriptor(const FileDescriptor&) = delete;
    FileDescriptor& operator=(const FileDescriptor&) = delete;

    [[nodiscard]] int get() const noexcept {
        return descriptor_;
    }

  private:
    int descriptor_{-1};
};

[[nodiscard]] bool exactMode(mode_t actual, mode_t expected) noexcept {
    return (actual & static_cast<mode_t>(0777)) == expected;
}

[[nodiscard]] bool writeAll(int descriptor, std::string_view contents) noexcept {
    std::size_t offset = 0;
    while (offset < contents.size()) {
        const auto count = ::write(descriptor, contents.data() + offset, contents.size() - offset);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        offset += static_cast<std::size_t>(count);
    }
    return true;
}

[[nodiscard]] std::string serializeJournal(const PluginLoadJournalEntry* entry,
                                           PluginRuntimeError failure) {
    auto* root = new juce::DynamicObject();
    root->setProperty("schemaVersion", 1);
    if (entry == nullptr) {
        root->setProperty("lastOperation", "idle");
        root->setProperty("loadingPlugin", juce::var());
        root->setProperty("failedPlugin", juce::var());
    } else {
        auto* plugin = new juce::DynamicObject();
        const auto slotID = entry->slotID.toString();
        plugin->setProperty("slotID", juce::String::fromUTF8(slotID.c_str()));
        plugin->setProperty("pluginFingerprint",
                            juce::String::fromUTF8(entry->fingerprint.c_str()));
        plugin->setProperty("pluginName", juce::String::fromUTF8(entry->pluginName.c_str()));
        if (failure == PluginRuntimeError::none) {
            root->setProperty("lastOperation", "loadingPlugin");
            root->setProperty("loadingPlugin", juce::var(plugin));
            root->setProperty("failedPlugin", juce::var());
        } else {
            plugin->setProperty("errorCode", static_cast<int>(failure));
            root->setProperty("lastOperation", "pluginLoadFailed");
            root->setProperty("loadingPlugin", juce::var());
            root->setProperty("failedPlugin", juce::var(plugin));
        }
    }
    return juce::JSON::toString(juce::var(root), true).toStdString();
}

} // namespace

FilePluginLoadJournal::FilePluginLoadJournal(std::string filePath)
    : filePath_(std::move(filePath)) {}

PluginRuntimeResult FilePluginLoadJournal::begin(const PluginLoadJournalEntry& entry) {
    if (!entry.slotID.isValid() || entry.fingerprint.size() != 64 || entry.pluginName.empty() ||
        entry.pluginName.size() > 512) {
        return PluginRuntimeResult::failure(PluginRuntimeError::journalWriteFailed,
                                            "The plug-in load journal entry is invalid.");
    }
    return write(serializeJournal(&entry, PluginRuntimeError::none));
}

PluginRuntimeResult FilePluginLoadJournal::fail(const PluginLoadJournalEntry& entry,
                                                PluginRuntimeError cause) {
    if (!entry.slotID.isValid() || entry.fingerprint.size() != 64 || entry.pluginName.empty() ||
        entry.pluginName.size() > 512 || cause == PluginRuntimeError::none) {
        return PluginRuntimeResult::failure(PluginRuntimeError::journalWriteFailed,
                                            "The plug-in failure journal entry is invalid.");
    }
    return write(serializeJournal(&entry, cause));
}

PluginRuntimeResult FilePluginLoadJournal::clear() {
    return write(serializeJournal(nullptr, PluginRuntimeError::none));
}

PluginRuntimeResult FilePluginLoadJournal::write(std::string json) const {
    constexpr std::size_t maximumJournalBytes = 16U * 1024U;
    if (filePath_.empty() || filePath_.size() > 4096 || json.empty() ||
        json.size() > maximumJournalBytes) {
        return PluginRuntimeResult::failure(PluginRuntimeError::journalWriteFailed,
                                            "The plug-in load journal path is invalid.");
    }

    const auto path = std::filesystem::path(filePath_);
    const auto parent = path.parent_path();
    const auto filename = path.filename().string();
    if (!path.is_absolute() || parent.empty() || filename != "plugin-load-journal.json") {
        return PluginRuntimeResult::failure(PluginRuntimeError::journalWriteFailed,
                                            "The plug-in load journal path is invalid.");
    }

    FileDescriptor directory(
        ::open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    struct stat directoryStatus{};
    if (directory.get() < 0 || ::fstat(directory.get(), &directoryStatus) != 0 ||
        !S_ISDIR(directoryStatus.st_mode) || directoryStatus.st_uid != ::getuid() ||
        !exactMode(directoryStatus.st_mode, 0700)) {
        return PluginRuntimeResult::failure(PluginRuntimeError::journalWriteFailed,
                                            "The plug-in journal directory is unsafe.");
    }

    struct stat existingStatus{};
    errno = 0;
    const auto existingResult =
        ::fstatat(directory.get(), filename.c_str(), &existingStatus, AT_SYMLINK_NOFOLLOW);
    if (existingResult == 0 &&
        (!S_ISREG(existingStatus.st_mode) || existingStatus.st_uid != ::getuid() ||
         existingStatus.st_nlink != 1 || !exactMode(existingStatus.st_mode, 0600))) {
        return PluginRuntimeResult::failure(PluginRuntimeError::journalWriteFailed,
                                            "The existing plug-in journal is unsafe.");
    }
    if (existingResult != 0 && errno != ENOENT) {
        return PluginRuntimeResult::failure(PluginRuntimeError::journalWriteFailed,
                                            "The plug-in journal could not be inspected.");
    }

    const auto temporaryName =
        ".plugin-load-journal.json.tmp-" + juce::Uuid().toDashedString().toStdString();
    FileDescriptor temporary(::openat(directory.get(), temporaryName.c_str(),
                                      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600));
    if (temporary.get() < 0 || !writeAll(temporary.get(), json) || ::fsync(temporary.get()) != 0) {
        static_cast<void>(::unlinkat(directory.get(), temporaryName.c_str(), 0));
        return PluginRuntimeResult::failure(PluginRuntimeError::journalWriteFailed,
                                            "The plug-in journal could not be written.");
    }
    if (::renameat(directory.get(), temporaryName.c_str(), directory.get(), filename.c_str()) !=
            0 ||
        ::fsync(directory.get()) != 0) {
        static_cast<void>(::unlinkat(directory.get(), temporaryName.c_str(), 0));
        return PluginRuntimeResult::failure(PluginRuntimeError::journalWriteFailed,
                                            "The plug-in journal could not be published.");
    }
    return PluginRuntimeResult::success();
}

} // namespace shitate::plugins
