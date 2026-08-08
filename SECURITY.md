# Security Policy

## Supported versions

Shi-tate is pre-alpha. No released version is currently supported. Security
fixes target the current development branch until a release policy is published.

Development versions use `X.Y.Z-dev` and are never tagged or published.
Publishable identities are exactly `X.Y.Z`, `X.Y.Z-alpha.N`, `X.Y.Z-beta.N`, or
`X.Y.Z-rc.N`; the complete version, including its prerelease suffix, must match
the signed tag, app metadata, artifact names, source metadata, and attestations.

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
loading is isolated in `ShitatePluginScanner`, but v0.2 runtime plug-ins execute
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

Release publication additionally requires an active tag ruleset that prevents
updates and deletion for `v*.*.*`, the protected `release` environment,
`SHITATE_IMMUTABLE_RELEASE_TAGS=YES`, and a configured
`SHITATE_RELEASE_TAGGER_EMAIL`. The workflow accepts only a GitHub-verified
annotated tag whose `valid` signature covers that tagger identity, records its
tag-object SHA, and revalidates the same live object immediately before creating
the draft release. Before an immutable tag is created, a protected preflight at
the exact reviewed main SHA must validate certificate import, Developer ID
codesigning, certificate lifetime, and notary authentication without creating a
tag, release, asset, or attestation. Every published asset is attested, and the
release becomes immutable only after downloaded draft bytes and evidence have
been independently revalidated.

App Sandbox is disabled and Library Validation is disabled only for the app and
scanner because user VST3 bundles are loaded as native code. Hardened Runtime
and release entitlement checks remain enabled, but these controls do not
contain an in-process plug-in. See the detailed [v0.2 threat model](docs/threat-model.md)
and [architecture](docs/architecture.md).

## Disclosure expectations

Please avoid public disclosure until the maintainer can assess impact and a
coordinated disclosure date can be discussed. Do not test against systems,
devices, plug-ins, or data you do not own or have permission to use.
