<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (C) 2026 Hokuto Takemiya -->

# Manual audio QA

This document separates automated checks from claims that require real audio
hardware and communication applications. `UNVERIFIED` is not a pass.

## Automated-session record

- Recorded: 2026-08-07 07:10 (JST)
- Host: Apple Silicon (`arm64`), macOS 26.5.2 (25F84)
- Toolchain: Xcode 26.6 (17F113)
- JUCE: `f8f8864172464b9adf9eba6101e1f784838d1597`
- Audio inventory: `system_profiler SPAudioDataType` returned no device entries in
  the execution environment.
- Hardware opt-in: not provided; no microphone or BlackHole routing claim was
  made.

The default CTest run executes `AudioHardwareIntegrationTest` with return code
77. CTest must report it as `Skipped`, with an explicit opt-in reason.

## Short hardware-gate record

- Recorded: 2026-08-07 08:47 (JST)
- Source: current Plan 003 worktree based on `6ce7115`
- Input: AT2040USB, channel 1
- Output: BlackHole 2ch 0.7.1 (`audio.existential.BlackHole2ch`)
- Command result: exit 0 after 250 ms routing and asynchronous stop
- Aggregate: found, private, exact subdevices matched
- Clock/drift: BlackHole clock, physical-input drift compensation enabled
- Actual formats and latency:
  - 48,000 Hz / 128 frames: 276 input samples / 228 output samples
  - 48,000 Hz / 256 frames: 404 input samples / 356 output samples
  - 48,000 Hz / 512 frames: 660 input samples / 612 output samples
- CoreAudio xruns: 0 in every short run
- Post-review rerun: 2026-08-07 09:21 (JST), 48,000 Hz / 256 frames,
  404 input samples / 356 output samples, exact private-aggregate evidence, xrun 0

This short gate proves configuration and lifecycle properties only. It does not
substitute for the two-hour, communication-app, hot-unplug, or sleep/wake cases.

## Interactive UI-state record

- Recorded: 2026-08-07 09:00 (JST)
- Tool: macOS accessibility state inspection with the Debug app
- Sequence: Ready → Routing → Muted → Routing → Ready
- Actual format: 48,000 Hz / 256 frames
- Routing: input and output meters both reported the live microphone signal
- Muted: input remained live while output reported `-96.0 dB`
- Unmuted: output resumed and matched the input meter
- Final CoreAudio xrun count: 0
- Controls: start/stop and mute/unmute labels, enabled states, and status descriptions matched
  every transition

This interaction did not monitor audio acoustically, so it does not verify that
the fades were click-free. A stopped-meter residue found during the interaction
was fixed in Core and covered by `AudioEngineTest` before this record was closed.

## Phase 6 onboarding record

- Recorded: 2026-08-07 14:18 (JST)
- Build: local `0.1.0-dev` Debug app after the Phase 6 SwiftUI composition
- Tool: macOS Computer Use accessibility tree plus visual screenshots
- BlackHole: detected as BlackHole 2ch; no installer or device UID was accessed
- Permission: the user approved the Shi-tate microphone prompt; onboarding then
  exposed `Microphone access is allowed`; approval was reconfirmed at
  2026-08-07 14:36 (JST)
- Input: AT2040USB, selected channel 1
- Validation: 48,000 Hz / 256 frames reached `Ready and stopped`
- Plug-ins: isolated scan reported one compatible local entry; the onboarding
  chain intentionally remained empty
- Zero-plug-in path: Welcome → BlackHole → permission → audio selection → audio
  validation → scan → empty chain → call-app guide completed
- Persistence: the default zero-plug-in session and settings were published as
  owner-only (`0600`) files; no audio or raw device UID was recorded here
- Product-flow boundary: Zoom/Meet selection and acoustic monitoring remain
  `UNVERIFIED`

The same checkout then passed the opt-in AT2040USB → BlackHole 2ch hardware gate:
private aggregate, exact subdevices, BlackHole clock, input drift compensation,
48,000 Hz / 256 frames, 404 input samples, 356 output samples, and xrun 0.

