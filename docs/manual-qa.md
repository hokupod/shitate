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

## v0.2 main-output Preview record

- Recorded: 2026-08-07 23:22 (JST)
- Build: local `0.2.0-dev` Debug `ALL_BUILD` succeeded.
- Automated suite: 29 registered, 28 passed, 0 failed, 1 hardware opt-in skip.
- Device contract: `DeviceServiceTest` accepts only the exact default-output UID
  and rejects BlackHole, aggregate, virtual, dead, mono, non-48-kHz, unsupported
  buffer, missing default, changed UID, and Manual Aggregate Preview cases.
- State contract: Swift tests cover stopped/running/muted entry, captured
  `wasRouting`/`wasMuted`, explicit return, real output naming, and return-context
  destruction on each failure phase.
- Regression contract: existing callback bounds, allocation policy, NaN/Inf
  removal, private aggregate evidence, BlackHole identity, and stop quiescence
  tests remain in the passing suite.
- Preview hardware gate: AT2040USB input and the current AT2040USB main output
  passed muted 48 kHz runs at 128, 256, and 512 frames. Every run reported a
  private aggregate, exact subdevices, output clock ownership, input drift
  compensation, asynchronous stop completion, and xrun 0.
- Default-output change gate: during a muted 256-frame Preview, the default was
  temporarily changed to the unique physical EV2785 output. The callback
  reported `previewOutputChanged`, fail-closed reached `blocked`, and the exact
  original AT2040USB default-output UID was restored and independently
  re-observed through System Profiler. This was a controlled one-time gate; the
  committed test does not mutate the system default because crash-safe
  supervision is not yet implemented.
- Interactive verification: the user reported that the v0.2 main-output Preview
  operated successfully. The exact output device, plug-in, prior routing state,
  and mute state were not recorded.

| v0.2 Preview path | Status | Evidence boundary |
|---|---|---|
| Default-output identity and format enforcement | VERIFIED | Unit rejection matrix plus live exact-default 48 kHz runs at 128/256/512 frames |
| Start/Stop return context and mute preservation | AUTOMATED | State transition tests; no acoustic output |
| Processed audio on the macOS main output | USER-REPORTED | Interactive confirmation; exact hardware and plug-in were not recorded |
| Private aggregate excludes BlackHole during Preview | VERIFIED | Live `subdevicesMatch=1` with only the selected input and exact default-output target expected |
| No simultaneous signal on BlackHole | UNVERIFIED | Requires measuring both destinations during Preview |
| Default-output change stops Preview | VERIFIED | Live AT2040USB → EV2785 switch produced `previewOutputChanged=1`, `blocked`, and exact default restoration |
| Preview-output disconnection stops Preview | UNVERIFIED | Default change passed; physical disconnect was not performed |
| Explicit Stop restores prior BlackHole running/muted state | UNVERIFIED | State contract is automated; live route restoration not performed |
| Click-free transitions and acoustic quality | UNVERIFIED | No explicit click or quality evaluation was reported |
| Short Preview runs at 128/256/512 with xrun 0 | VERIFIED | Muted AT2040USB hardware gates; 250 ms per buffer size |
| Long-duration xrun 0 | UNVERIFIED | No Preview endurance run was performed |

These results confirm only the user-reported audible main-output Preview path.
They do not claim acoustic quality, clickless transitions, live output
signal exclusivity on BlackHole, physical-disconnect behavior, explicit
BlackHole restoration, or long-duration xrun 0. Those claims require the
hardware cases above to be run and recorded separately.

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
| Add, edit, bypass, reorder, remove third-party VST3 | PARTIAL | User-approved RNNoise loaded and its native editor opened; bypass, reorder, and remove remain unverified |
| Menu-bar mute | VERIFIED | Earlier live-meter sequence in this document; no acoustic monitoring |
| Main-window hide and reopen | UNVERIFIED | Requires a stable post-build accessibility attachment |
| Quit and fresh-process session restore | UNVERIFIED | Persistence round-trip is automated; final screen was not re-inspected |
| Incomplete plug-in recovery choices | UNVERIFIED | Controls are present; no third-party bundle was invalidated manually |
| Zoom or Google Meet microphone selection | UNVERIFIED | No communication app was exercised |

## Third-party editor follow-up record

- Recorded: 2026-08-07 18:32 (JST)
- Build: local `0.1.0-dev` Debug app with the editor-window attachment fix
- Plug-in: RNNoise suppression for voice 1.10 by werman, restored from the
  user-approved session with fingerprint prefix `8ace66d08bd3`
- Interaction: Edit opened the native RNNoise controls in a separate foreground
  window; closing and selecting Edit again reopened the same editor successfully
- Observability: the local owner-only log recorded
  `pluginEditorOpenRequested` and `pluginEditorOpenSucceeded` with slot number,
  routing state, editor capability, and truncated fingerprint
- Boundary: two open/close cycles passed without changing plug-in parameters;
  bypass, reorder, remove, audio quality, and the 100-cycle reliability gate were
  not exercised

## Phase 7 recovery and release-policy record

- Recorded: 2026-08-07 17:25 (JST)
- Source: clean, reviewed Phase 7 branch HEAD; exact commits are embedded in the
  app Info.plist and recursive source metadata
- Host/toolchain: Apple Silicon, macOS 26.5.2 (25F84), Xcode 26.6
- Full CTest: 28 registered, 27 passed, 0 failed, 1 hardware opt-in skip
- Recovery label: 2/2 passed, including direct `waitpid` proof that the
  disposable runtime CrashPlugin reached `processBlock` and terminated by
  SIGABRT, followed by fresh-process safe mode before plug-in factory use
- Security label: 3/3 passed, including entitlement/content/network negative
  fixtures and GitHub workflow-policy negative fixtures
