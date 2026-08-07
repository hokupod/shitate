// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import Darwin
import Foundation

@main
struct RecoveryStateHarness {
    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            fail(
                "usage: RecoveryStateHarness <mark-and-crash|assert-safe-mode> <support> [runtime-host fingerprint]"
            )
        }
        let support = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let paths = ApplicationPaths(
            applicationSupportDirectory: support,
            logsDirectory: support.appendingPathComponent("logs", isDirectory: true)
        )
        let service = RunStateService(paths: paths)

        do {
            switch arguments[1] {
            case "mark-and-crash":
                guard arguments.count == 5 else {
                    fail("mark-and-crash requires a runtime host and exact fingerprint")
                }
                _ = try service.beginRun()
                try service.recordOperation(
                    "loadingPlugin",
                    loadingPlugin: LoadingPluginDocument(
                        slotID: UUID(),
                        pluginFingerprint: arguments[4],
                        pluginName: "CrashPlugin"
                    )
                )
                execRuntimeHost(arguments[3])
            case "assert-safe-mode":
                let decision = try service.beginRun()
                guard
                    decision.entersSafeMode,
                    decision.suspectPlugin?.pluginName == "CrashPlugin"
                else {
                    fail("fresh process did not enter safe mode before plug-in code")
                }
                print("safe-mode-before-plugin-factory")
            default:
                fail("unknown recovery harness command")
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func execRuntimeHost(_ executable: String) -> Never {
        let executableArgument = strdup(executable)
        let crashArgument = strdup("--crash")
        guard executableArgument != nil, crashArgument != nil else {
            free(executableArgument)
            free(crashArgument)
            fail("runtime host arguments could not be allocated")
        }
        var arguments: [UnsafeMutablePointer<CChar>?] = [
            executableArgument,
            crashArgument,
            nil,
        ]
        let result = executable.withCString { path in
            arguments.withUnsafeMutableBufferPointer { buffer in
                Darwin.execv(path, buffer.baseAddress)
            }
        }
        free(executableArgument)
        free(crashArgument)
        fail("runtime host exec failed with errno \(errno), result \(result)")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Darwin.exit(1)
    }
}