| Phase 6 product path | Status | Evidence boundary |
|---|---|---|
| First launch and onboarding | VERIFIED | Computer Use accessibility tree and screenshots |
| BlackHole missing branch | AUTOMATED | Model branch test only; installed driver prevented a manual missing-device run |
| Permission request and grant | VERIFIED | User-approved macOS prompt and allowed-state UI |
| Physical input selection and 48 kHz validation | VERIFIED | AT2040USB, channel 1, 256 frames |
| Zero-plug-in scan, save, and completion | VERIFIED | One compatible catalog entry; empty session saved with mode `0600` |
| Add, edit, bypass, reorder, remove third-party VST3 | UNVERIFIED | No third-party plug-in was loaded during this privacy-safe run |
| Menu-bar mute | VERIFIED | Earlier live-meter sequence in this document; no acoustic monitoring |
| Main-window hide and reopen | UNVERIFIED | Requires a stable post-build accessibility attachment |
| Quit and fresh-process session restore | UNVERIFIED | Persistence round-trip is automated; final screen was not re-inspected |
| Incomplete plug-in recovery choices | UNVERIFIED | Controls are present; no third-party bundle was invalidated manually |
| Zoom or Google Meet microphone selection | UNVERIFIED | No communication app was exercised |

## Reproduction command

Run only on a Mac where microphone access has been explicitly granted. Prefer a
unique display name; a private UID is also supported and is never printed.

```bash
SHITATE_RUN_AUDIO_HARDWARE_TESTS=1 \
SHITATE_TEST_INPUT_NAME='AT2040USB' \
SHITATE_TEST_BUFFER_FRAMES=256 \
ctest --test-dir build/dev -C Debug -R AudioHardwareIntegrationTest -V
```

The test records only aggregate-property booleans, actual format, latency, and
xrun count. It fails if the aggregate is not private, BlackHole does not own the
clock, input drift compensation is absent, or the requested format changes.

## Required hardware evidence

| Case | Required result | Status | Evidence |
|---|---|---|---|
| Automatic private aggregate | BlackHole clock; microphone drift correction; private aggregate | VERIFIED | 2026-08-07 short hardware gates; exact subdevices matched |
| Two-hour passthrough | 48 kHz / 256 frames; xrun count 0 | UNVERIFIED | Requires dedicated hardware run |
| Zoom input | Dual mono on BlackHole channels 1 and 2 | UNVERIFIED | Zoom not exercised |
| Google Meet input | Dual mono on BlackHole channels 1 and 2 | UNVERIFIED | Browser call not exercised |
| Start, stop, and mute | No obvious clicks across ramps | UNVERIFIED | Requires monitored audio |
| Microphone removal | Immediate silence; no alternate input | UNVERIFIED | Requires hot-unplug test |
| BlackHole removal | Immediate silence; no speaker or alternate output | UNVERIFIED | Requires driver/device test |
| Buffer sizes | 128, 256, and 512 where hardware supports them | VERIFIED | AT2040USB + BlackHole passed all three at 48 kHz; xrun 0 in each short run |
| Sleep and wake | Ten cycles; stopped on sleep; no default resume | UNVERIFIED | Requires full workspace cycle |
| Manual aggregate | Explicit offsets route only to BlackHole pair | UNVERIFIED | Requires user-created aggregate |

## Evidence to capture during a run

- Timestamp from
  `perl -MPOSIX -le 'print strftime("%Y-%m-%d %H:%M (JST)", localtime)'`.
- `git rev-parse HEAD`, app version, macOS build, Xcode version, microphone model,
  and BlackHole version.
- Input/output display names and truncated UID hashes only; never raw UIDs.
- Exact sample rate, buffer frames, input/output latency, duration, final xrun
  count, and communication-app versions.
- Observed result and reproduction notes for every table row; leave unavailable
  cases `UNVERIFIED`.