- Release build: `BUILD_TESTING=OFF`, arm64, minimum macOS 14.0, ad-hoc
  Hardened Runtime app/helper; explicit nested-code and entitlement checks passed
- Network boundary: no WebKit/CFNetwork/Network/libcurl dependency and no
  `NSURLSession`, `CFHTTP`, `NWConnection`, curl, or WKWebView symbol in the
  release app/helper after dead stripping the unused JUCE URL backend
- Local package: `Shi-tate_0.1.0_arm64.dmg` created as UDZO/HFS+ and its
  adjacent SHA-256 verified; this is not Developer ID/notarization evidence
- Source archive: `LOCAL PASS`; SHA-256 and recursive JUCE hashes verified, then
  a clean extraction under an unrelated parent Git checkout built 39 targets
  and ran all 28 registered tests without a dependency download
- Local provenance: in-toto statement covers the DMG, recursive source archive,
  and third-party notices at the embedded exact commit; no hosted attestation is
  claimed
- Remote CI/CodeQL: `UNVERIFIED`; workflow policy is tested locally, but no
  GitHub-hosted run is claimed

### Design §24.5 reliability matrix

| Required case | Status | Evidence boundary |
|---|---|---|
| Two-hour zero-plug-in passthrough, xrun 0 | UNVERIFIED | Only 250 ms short hardware gates passed |
| Two-hour three-plug-in chain, xrun 0 | UNVERIFIED | No three-plug-in hardware run |
| Eight-hour soak, host growth under 10 MB | UNVERIFIED | Duration/performance run not performed |
| Physical input and BlackHole removal | UNVERIFIED | Fail-closed reducer/policy tests pass; hot-unplug not performed |
| Ten sleep/wake cycles | UNVERIFIED | Delay/coalescing/default-off policy tests pass; real cycles not performed |
| Sample-rate and buffer changes | PARTIAL | 128/256/512 short gates pass; live rate/buffer mutation not performed |
| 100 editor open/close cycles | UNVERIFIED | Desktop-attachment regression test and two live RNNoise cycles pass; count gate not performed |
| Runtime CrashPlugin → next-launch safe mode | AUTOMATED PASS | Disposable child crash and fresh-process run-state harness |
| 1,000 global mute toggles | UNVERIFIED | Single live UI sequence and audio-unit ramp tests only |
| Zoom and Google Meet dual mono | UNVERIFIED | Neither communication application was exercised |

### Design §28 completion evidence

| Area | Status | Evidence or blocker |
|---|---|---|
| arm64/macOS 14 binary contract | AUTOMATED PASS | Release Mach-O architecture and minimum-OS checks; macOS 14 runtime launch remains unverified |
| Physical microphone/channel and BlackHole 48 kHz route | PARTIAL | AT2040USB short gate, exact BlackHole route, 128/256/512, xrun 0; long/communication-app gates remain |
| Eight-slot VST3 chain/editor/bypass/reorder/state | AUTOMATED PASS | Deterministic fixtures and workflow tests plus live RNNoise editor open/reopen; broad third-party compatibility remains unverified |
| Global mute and menu-bar residency | PARTIAL | Live mute state/meter sequence and UI tests; long/repeated interaction gates remain |
| Scanner isolation/reaping and non-finite safety | AUTOMATED PASS | Crash/hang scanner integration and per-slot/final safety tests |
| Fail-closed device/sleep/wake recovery | AUTOMATED PASS | State/event policy and race tests; hot-unplug and ten real sleep cycles remain unverified |
| Dirty shutdown safe mode and repeated-fingerprint block | AUTOMATED PASS | Run-state unit matrix and disposable runtime crash integration |
| Diagnostics redaction/bounds/rotation | AUTOMATED PASS | Home/UID/control/oversize/forbidden-marker negative tests and 5 MiB × three-rotation policy |
| No app networking/admin/shell/bundled driver or VST3 | AUTOMATED PASS | Source, Mach-O dependency/symbol, entitlement, and bundle policy tests |
| Ad-hoc release layout and DMG/SHA-256 | LOCAL PASS | Explicitly not distribution-signing evidence |
| Developer ID, notarization, staple, Gatekeeper | BLOCKED | No credential use or release authority was provided; no production release attempted |
| Recursive source rebuild and provenance | LOCAL PASS | Exact source metadata overrides an unrelated parent Git checkout; clean extraction built, tested, and produced local in-toto provenance without dependency download |
| Remote CI and CodeQL | UNVERIFIED | No push or remote workflow run was authorized |

No tag, GitHub Release, upload, signing credential, or notarization service was
used during this record.

## Reproduction command

Run only on a Mac where microphone access has been explicitly granted. Prefer a
unique display name; a private UID is also supported and is never printed.

```bash
SHITATE_RUN_AUDIO_HARDWARE_TESTS=1 \
SHITATE_TEST_INPUT_NAME='AT2040USB' \
SHITATE_TEST_BUFFER_FRAMES=256 \
ctest --test-dir build/dev -C Debug -R AudioHardwareIntegrationTest -V
```

Preview uses the current physical macOS default output and starts muted:

```bash
SHITATE_RUN_AUDIO_HARDWARE_TESTS=1 \
SHITATE_TEST_PREVIEW=1 \
SHITATE_TEST_INPUT_NAME='AT2040USB' \
SHITATE_TEST_BUFFER_FRAMES=256 \
ctest --test-dir build/dev -C Debug -R AudioHardwareIntegrationTest -V
```

The test records only aggregate-property booleans, target kind, mute state,
actual format, latency, and xrun count. It never prints device UIDs or changes
the system default. It fails if the aggregate is not private, the exact output
does not own the clock, input drift compensation is absent, or the requested
short-run contract changes.

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
