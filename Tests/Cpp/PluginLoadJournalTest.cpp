// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Plugins/PluginLoadJournal.h"

#include "PluginRuntimeTestSupport.h"

#include <filesystem>
#include <fstream>
#include <juce_core/juce_core.h>
#include <sstream>
#include <sys/stat.h>
#include <unistd.h>

namespace {

class TemporaryJournalDirectory final {
  public:
    TemporaryJournalDirectory()
        : path(std::filesystem::temp_directory_path() /
               ("shitate-journal-test-" + juce::Uuid().toString().toStdString())) {
        std::filesystem::create_directory(path);
        static_cast<void>(::chmod(path.c_str(), 0700));
    }

    ~TemporaryJournalDirectory() {
        std::error_code error;
        std::filesystem::remove_all(path, error);
    }

    std::filesystem::path path;
};

[[nodiscard]] std::string readFile(const std::filesystem::path& path) {
    std::ifstream stream(path);
    std::ostringstream contents;
    contents << stream.rdbuf();
    return contents.str();
}

class PluginLoadJournalTest final : public juce::UnitTest {
  public:
    PluginLoadJournalTest() : UnitTest("PluginLoadJournal", "Shitate") {}

    void runTest() override {
        TemporaryJournalDirectory directory;
        const auto journalPath = directory.path / "plugin-load-journal.json";
        shitate::plugins::FilePluginLoadJournal journal(journalPath.string());
        const auto catalog = shitate::test::catalogEntry();
        const shitate::plugins::PluginLoadJournalEntry entry{
            .slotID = shitate::test::slotID(1),
            .fingerprint = catalog.fingerprint,
            .pluginName = catalog.name,
        };

        beginTest("begin atomically writes a private bounded loading record");
        expect(journal.begin(entry).succeeded());
        struct stat status{};
        expect(::lstat(journalPath.c_str(), &status) == 0);
        expect(S_ISREG(status.st_mode));
        expectEquals(static_cast<int>(status.st_mode & 0777), 0600);
        expectEquals(static_cast<int>(status.st_uid), static_cast<int>(::getuid()));
        expectEquals(static_cast<int>(status.st_nlink), 1);
        const auto loadingJSON = readFile(journalPath);
        expect(loadingJSON.find("\"lastOperation\": \"loadingPlugin\"") != std::string::npos);
        expect(loadingJSON.find(entry.slotID.toString()) != std::string::npos);
        expect(loadingJSON.find(entry.fingerprint) != std::string::npos);

        beginTest("graceful failure replaces loading with a bounded terminal record");
        expect(journal.fail(entry, shitate::plugins::PluginRuntimeError::instanceCreationFailed)
                   .succeeded());
        const auto failureJSON = readFile(journalPath);
        expect(failureJSON.find("\"lastOperation\": \"pluginLoadFailed\"") != std::string::npos);
        expect(failureJSON.find("\"loadingPlugin\": null") != std::string::npos);
        expect(failureJSON.find("\"errorCode\": 303") != std::string::npos);

        beginTest("clear publishes an explicit idle record");
        expect(journal.clear().succeeded());
        const auto idleJSON = readFile(journalPath);
        expect(idleJSON.find("\"lastOperation\": \"idle\"") != std::string::npos);
        expect(idleJSON.find("\"loadingPlugin\": null") != std::string::npos);

        beginTest("unsafe existing file permissions are rejected");
        expect(::chmod(journalPath.c_str(), 0644) == 0);
        const auto unsafeFile = journal.begin(entry);
        expect(unsafeFile.error == shitate::plugins::PluginRuntimeError::journalWriteFailed);
        expect(::chmod(journalPath.c_str(), 0600) == 0);

        beginTest("symlink replacement is rejected without touching its target");
        const auto targetPath = directory.path / "target";
        {
            std::ofstream target(targetPath);
            target << "unchanged";
        }
        expect(::unlink(journalPath.c_str()) == 0);
        expect(::symlink(targetPath.c_str(), journalPath.c_str()) == 0);
        const auto unsafeLink = journal.begin(entry);
        expect(unsafeLink.error == shitate::plugins::PluginRuntimeError::journalWriteFailed);
        expectEquals(readFile(targetPath), std::string("unchanged"));
        expect(::unlink(journalPath.c_str()) == 0);

        beginTest("unsafe parent mode and invalid record are rejected");
        expect(::chmod(directory.path.c_str(), 0755) == 0);
        const auto unsafeDirectory = journal.clear();
        expect(unsafeDirectory.error == shitate::plugins::PluginRuntimeError::journalWriteFailed);
        expect(::chmod(directory.path.c_str(), 0700) == 0);
        auto invalidEntry = entry;
        invalidEntry.fingerprint = "short";
        const auto invalid = journal.begin(invalidEntry);
        expect(invalid.error == shitate::plugins::PluginRuntimeError::journalWriteFailed);
    }
};

PluginLoadJournalTest pluginLoadJournalTest;

} // namespace
