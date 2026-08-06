# Contributing to Shi-tate

Shi-tate is pre-alpha. Read [the detailed design](docs/design.md),
[SECURITY.md](SECURITY.md), and all relevant implementation plans before making
changes.

## Development environment

Use the repository Nix flake for missing command-line tooling and Xcode 26.6 as
the Apple compiler/SDK source.

```bash
nix develop
./scripts/bootstrap.sh
./scripts/configure.sh dev
./scripts/build.sh dev
./scripts/test.sh dev
./scripts/check-format.sh
./scripts/check-docs.sh
```

The build scripts never install system packages. Until the build foundation is
implemented, only `./scripts/check-docs.sh` is available.

## Change requirements

- Use Conventional Commits.
- Add `SPDX-License-Identifier: AGPL-3.0-only` and the project copyright line to
  every original source file.
- Keep CMake as the only project source of truth; do not commit generated Xcode
  projects or build output.
- Update English, Japanese, and Simplified Chinese README facts together.
- Add tests with every behavior or boundary change.
- Separate automated, hardware, signed-release, and remote-CI evidence.
- Do not claim a compatibility, latency, xrun, routing, or release result that
  was not directly verified.

## Real-time rules

The audio callback must not allocate/free, resize containers, wait on a lock,
perform file/JSON/log/network I/O, call Swift/Foundation/UI, create/destroy or
serialize a plug-in, or reconfigure a device. Changes to callback code require
allocation, lock, non-finite, and frame-boundary tests.

## Privacy and trust rules

- Never add audio recording, sample logging, telemetry, crash upload, analytics,
  remote configuration, plug-in download, or app networking.
- Never execute a shell or combine external input into a command string.
- Never silently fall back to another input, speaker, or output.
- Never load a plug-in without fresh canonical-path, signature, cdhash,
  architecture, class, and layout validation.
- Do not include BlackHole or third-party/test VST3 in release artifacts.
- Logs and test fixtures must not contain raw home paths, device UIDs, plug-in
  state, credentials, or audio-derived content.

## Formatting and review

Use the repository `.swift-format` and `.clang-format`. Keep SwiftUI native to
macOS and follow Apple's Human Interface Guidelines, including standard menus,
settings placement, keyboard access, semantic labels, system colors/type, and
accessible control sizing.

Security-sensitive changes should be reviewed specifically for path/cdhash
TOCTOU, process reaping, file modes, parser bounds, fail-closed output,
entitlements, diagnostics redaction, and supply-chain pins.
