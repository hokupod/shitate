// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "PluginScanCoordinator.h"

#include "PluginScanProtocol.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cerrno>
#include <csignal>
#include <cstdlib>
#include <dirent.h>
#include <fcntl.h>
#include <filesystem>
#include <juce_core/juce_core.h>
#include <spawn.h>
#include <string_view>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <utility>
#include <vector>

namespace shitate::plugins {
namespace {

constexpr std::string_view taskPrefix = "shitate-scan-";
constexpr std::chrono::hours staleAge{24};

class FileDescriptor final {
  public:
    explicit FileDescriptor(int descriptor = -1) noexcept : descriptor_(descriptor) {}
    ~FileDescriptor() {
        if (descriptor_ >= 0) {
            ::close(descriptor_);
        }
    }
    FileDescriptor(const FileDescriptor&) = delete;
    FileDescriptor& operator=(const FileDescriptor&) = delete;
    FileDescriptor(FileDescriptor&& other) noexcept
        : descriptor_(std::exchange(other.descriptor_, -1)) {}
    FileDescriptor& operator=(FileDescriptor&& other) noexcept {
        if (this != &other) {
            if (descriptor_ >= 0) {
                ::close(descriptor_);
            }
            descriptor_ = std::exchange(other.descriptor_, -1);
        }
        return *this;
    }
    [[nodiscard]] int get() const noexcept {
        return descriptor_;
    }
    [[nodiscard]] int release() noexcept {
        return std::exchange(descriptor_, -1);
    }

  private:
    int descriptor_{-1};
};

[[nodiscard]] bool isTaskName(std::string_view name) {
    return name.starts_with(taskPrefix) && isCanonicalUUID(name.substr(taskPrefix.size()));
}

[[nodiscard]] bool exactMode(mode_t actual, mode_t expected) {
    return (actual & static_cast<mode_t>(0777)) == expected;
}

[[nodiscard]] bool writeAll(int descriptor, std::string_view contents) {
    std::size_t offset = 0;
    while (offset < contents.size()) {
        const auto written =
            ::write(descriptor, contents.data() + offset, contents.size() - offset);
        if (written < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        offset += static_cast<std::size_t>(written);
    }
    return true;
}

[[nodiscard]] bool createSecureFile(const std::string& path, std::string_view contents) {
    FileDescriptor descriptor(::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600));
    if (descriptor.get() < 0 || !writeAll(descriptor.get(), contents) ||
        ::fsync(descriptor.get()) != 0) {
        return false;
    }
    return true;
}

[[nodiscard]] bool readSecureFile(const std::string& path, std::size_t maximumBytes,
                                  std::string& contents) {
    FileDescriptor descriptor(::open(path.c_str(), O_RDONLY | O_NOFOLLOW));
    if (descriptor.get() < 0) {
        return false;
    }

    struct stat status{};
    if (::fstat(descriptor.get(), &status) != 0 || !S_ISREG(status.st_mode) ||
        status.st_uid != ::getuid() || !exactMode(status.st_mode, 0600) || status.st_size <= 0 ||
        static_cast<std::uintmax_t>(status.st_size) > maximumBytes) {
        return false;
    }

    contents.resize(static_cast<std::size_t>(status.st_size));
    std::size_t offset = 0;
    while (offset < contents.size()) {
        const auto count =
            ::read(descriptor.get(), contents.data() + offset, contents.size() - offset);
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            return false;
        }
        if (count == 0) {
            return false;
        }
        offset += static_cast<std::size_t>(count);
    }
    return true;
}

[[nodiscard]] bool createPipe(std::array<int, 2>& descriptors) {
    if (::pipe(descriptors.data()) != 0) {
        return false;
    }
    const auto flags = ::fcntl(descriptors[0], F_GETFL, 0);
    if (flags < 0 || ::fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) != 0) {
        ::close(descriptors[0]);
        ::close(descriptors[1]);
        descriptors = {-1, -1};
        return false;
    }
    return true;
}

