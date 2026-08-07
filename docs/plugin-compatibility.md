# VST3 compatibility and scanning

Shi-tate v0.1 accepts a deliberately narrow VST3 subset. A successful scan
means that a plug-in passed deterministic discovery checks; it is not a general
compatibility certification.

## Accepted candidates

A candidate must satisfy every requirement:

- macOS `.vst3` bundle with native `arm64` code, either arm64-only or Universal;
- VST3 Audio Effect, not an Instrument or MIDI Effect;
- one stereo main input and one stereo main output, with no active sidechain;
- preparation at 48 kHz with a maximum block size of 512 frames;
- finite output from two silent blocks followed by one stereo impulse block;
- valid Apple or Developer ID signature, or an explicitly approved ad-hoc
  signature fingerprint.

Mono-only, Intel-only, instruments, sidechain-required effects, fixed
multichannel effects, invalid/unsigned code, non-finite output, crashes, and
timeouts are rejected or blocked.

## Search locations

Shi-tate uses these standard locations:

```text
~/Library/Audio/Plug-Ins/VST3
/Library/Audio/Plug-Ins/VST3
```

Additional folders must be selected explicitly and stored as canonical absolute
paths. Shi-tate does not download, install, purchase, redistribute, or update
plug-ins.

## Signature policy

| Signature result | Default behavior |
|---|---|
| Valid Apple / Developer ID | Eligible for scanning |
| Valid ad-hoc | Scan, then block until that exact fingerprint is approved |
| Unsigned or invalid | Reject |
| Changed code-directory hash | Invalidate the cache and require a rescan |
| Intel-only | Reject |

The fingerprint includes the canonical bundle path, VST3 class UID,
code-directory hash, and arm64 architecture. Approval does not transfer to a
different path, class, binary, or architecture.

## Isolation boundary

Discovery never loads VST3 code in the main app. Each bundle is passed through
one signed `ShitatePluginScanner` process using a versioned JSON request file.
The parent uses `posix_spawn`, enforces a 20-second deadline, terminates and
reaps the helper process group, validates the bundle identity both before and
after discovery, validates the result against its preflight signature, and
removes only its owned secure task directory. The app accepts only the signed
helper sealed inside its own `Contents/Helpers` directory.

Request paths, results, and logs are bounded. Task directories use mode `0700`;
files use `0600`. The bundle path is not placed directly on the scanner command
line, and no shell is involved.

The scanner is a crash and hang boundary, not a macOS App Sandbox. VST3 code
still executes with the user's file and network permissions while scanning.
The parent limits inherited environment variables, closes unrelated file
descriptors, and owns a dedicated process group, but users should scan only
plug-ins they trust.

Scanning isolation does not extend to runtime hosting in v0.1. When runtime
hosting is implemented, a selected VST3 will execute inside the main app with
the user's permissions and may crash, hang, access files, or use the network.
Load only plug-ins you trust.

## Deterministic fixture coverage

The automated suite builds test-only Gain, Latency, NaN, Throw, Crash, Hang,
MonoOnly, and Instrument VST3 bundles. It verifies compatible gain processing,
latency reporting, stable incompatibility reasons, crash containment, timeout
termination, and exclusion of fixtures from `Shi-tate.app`.

These synthetic fixtures do not establish compatibility with third-party
products. Shi-tate does not bundle or redistribute them in release artifacts.

## Troubleshooting scan results

| Result | Meaning | Next action |
|---|---|---|
| `unsupportedLayout` | The effect cannot provide exactly stereo in/out without sidechains | Use a compatible stereo effect |
| `instrumentUnsupported` | The class is an Instrument/Synth | Choose an Audio Effect build |
| `nonFiniteOutput` | The deterministic exercise produced NaN or Inf | Contact the plug-in developer |
| `processingException` | Processing threw an exception | Contact the plug-in developer |
| `adHocApprovalRequired` | The exact ad-hoc fingerprint is not approved | Review its source, origin, and fingerprint before explicit approval |
| `signatureRejected` | Signature, hash, path, or architecture failed validation | Reinstall from the trusted developer; do not bypass validation |
| `crashed` | The isolated scanner terminated by signal | Leave the plug-in disabled and report it to its developer |
| `timedOut` | The isolated scanner exceeded 20 seconds | Leave the plug-in disabled and report it to its developer |
| `invalidResult` | The helper result was missing, malformed, or mismatched | Rescan after checking the installation; reinstall if repeated |

Catalog entries are reused only while canonical path, code-directory hash,
bundle modification time, scanner protocol version, and compatible Shi-tate
major/minor version all match.
