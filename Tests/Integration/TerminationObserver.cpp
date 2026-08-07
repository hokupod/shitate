// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include <cerrno>
#include <iostream>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char** argv) {
    if (argc < 2) {
        std::cerr << "usage: ShitateTerminationObserver <executable> [arguments...]\n";
        return 2;
    }

    const auto child = ::fork();
    if (child < 0) {
        std::cerr << "fork failed\n";
        return 1;
    }
    if (child == 0) {
        ::execv(argv[1], argv + 1);
        ::_exit(127);
    }

    int status = 0;
    pid_t waited = -1;
    do {
        waited = ::waitpid(child, &status, 0);
    } while (waited < 0 && errno == EINTR);

    if (waited != child) {
        std::cerr << "waitpid failed\n";
        return 1;
    }
    if (WIFSIGNALED(status)) {
        std::cout << "termination=signal:" << WTERMSIG(status) << '\n';
        return 0;
    }
    if (WIFEXITED(status)) {
        std::cout << "termination=exit:" << WEXITSTATUS(status) << '\n';
        return 0;
    }

    std::cerr << "child did not terminate\n";
    return 1;
}
