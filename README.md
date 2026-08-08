[English](README.md) | [日本語](README.ja.md) | [简体中文](README.zh-CN.md)

# Shi-tate

**Tailor your voice before it reaches the call.**

Shi-tate (Shitate / 仕立て) is an open-source VST3 audio input FX host for
macOS. It processes one physical microphone channel through a personal effect
chain and routes stereo dual mono to communication apps through BlackHole 2ch.

The Japanese word 仕立て means tailoring something for a particular person or
purpose. Shi-tate lets you tailor your microphone signal before it reaches the
call.

## Status

> [!WARNING]
> **Pre-alpha — not yet production-ready.** Version `0.2.0-dev` is under
> implementation. There is no installable release or broad third-party VST3
> compatibility evidence.

Do not rely on Shi-tate for a call, recording, or production workflow until the
relevant automated and manual evidence is published.

## v0.2 scope

- Apple Silicon (`arm64`) and macOS 14 or later.
- Select one physical microphone channel and convert it to stereo dual mono.
- Process up to eight serial, user-provided arm64 VST3 Audio Effects.
- Route to externally installed BlackHole 2ch at 48 kHz.
- Explicitly preview the processed signal on the current physical macOS main
  output, exclusively instead of BlackHole.
- Isolate one-bundle-at-a-time VST3 scanning in a helper process.
- Fail closed to silence when a saved device, format, or plug-in is invalid.
- Start in safe mode after a dirty shutdown before loading any VST3.
- Keep app settings and plug-in state locally; never store audio.

## Non-goals

v0.2 does not include a virtual driver, BlackHole or VST3 redistribution,
Intel/Windows/Linux support, AU/CLAP/VST2, resampling, sidechains, instruments,
simultaneous BlackHole/main-output monitoring, preview output selection or
volume, recording, telemetry, an updater, or runtime plug-in isolation.

## Architecture

```text
Physical microphone
  → Shi-tate (serial VST3 Audio Effects)
  ├→ BlackHole 2ch → Zoom / Slack / Google Meet / Discord
  └→ current macOS main output (exclusive Preview)
```

SwiftUI owns the product UI and local state. A thin Objective-C++ bridge
isolates the C++20/JUCE audio core. The main target is `Shitate`; the distributed
application name is `Shi-tate.app`.

See the [implemented architecture](docs/architecture.md),
[threat model](docs/threat-model.md), and
[canonical detailed design](docs/design.md).

## Requirements

- Apple Silicon Mac
- macOS 14+
- Xcode 26.6 / Swift 6.3
- Nix 2.34+ with flakes, or equivalent CMake 3.31+ tooling
- BlackHole 2ch installed separately from its official project
- User-provided, compatible arm64 or Universal VST3 Audio Effects

See the narrow [VST3 compatibility and scanning contract](docs/plugin-compatibility.md)
before selecting a plug-in.

JUCE is pinned to commit
`f8f8864172464b9adf9eba6101e1f784838d1597`.

## Build and test

Run the supported development workflow from the repository root:

```bash
nix develop
./scripts/bootstrap.sh
./scripts/configure.sh dev
./scripts/build.sh dev
./scripts/test.sh dev
./scripts/check-format.sh
./scripts/check-docs.sh
```

Automated tests cover the build, audio core, scanner isolation, and deterministic
in-tree VST3 fixtures. They do not prove production readiness or compatibility
with a particular third-party plug-in.

## Try the development app

After building, launch the local Debug app:

```bash
open build/dev/Debug/Shi-tate.app
```

The native onboarding flow checks BlackHole 2ch, requests microphone access,
validates a physical input at 48 kHz, scans local VST3, saves the default
session, and explains the call-app selection. An empty plug-in chain is a valid
passthrough setup. Shi-tate never installs BlackHole or a plug-in for you.

Select BlackHole 2ch as the microphone inside the communication app, then start
routing from the Dashboard or menu bar. `Control-Shift-M` toggles master mute
without Accessibility permission. Closing the main window leaves the menu-bar
utility running; use Quit to terminate it.

`Start Preview` temporarily stops BlackHole routing and sends the processed
dual-mono signal to the current physical macOS main output. It is available only
with Automatic routing, 48 kHz, a shared 128/256/512-frame buffer, and a live
stereo output. Use headphones or keep speaker gain low to avoid feedback. An
explicit `Stop Preview` restores BlackHole and resumes it only when routing was
active before Preview, preserving the prior mute state. Output changes, sleep,
permission loss, or errors stop Preview without automatic restart.

See [manual audio QA](docs/manual-qa.md) for the exact verified and unverified
hardware/product-flow evidence.

## Verify a future signed release

There is no signed release yet. When one is published, download its DMG and
adjacent checksum from the same approved release, then verify before opening it:

```bash
version='<exact release version, including any alpha/beta/rc suffix>'
shasum -a 256 -c "Shi-tate_${version}_arm64.dmg.sha256"
gh attestation verify "Shi-tate_${version}_arm64.dmg" \
  --repo hokupod/shitate \
  --signer-workflow hokupod/shitate/.github/workflows/release.yml
spctl --assess --type open --context context:primary-signature --verbose=4 \
  "Shi-tate_${version}_arm64.dmg"
```

After dragging the app to Applications, verify it again with
`spctl --assess --type execute --verbose=4 /Applications/Shi-tate.app`. Do not
bypass Gatekeeper if either assessment fails. The checksum is auxiliary;
attestation verification authenticates the workflow origin. The release also
provides `shitate-${version}-source.tar.zst` and its SHA-256, preserving the
complete prerelease suffix. GitHub's automatic source archive is not the
corresponding source because it omits JUCE contents.

## Privacy and security

Shi-tate is designed without audio storage, telemetry, crash upload, analytics,
remote configuration, plug-in download, or app network access. It does not run
a shell or require administrator privileges. Device failures never trigger an
implicit fallback to another input or output. Main-output Preview is entered
only by an explicit user action and stops if that output changes.

Local asynchronous logs are owner-only, bounded to 5 MiB with three rotated
generations, and redact home paths and device UIDs. `Copy Diagnostics` is an
explicit clipboard action; Shi-tate never sends or automatically persists that
report.

VST3 plug-ins are untrusted native code. Scanning is isolated, but v0.2 runtime
plug-ins execute inside the main app and can crash, hang, access files, or use
the network with your permissions. App Sandbox is disabled and Library
Validation is disabled for the app/scanner to support user VST3 bundles;
Hardened Runtime does not contain those plug-ins. Load only plug-ins you trust.
See [SECURITY.md](SECURITY.md).

## Licensing and third parties

Shi-tate is licensed under
[GNU AGPL-3.0-only](LICENSE). BlackHole and third-party VST3 plug-ins are
separate projects and are not bundled. Users must obtain them from their
official developers and comply with their license terms.

Shi-tate does not include or redistribute third-party VST3 plug-ins. Users are
responsible for complying with the licence terms of every plug-in that they
install and load.

See [third-party notices](THIRD_PARTY_NOTICES.md).

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md), the
[detailed design](docs/design.md), and [SECURITY.md](SECURITY.md). Contributions
must preserve the real-time, privacy, signature, and fail-closed boundaries.
