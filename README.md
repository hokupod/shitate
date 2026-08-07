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
> **Pre-alpha — not yet production-ready.** Version `0.1.0-dev` is under
> implementation. There is no installable release or broad third-party VST3
> compatibility evidence.

Do not rely on Shi-tate for a call, recording, or production workflow until the
relevant automated and manual evidence is published.

## v0.1 scope

- Apple Silicon (`arm64`) and macOS 14 or later.
- Select one physical microphone channel and convert it to stereo dual mono.
- Process up to eight serial, user-provided arm64 VST3 Audio Effects.
- Route only to externally installed BlackHole 2ch at 48 kHz.
- Isolate one-bundle-at-a-time VST3 scanning in a helper process.
- Fail closed to silence when a saved device, format, or plug-in is invalid.
- Start in safe mode after a dirty shutdown before loading any VST3.
- Keep app settings and plug-in state locally; never store audio.

## Non-goals

v0.1 does not include a virtual driver, BlackHole or VST3 redistribution,
Intel/Windows/Linux support, AU/CLAP/VST2, resampling, sidechains, instruments,
monitoring, recording, telemetry, an updater, or runtime plug-in isolation.

## Architecture

```text
Physical microphone
  → Shi-tate (serial VST3 Audio Effects)
  → BlackHole 2ch
  → Zoom / Slack / Google Meet / Discord
```

SwiftUI owns the product UI and local state. A thin Objective-C++ bridge
isolates the C++20/JUCE audio core. The main target is `Shitate`; the distributed
application name is `Shi-tate.app`.

See the [canonical detailed design](docs/design.md).

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

## Privacy and security

Shi-tate is designed without audio storage, telemetry, crash upload, analytics,
remote configuration, plug-in download, or app network access. It does not run
a shell or require administrator privileges. Device failures never trigger an
implicit fallback to another input or speaker.

VST3 plug-ins are untrusted native code. Scanning is isolated, but v0.1 runtime
plug-ins execute inside the main app and can crash, hang, access files, or use
the network with your permissions. Load only plug-ins you trust. See
[SECURITY.md](SECURITY.md).

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