void drainPipe(int pipeDescriptor, int logDescriptor, std::size_t maximumBytes,
               std::size_t& retainedBytes) {
    constexpr std::size_t maximumDrainBytesPerPass = 64U * 1024U;
    constexpr std::size_t maximumReadAttemptsPerPass = 32;
    std::array<char, 4096> buffer{};
    std::size_t drainedBytes = 0;
    std::size_t attempts = 0;
    while (drainedBytes < maximumDrainBytesPerPass && attempts < maximumReadAttemptsPerPass) {
        ++attempts;
        const auto remaining = maximumDrainBytesPerPass - drainedBytes;
        const auto count =
            ::read(pipeDescriptor, buffer.data(), std::min(buffer.size(), remaining));
        if (count > 0) {
            drainedBytes += static_cast<std::size_t>(count);
            const auto available = maximumBytes > retainedBytes ? maximumBytes - retainedBytes : 0;
            const auto toWrite = std::min(available, static_cast<std::size_t>(count));
            if (toWrite > 0) {
                static_cast<void>(::write(logDescriptor, buffer.data(), toWrite));
                retainedBytes += toWrite;
            }
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        break;
    }
}

[[nodiscard]] ScanOutcomeKind outcomeForExitCode(int exitCode) {
    switch (exitCode) {
    case 10:
        return ScanOutcomeKind::invalidRequest;
    case 20:
        return ScanOutcomeKind::invalidSignature;
    case 30:
        return ScanOutcomeKind::bundleLoadFailure;
    case 31:
        return ScanOutcomeKind::factoryFailure;
    case 32:
        return ScanOutcomeKind::noSupportedClass;
    case 40:
        return ScanOutcomeKind::resultWriteFailure;
    case 50:
        return ScanOutcomeKind::internalError;
    default:
        return ScanOutcomeKind::invalidResult;
    }
}

[[nodiscard]] bool resultMatchesPreflight(const ScanResult& result, const ScanRequest& request,
                                          const SignatureInfo& signature) {
    return result.protocolVersion == request.protocolVersion &&
           result.requestID == request.requestID && result.bundle.path == signature.canonicalPath &&
           result.bundle.path == request.pluginBundlePath &&
           result.bundle.codeDirectoryHash == signature.codeDirectoryHash &&
           result.bundle.codeDirectoryHash == request.expectedCodeDirectoryHash &&
           result.bundle.signatureKind == signature.kind &&
           result.bundle.teamIdentifier == signature.teamIdentifier &&
           result.bundle.architectures == signature.architectures &&
           result.bundle.modificationTime == signature.modificationTime;
}

[[nodiscard]] int createEmptySecureFile(const std::string& path) {
    return ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
}

[[nodiscard]] bool sameBundleIdentity(const SignatureInfo& left, const SignatureInfo& right) {
    return left.kind == right.kind && left.canonicalPath == right.canonicalPath &&
           left.signingIdentifier == right.signingIdentifier &&
           left.teamIdentifier == right.teamIdentifier &&
           left.codeDirectoryHash == right.codeDirectoryHash && left.flags == right.flags &&
           left.architectures == right.architectures && left.bundleVersion == right.bundleVersion &&
           left.modificationTime == right.modificationTime;
}

[[nodiscard]] bool validEnvironmentKey(std::string_view key) {
    if (key.empty() || key.size() > 128 ||
        (!std::isalpha(static_cast<unsigned char>(key.front())) && key.front() != '_')) {
        return false;
    }
    return std::all_of(key.begin(), key.end(), [](const auto character) {
        return std::isalnum(static_cast<unsigned char>(character)) || character == '_';
    });
}

[[nodiscard]] std::vector<std::string>
childEnvironment(const std::vector<std::string>& inheritedKeys) {
    std::vector<std::string> result{"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR=/private/tmp"};
    for (const auto& key : inheritedKeys) {
        if (!validEnvironmentKey(key)) {
            continue;
        }
        const auto* value = std::getenv(key.c_str());
        if (value == nullptr || std::char_traits<char>::length(value) > 4096) {
            continue;
        }
        result.push_back(key + "=" + value);
    }
    return result;
}

void signalProcessGroup(pid_t child, int signal) noexcept {
    if (child > 0) {
        static_cast<void>(::kill(-child, signal));
    }
}

enum class ChildPollResult {
    running,
    reaped,
    error,
};

[[nodiscard]] ChildPollResult pollProcessGroupLeader(pid_t child, int& waitStatus) {
    siginfo_t information{};
    int status = 0;
    do {
        status =
            ::waitid(P_PID, static_cast<id_t>(child), &information, WEXITED | WNOHANG | WNOWAIT);
    } while (status != 0 && errno == EINTR);
    if (status != 0) {
        return ChildPollResult::error;
    }
    if (information.si_pid == 0) {
        return ChildPollResult::running;
    }

    // Keep the exited leader unreaped while addressing its process group so the
    // group identifier cannot be recycled between observation and signalling.
    signalProcessGroup(child, SIGKILL);
    pid_t waited = -1;
    do {
        waited = ::waitpid(child, &waitStatus, 0);
    } while (waited < 0 && errno == EINTR);
    return waited == child ? ChildPollResult::reaped : ChildPollResult::error;
}

[[nodiscard]] bool killAndReapProcessGroup(pid_t child, int& waitStatus) {
    signalProcessGroup(child, SIGKILL);
    pid_t waited = -1;
    do {
        waited = ::waitpid(child, &waitStatus, 0);
    } while (waited < 0 && errno == EINTR);
    return waited == child;
}

[[nodiscard]] bool removeDirectoryContents(int directoryDescriptor, std::size_t depth) {
    constexpr std::size_t maximumDepth = 64;
    constexpr std::size_t maximumEntriesPerDirectory = 65'536;
    if (depth > maximumDepth) {
        return false;
    }

    FileDescriptor iterationDescriptor(::dup(directoryDescriptor));
    if (iterationDescriptor.get() < 0) {
        return false;
    }
    DIR* directory = ::fdopendir(iterationDescriptor.release());
    if (directory == nullptr) {
        return false;
    }

    std::vector<std::string> names;
    errno = 0;
    while (const auto* entry = ::readdir(directory)) {
        const std::string_view name(entry->d_name);
        if (name == "." || name == "..") {
            continue;
        }
        if (names.size() >= maximumEntriesPerDirectory) {
            ::closedir(directory);
            return false;
        }
        names.emplace_back(name);
        errno = 0;
    }
    const auto readError = errno;
    ::closedir(directory);
    if (readError != 0) {
        return false;
    }

    for (const auto& name : names) {
        struct stat status{};
        if (::fstatat(directoryDescriptor, name.c_str(), &status, AT_SYMLINK_NOFOLLOW) != 0) {
            if (errno == ENOENT) {
                continue;
            }
            return false;
        }
        if (status.st_uid != ::getuid()) {
            return false;
        }

        if (S_ISDIR(status.st_mode)) {
            FileDescriptor childDirectory(
                ::openat(directoryDescriptor, name.c_str(),
                         O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
            struct stat childStatus{};
            if (childDirectory.get() < 0 || ::fstat(childDirectory.get(), &childStatus) != 0 ||
                childStatus.st_dev != status.st_dev || childStatus.st_ino != status.st_ino ||
                !removeDirectoryContents(childDirectory.get(), depth + 1)) {
                return false;
            }
            childDirectory = FileDescriptor();
            if (::unlinkat(directoryDescriptor, name.c_str(), AT_REMOVEDIR) != 0) {
                return false;
            }
        } else if (::unlinkat(directoryDescriptor, name.c_str(), 0) != 0 && errno != ENOENT) {
            return false;
        }
    }
    return true;
}

} // namespace

PluginScanCoordinator::PluginScanCoordinator(
    std::shared_ptr<const SignatureInspector> signatureInspector,
    ScanCoordinatorConfiguration configuration)
    : signatureInspector_(std::move(signatureInspector)), configuration_(std::move(configuration)) {
}

ScanOutcome PluginScanCoordinator::scan(const std::string& scannerExecutable,
                                        const std::string& pluginBundlePath) const {
    if (signatureInspector_ == nullptr) {
        return {ScanOutcomeKind::internalError, std::nullopt, -1, 0, "missingSignatureInspector"};
    }

    const auto signature = signatureInspector_->inspect(pluginBundlePath);
    const auto policy = evaluateSignaturePolicy(signature, false);
    if (policy == SignaturePolicyDecision::reject) {
        return {ScanOutcomeKind::invalidSignature, std::nullopt, 20, 0,
                signature.errorCode.empty() ? "signatureRejected" : signature.errorCode};
    }

    std::error_code pathError;
    const auto scannerPath = std::filesystem::canonical(scannerExecutable, pathError);
    if (pathError || !std::filesystem::is_regular_file(scannerPath, pathError) ||
        ::access(scannerPath.c_str(), X_OK) != 0) {
        return {ScanOutcomeKind::spawnFailure, std::nullopt, -1, 0, "invalidScannerExecutable"};
    }

    const auto requestID = juce::Uuid().toDashedString().toStdString();
    const auto taskPath =
        (std::filesystem::path(configuration_.taskRoot) / (std::string(taskPrefix) + requestID))
            .string();
    if (::mkdir(taskPath.c_str(), 0700) != 0) {
        return {ScanOutcomeKind::internalError, std::nullopt, -1, 0, "taskDirectoryCreationFailed"};
    }

    const auto requestPath = (std::filesystem::path(taskPath) / "request.json").string();
    const auto resultPath = (std::filesystem::path(taskPath) / "result.json").string();
    const auto stdoutPath = (std::filesystem::path(taskPath) / "stdout.log").string();
    const auto stderrPath = (std::filesystem::path(taskPath) / "stderr.log").string();
    ScanRequest request;
    request.requestID = requestID;
    request.pluginBundlePath = signature.canonicalPath;
    request.expectedCodeDirectoryHash = signature.codeDirectoryHash;

    const auto finish = [&](ScanOutcome outcome) {
        if (!removeOwnedTask(taskPath)) {
            if (outcome.kind == ScanOutcomeKind::success) {
                return ScanOutcome{ScanOutcomeKind::internalError, std::nullopt, -1, 0,
                                   "taskCleanupFailed"};
            }
            outcome.diagnosticCode +=
                outcome.diagnosticCode.empty() ? "taskCleanupFailed" : ".taskCleanupFailed";
        }
        return outcome;
    };
    if (!createSecureFile(requestPath, serializeScanRequest(request))) {
        return finish({ScanOutcomeKind::internalError, std::nullopt, -1, 0, "requestWriteFailed"});
    }

    FileDescriptor stdoutLog(createEmptySecureFile(stdoutPath));
    FileDescriptor stderrLog(createEmptySecureFile(stderrPath));
    std::array<int, 2> stdoutPipe{-1, -1};
    std::array<int, 2> stderrPipe{-1, -1};
    if (stdoutLog.get() < 0 || stderrLog.get() < 0 || !createPipe(stdoutPipe) ||
        !createPipe(stderrPipe)) {
        if (stdoutPipe[0] >= 0) {
            ::close(stdoutPipe[0]);
            ::close(stdoutPipe[1]);
        }
        return finish({ScanOutcomeKind::internalError, std::nullopt, -1, 0, "logSetupFailed"});
    }
    FileDescriptor stdoutRead(stdoutPipe[0]);
    FileDescriptor stdoutWrite(stdoutPipe[1]);
    FileDescriptor stderrRead(stderrPipe[0]);
    FileDescriptor stderrWrite(stderrPipe[1]);

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    if (posix_spawn_file_actions_init(&actions) != 0) {
        return finish({ScanOutcomeKind::spawnFailure, std::nullopt, -1, 0, "spawnActionsFailed"});
    }
    if (posix_spawnattr_init(&attributes) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        return finish({ScanOutcomeKind::spawnFailure, std::nullopt, -1, 0, "spawnSetupFailed"});
    }
    if (posix_spawn_file_actions_adddup2(&actions, stdoutWrite.get(), STDOUT_FILENO) != 0 ||
        posix_spawn_file_actions_adddup2(&actions, stderrWrite.get(), STDERR_FILENO) != 0 ||
        posix_spawn_file_actions_addclose(&actions, stdoutRead.get()) != 0 ||
        posix_spawn_file_actions_addclose(&actions, stderrRead.get()) != 0 ||
        posix_spawnattr_setflags(
            &attributes, static_cast<short>(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)) !=
            0 ||
        posix_spawnattr_setpgroup(&attributes, 0) != 0) {
        posix_spawn_file_actions_destroy(&actions);
        posix_spawnattr_destroy(&attributes);
        return finish({ScanOutcomeKind::spawnFailure, std::nullopt, -1, 0, "spawnSetupFailed"});
    }

    auto scannerArgument = scannerPath.string();
    auto requestArgument = requestPath;
    std::array<char*, 4> arguments{scannerArgument.data(), const_cast<char*>("--request"),
                                   requestArgument.data(), nullptr};
    auto environmentValues = childEnvironment(configuration_.inheritedEnvironmentKeys);
    std::vector<char*> environment;
    environment.reserve(environmentValues.size() + 1);
    for (auto& value : environmentValues) {
        environment.push_back(value.data());
    }
    environment.push_back(nullptr);
    pid_t child = -1;
    const auto spawnStatus = posix_spawn(&child, scannerArgument.c_str(), &actions, &attributes,
                                         arguments.data(), environment.data());
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    stdoutWrite = FileDescriptor();
    stderrWrite = FileDescriptor();
    if (spawnStatus != 0 || child <= 0) {
        return finish({ScanOutcomeKind::spawnFailure, std::nullopt, -1, 0, "spawnFailed"});
    }

    int waitStatus = 0;
    bool childExited = false;
    bool timedOut = false;
    bool childWaitFailed = false;
    std::size_t stdoutBytes = 0;
    std::size_t stderrBytes = 0;
    const auto deadline = std::chrono::steady_clock::now() + configuration_.timeout;
    while (!childExited && std::chrono::steady_clock::now() < deadline) {
        drainPipe(stdoutRead.get(), stdoutLog.get(), configuration_.maximumLogBytes, stdoutBytes);
        drainPipe(stderrRead.get(), stderrLog.get(), configuration_.maximumLogBytes, stderrBytes);
        const auto pollResult = pollProcessGroupLeader(child, waitStatus);
        if (pollResult == ChildPollResult::reaped) {
            childExited = true;
        } else if (pollResult == ChildPollResult::error) {
            childExited = true;
            childWaitFailed = true;
        } else {
            std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    }

    if (!childExited) {
        timedOut = true;
        signalProcessGroup(child, SIGTERM);
        const auto graceDeadline =
            std::chrono::steady_clock::now() + configuration_.terminationGrace;
        while (!childExited && std::chrono::steady_clock::now() < graceDeadline) {
            drainPipe(stdoutRead.get(), stdoutLog.get(), configuration_.maximumLogBytes,
                      stdoutBytes);
            drainPipe(stderrRead.get(), stderrLog.get(), configuration_.maximumLogBytes,
                      stderrBytes);
            const auto pollResult = pollProcessGroupLeader(child, waitStatus);
            if (pollResult == ChildPollResult::reaped) {
                childExited = true;
            } else if (pollResult == ChildPollResult::error) {
                childExited = true;
                childWaitFailed = true;
            } else {
                std::this_thread::sleep_for(std::chrono::milliseconds(5));
            }
        }
        if (!childExited) {
            childWaitFailed = !killAndReapProcessGroup(child, waitStatus);
            childExited = true;
        }
    }
    drainPipe(stdoutRead.get(), stdoutLog.get(), configuration_.maximumLogBytes, stdoutBytes);
    drainPipe(stderrRead.get(), stderrLog.get(), configuration_.maximumLogBytes, stderrBytes);
    static_cast<void>(::fsync(stdoutLog.get()));
    static_cast<void>(::fsync(stderrLog.get()));

    if (timedOut) {
        return finish({ScanOutcomeKind::timedOut, std::nullopt, -1,
                       WIFSIGNALED(waitStatus) ? WTERMSIG(waitStatus) : 0, "scannerTimedOut"});
    }
    if (childWaitFailed) {
        return finish({ScanOutcomeKind::invalidResult, std::nullopt, -1, 0, "childWaitFailed"});
    }
    if (WIFSIGNALED(waitStatus)) {
        return finish(
            {ScanOutcomeKind::crashed, std::nullopt, -1, WTERMSIG(waitStatus), "scannerCrashed"});
    }
    if (!WIFEXITED(waitStatus)) {
        return finish({ScanOutcomeKind::invalidResult, std::nullopt, -1, 0, "unknownChildStatus"});
    }

    const auto exitCode = WEXITSTATUS(waitStatus);
    if (exitCode != 0) {
        return finish({outcomeForExitCode(exitCode), std::nullopt, exitCode, 0,
                       "scannerExit" + std::to_string(exitCode)});
    }

    const auto postflightSignature = signatureInspector_->inspect(signature.canonicalPath);
    if (!sameBundleIdentity(signature, postflightSignature)) {
        return finish(
            {ScanOutcomeKind::invalidResult, std::nullopt, exitCode, 0, "bundleChangedDuringScan"});
    }

    std::string resultJSON;
    ScanResult result;
    std::string parseError;
    if (!readSecureFile(resultPath, maximumResultBytes, resultJSON) ||
        !parseScanResult(resultJSON, result, parseError) ||
        !resultMatchesPreflight(result, request, signature)) {
        return finish({ScanOutcomeKind::invalidResult, std::nullopt, exitCode, 0,
                       parseError.empty() ? "resultMismatch" : parseError});
    }
    return finish({ScanOutcomeKind::success, std::move(result), exitCode, 0, {}});
}

std::size_t
PluginScanCoordinator::cleanupStaleTasks(std::chrono::system_clock::time_point now) const {
    std::size_t removed = 0;
    std::error_code iteratorError;
    for (const auto& entry :
         std::filesystem::directory_iterator(configuration_.taskRoot, iteratorError)) {
        if (iteratorError) {
            break;
        }
        const auto name = entry.path().filename().string();
        if (!isTaskName(name)) {
            continue;
        }
        struct stat status{};
        if (::lstat(entry.path().c_str(), &status) != 0 || !S_ISDIR(status.st_mode) ||
            S_ISLNK(status.st_mode) || status.st_uid != ::getuid()) {
            continue;
        }
        const auto modified = std::chrono::system_clock::from_time_t(status.st_mtimespec.tv_sec);
        if (now - modified < staleAge) {
            continue;
        }
        if (removeOwnedTask(entry.path().string())) {
            ++removed;
        }
    }
    return removed;
}

bool PluginScanCoordinator::removeOwnedTask(const std::string& taskPath) const {
    const auto path = std::filesystem::path(taskPath);
    std::error_code canonicalError;
    const auto canonicalRoot =
        std::filesystem::weakly_canonical(configuration_.taskRoot, canonicalError);
    const auto canonicalParent =
        std::filesystem::weakly_canonical(path.parent_path(), canonicalError);
    if (canonicalError || canonicalParent != canonicalRoot ||
        !isTaskName(path.filename().string())) {
        return false;
    }

    FileDescriptor directory(::open(taskPath.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW));
    struct stat directoryStatus{};
    if (directory.get() < 0 || ::fstat(directory.get(), &directoryStatus) != 0 ||
        !S_ISDIR(directoryStatus.st_mode) || directoryStatus.st_uid != ::getuid() ||
        !exactMode(directoryStatus.st_mode, 0700)) {
        return false;
    }

    if (!removeDirectoryContents(directory.get(), 0)) {
        return false;
    }
    directory = FileDescriptor();
    return ::rmdir(taskPath.c_str()) == 0;
}

} // namespace shitate::plugins
