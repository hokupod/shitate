<!-- SPDX-License-Identifier: AGPL-3.0-only -->
<!-- Copyright (C) 2026 Hokuto Takemiya -->

# v0.1 threat model

## Scope and assets

This model covers `Shi-tate.app`, `ShitatePluginScanner`, local persistence,
CoreAudio routing, CI, and release artifacts. BlackHole, communication apps,
macOS, and user-installed VST3 code are external dependencies.

Assets to protect are microphone confidentiality, output routing integrity,
saved settings/VST3 state, diagnostic privacy, user file access, release
integrity, and a recoverable next launch.

## Trust boundaries

1. **Microphone → audio callback**: live audio must remain memory-only and reach
   only the explicitly configured BlackHole path.
2. **Filesystem → scanner**: VST3 paths, signatures, architecture, classes, and
   fingerprints are untrusted input.
3. **Scanner → app**: bounded JSON is parsed strictly; scanner failure is not
   trusted as a compatibility result.
4. **Catalog → runtime load**: canonical path and cdhash are revalidated
   immediately before the in-process load.
5. **App → local storage/clipboard**: state and diagnostics must not expose raw
   identifiers, private paths, audio, or plug-in state unexpectedly.
6. **Repository → CI/release**: Actions, submodules, permissions, credentials,
   signatures, and artifacts are supply-chain inputs.

## Threats, controls, and residual risk

| Threat | Implemented control and evidence | Residual risk |
|---|---|---|
| Malicious/replaced VST3 | Canonical containment, Security.framework validation, architecture/class/layout policy, exact cdhash immediately before load, explicit ad-hoc approval | Signed code may still be malicious; runtime code shares the app process and user permissions |
| Scanner crash/hang | One bundle per helper process, bounded protocol, timeout, terminate/kill/reap integration tests | Scanner is not a runtime sandbox and still reads the selected bundle |
| Runtime crash/hang | Atomic write-before-load journal, dirty-run history, next-launch safe mode, exact-fingerprint block after three crashes, disposable crash test | Current call can still fail; native runtime isolation is deferred |
| Wrong audio destination | Exact saved device identities, 48 kHz/allowed buffers, no fallback, mute/stop on device or permission loss | CoreAudio/driver defects remain external; long-duration manual gates remain required |
| Non-finite plug-in output | Per-slot backup/restore/fault and final output safety tests | A plug-in can consume CPU, hang, or alter other process memory before detection |
| Persistence traversal/symlink or corruption | Owner-only directories/files, `O_NOFOLLOW`, link/owner/mode/size/schema validation, atomic rename/fsync, future-schema fail-closed tests | A process already acting as the user may modify user-owned files |
| Diagnostic disclosure | Asynchronous bounded logs, 5 MiB × three rotations, home redaction, scoped UID hash, 64 KiB explicit-copy report, negative tests | Plug-in names and device display names remain intentionally visible to the user |
| App-originated exfiltration | `JUCE_USE_CURL=0`, web browser disabled, no app HTTP client, linked framework/symbol checks, no updater/telemetry/upload | In-process VST3 may initiate network access independently |
| Release tampering | arm64/minimum-OS checks, explicit nested-code verification, least entitlements, Developer ID/notary/staple gates, SHA-256, provenance, no-overwrite draft release | Developer ID/notary/Gatekeeper are externally blocked until credentials and release authority are supplied |
| CI compromise | Immutable Action SHAs, exact JUCE pin, Nix tool environment, `contents: read` defaults, no `pull_request_target`, no PR secrets, protected release job | GitHub/Xcode/Nix binary infrastructure remains trusted |

## Entitlement decision

App Sandbox is disabled for v0.1 because common VST3 plug-ins need license,
preset, and content access. Hardened Runtime remains enabled. The app has audio
input and disables Library Validation; the scanner disables Library Validation
but has no audio-input entitlement. JIT, unsigned executable memory,
executable-page protection disable, DYLD environment, and `get-task-allow` are
forbidden in release code.

Disabling Library Validation is a deliberate compatibility tradeoff, not a
containment mechanism. Users must load only VST3 bundles they trust.

## Privacy and data lifecycle

Shi-tate does not record audio, meter history, continuous parameters,
communication-app activity, analytics, telemetry, crash reports, or remote
configuration. `Copy Diagnostics` is an explicit clipboard action; the report
is neither sent nor automatically persisted. Local VST3 state is required for
session restore and remains owner-only.

## Release authority boundary

Normal CI runs untrusted changes with read-only repository permission and no
secrets. The release job depends on a completed test job, names the protected
`release` environment, and alone receives `contents: write`, `id-token: write`,
attestation permission, and signing/notary secrets. A tag-triggered release
requires a GitHub-verified annotated signed tag from the configured tagger, an
immutable `v*.*.*` tag ruleset, and publication-time revalidation of the exact
tag-object SHA. Manual dispatch still requires the protected environment
approval.

Creating a production tag, using credentials, notarizing, uploading, or
publishing remains an explicit operator action. Local ad-hoc verification does
not count as signed-release evidence.

## Change triggers

Revisit this model for any new entitlement, network-capable framework/symbol,
persisted field, diagnostic field, plug-in format, output destination, runtime
process boundary, updater, or release credential path. Re-run manual audio and
performance gates after changes to JUCE, Xcode, CoreAudio routing, buffers, or
the callback.
