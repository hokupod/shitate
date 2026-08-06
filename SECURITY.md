# Security Policy

## Supported versions

Shi-tate is pre-alpha. No released version is currently supported. Security
fixes target the current development branch until a release policy is published.

## Reporting a vulnerability

Please report a suspected vulnerability privately through GitHub's private
vulnerability reporting feature for `hokupod/shitate`. If that feature is not
available, contact the repository owner through a private channel listed on the
owner's GitHub profile.

Do not include audio, plug-in state, credentials, raw CoreAudio UIDs, private
home-directory paths, or another person's data. Provide the smallest safe
reproduction, affected commit/version, expected boundary, and observed result.

No response or remediation SLA is promised while the project is pre-alpha.

## Security boundary

Shi-tate treats third-party VST3 bundles as untrusted native code. Scan-time
loading is isolated in `ShitatePluginScanner`, but v0.1 runtime plug-ins execute
inside the main app after signature, architecture, layout, and fingerprint
validation. A valid signature identifies code; it does not establish safe
behavior. A plug-in can still crash, hang, access files, or use the network with
the user's permissions.

The host itself is designed to:

- require no administrator privilege or shell execution;
- make no network request, upload, or automatic download;
- store no audio;
- reject unsigned or invalid VST3 by default;
- require explicit approval for each ad-hoc fingerprint;
- revalidate a canonical path and cdhash immediately before runtime load;
- fail closed to silence without choosing another input or output;
- enter safe mode after a dirty shutdown before loading VST3; and
- redact local diagnostics.

BlackHole is an external project and is not bundled. Its installation and
security lifecycle are outside the Shi-tate trust boundary.

## Disclosure expectations

Please avoid public disclosure until the maintainer can assess impact and a
coordinated disclosure date can be discussed. Do not test against systems,
devices, plug-ins, or data you do not own or have permission to use.
