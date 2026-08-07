<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (C) 2026 Hokuto Takemiya -->

# v0.2 architecture

This document describes the implemented `0.2.0-dev` architecture. The
[detailed design](design.md) remains canonical when this summary and the design
disagree.

## System context

```text
physical microphone
  → CoreAudio private aggregate or explicit manual aggregate
  → Shi-tate audio callback
  → 0–8 in-process VST3 Audio Effects
  → final non-finite/output-safety stage
  ├→ BlackHole 2ch as stereo dual mono
  │   → user-selected communication application
  └→ current physical macOS main output as exclusive Preview
```

Shi-tate never selects a communication application and never falls back to
another input or output. The physical main output is used only after an explicit
`Start Preview`; a default-output change stops Preview instead of following it.
BlackHole and all user VST3 bundles are installed separately.

## Executable components

| Component | Responsibility | Trust boundary |
|---|---|---|
| `Shi-tate.app` | SwiftUI product state, persistence, recovery, Objective-C++ bridge, JUCE audio core, runtime VST3 | Runtime VST3 executes in this process with user permissions |
| `ShitatePluginScanner` | Validate and scan exactly one VST3 bundle per invocation | Separate process; timeout/crash cannot corrupt the parent process |
| Test-only VST3 and harnesses | Deterministic failure, audio, and recovery evidence | Built only with `BUILD_TESTING=ON`; forbidden from release bundles |

The app uses AppKit/SwiftUI system controls and semantic accessibility labels.
The C++20/JUCE core is hidden behind `ShitateBridge`; Swift does not enter the
real-time callback.

## Startup and shutdown ordering

Startup is deliberately ordered:

1. Atomically publish a dirty `run-state.json` before scanning, configuring
   CoreAudio, or loading any runtime VST3.
2. Decide safe mode from the prior run, crash history, migration state, and
   blocked fingerprints.
3. In safe mode, load no VST3, open no editor, and start no BlackHole output.
4. Outside safe mode, validate the catalog, enumerate devices, restore the
   session, and configure routing while stopped.
5. Immediately before every runtime load, persist the slot ID, name, and exact
   fingerprint. Clear it only after the asynchronous load completes.

Clean shutdown is recorded only after routing has stopped, editors have closed,
and any required session save has completed. A crash or forced termination
therefore leaves fail-safe evidence for the next process.

## Audio and control planes

The audio callback performs bounded audio work only. It does not allocate,
wait on a lock, call Swift/Foundation/UI, access files, serialize state, log, or
reconfigure a device. Cross-thread events use bounded queues and atomics.

All device, plug-in-chain, persistence, diagnostics, and UI changes occur on
the control/MainActor side while stopped or through an explicit stop–mutate–
restart sequence. Each plug-in slot restores its input on exceptions or
non-finite output; the final output stage prevents NaN/Inf from reaching
either BlackHole or Preview.

## Preview lifecycle

Preview reuses the same input mapper, serial VST3 chain, safety stage, meters,
mute, and start/stop ramps. It is an exclusive alternate `AudioOutputTarget`,
never a second callback output.

1. Capture whether BlackHole routing is running and the current mute state.
2. Fade and stop the current route, if running.
3. Re-read the macOS default-output UID, require a live physical non-aggregate
   stereo device at 48 kHz with a shared 128/256/512-frame buffer, then
   create a private aggregate using that output as clock.
4. Start Preview with the captured mute state.
5. On explicit `Stop Preview`, fade and stop, restore the validated BlackHole
   configuration, and restart only if step 1 captured an active route.

Manual Aggregate mode cannot start Preview. Preview state and its output UID are
not persisted. Output change/disconnection, sleep, permission loss, error, or
termination cancels the return context and leaves audio stopped; wake and launch
never restore Preview.

## Device and workspace recovery

- Missing microphone or BlackHole: mute, stop, block, and select no fallback.
- Preview output change or disconnection: immediately prevent callback commit,
  mute/stop, report a Preview-specific error, and require a new explicit start.
- Unsupported sample rate or buffer: stop and perform at most one automatic
  reset before requiring manual resolution.
- Sleep: always stop.
- Wake: coalesce notifications, wait one second, re-enumerate devices, validate
  the saved configuration and plug-ins, and resume only after explicit
  `resumeAfterWake` opt-in and complete validation. The default is off.
- Permission loss: mute, stop, and direct the user to System Settings without a
  repeated automatic prompt.

## Local data

Owner-only state is stored under
`~/Library/Application Support/dev.hokupod.shitate/`:

- `settings.json`, `scan-folders.json`, and `plugin-catalog.json`;
- `run-state.json` and `blocked-plugins.json`; and
- `sessions/<id>/session.json` plus bounded VST3 state blobs.

Directories are normalized to `0700`; regular state files are atomically
published as `0600` and validated against symlink, owner, link-count, size, and
schema constraints. Unknown future schemas fail closed. No audio is persisted.

Asynchronous diagnostic logs live under `~/Library/Logs/Shitate/`. The current
file is capped at 5 MiB with three rotated generations. Raw home paths and
CoreAudio UIDs are redacted; audio, VST3 state, clipboard data, meter history,
and communication-app details are forbidden.

## Build and release layers

CMake is the only project source of truth. The Nix flake supplies missing CLI
tools while Xcode supplies the macOS SDK and Apple toolchain. JUCE is pinned to
`f8f8864172464b9adf9eba6101e1f784838d1597`.

Release builds disable test targets, build only arm64 for macOS 14+, enable
Hardened Runtime, and enumerate app/helper entitlements, Mach-O dependencies,
symbols, executable permissions, and bundle contents. The release workflow is
separately gated for signing/notarization and refuses to overwrite an existing
GitHub release or asset set.

The recursive source archive contains the exact JUCE source, normalized archive
metadata, a JUCE file-hash manifest, and source commit metadata. Its extracted
tree bootstraps, builds, and tests without Git metadata or dependency download.

## Non-goals and residual risk

v0.2 does not isolate runtime VST3. A trusted-signature check identifies code;
it does not make that code safe. A loaded plug-in can crash or hang the app and,
because App Sandbox and Library Validation are disabled for compatibility, can
access resources available to the user. Safe mode reduces repeat-crash impact
but cannot contain a malicious or faulty in-process plug-in.

See the [threat model](threat-model.md), [manual evidence](manual-qa.md), and
[plug-in compatibility contract](plugin-compatibility.md).
