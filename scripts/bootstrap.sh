#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
expected_juce_sha=f8f8864172464b9adf9eba6101e1f784838d1597
# shellcheck source=scripts/lib/version.sh
source "$repository_root/scripts/lib/version.sh"
shitate_read_version_contract "$repository_root"

if [[ -z ${DEVELOPER_DIR:-} ]]; then
  xcode_candidates=(
    /Applications/Xcode.app/Contents/Developer
    /Applications/Xcode_26.6.app/Contents/Developer
  )
  for candidate in "${xcode_candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      export DEVELOPER_DIR="$candidate"
      break
    fi
  done
fi

if [[ $(uname -m) != arm64 ]]; then
  printf 'Shi-tate requires an arm64 macOS host.\n' >&2
  exit 1
fi

if [[ ! -d ${DEVELOPER_DIR:-} ]]; then
  printf 'Xcode 26.6 is required under /Applications.\n' >&2
  exit 1
fi

xcode_version=$(xcodebuild -version | sed -n '1s/^Xcode //p')
if [[ "$xcode_version" != "26.6" ]]; then
  printf 'Xcode 26.6 is required; found %s.\n' "${xcode_version:-unknown}" >&2
  exit 1
fi

swift_version=$(xcrun swift --version | sed -n '1s/.*Swift version \([0-9][0-9.]*\).*/\1/p')
if [[ ! "$swift_version" =~ ^6\.3(\.|$) ]]; then
  printf 'Apple Swift 6.3.x is required; found %s.\n' "${swift_version:-unknown}" >&2
  exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
  printf 'CMake 3.31+ is missing; enter the pinned environment with nix develop.\n' >&2
  exit 1
fi

cmake_version=$(cmake --version | sed -n '1s/^cmake version //p')
if ! perl -Mversion -e 'exit(version->parse($ARGV[0]) < version->parse($ARGV[1]))' \
  "$cmake_version" 3.31; then
  printf 'CMake 3.31+ is required; found %s.\n' "$cmake_version" >&2
  exit 1
fi

checkout_root=$(git -C "$repository_root" rev-parse --show-toplevel 2>/dev/null || true)
juce_checkout_root=$(git -C "$repository_root/external/JUCE" rev-parse --show-toplevel 2>/dev/null || true)
if [[ "$checkout_root" == "$repository_root" &&
  "$juce_checkout_root" == "$repository_root/external/JUCE" ]]; then
  git -C "$repository_root" submodule update --init --recursive external/JUCE
  actual_juce_sha=$(git -C "$repository_root/external/JUCE" rev-parse HEAD)
else
  source_metadata="$repository_root/SOURCE-METADATA.json"
  juce_manifest="$repository_root/JUCE-SOURCE.sha256"
  if [[ ! -f "$source_metadata" || ! -f "$juce_manifest" ]]; then
    printf 'Git checkout or verified corresponding-source metadata is required.\n' >&2
    exit 1
  fi
  if ! jq -e '
    .schemaVersion == 2 and
    (.version | type == "string") and
    (.versionCore | type == "string") and
    (.bundleVersion | type == "string") and
    (.commit | test("^[0-9a-f]{40}$")) and
    (.juceCommit | test("^[0-9a-f]{40}$"))
  ' "$source_metadata" >/dev/null ||
    ! jq -e \
      --arg version "$SHITATE_VERSION" \
      --arg core "$SHITATE_VERSION_CORE" \
      --arg bundle "$SHITATE_BUNDLE_VERSION" \
      '.version == $version and .versionCore == $core and .bundleVersion == $bundle' \
      "$source_metadata" >/dev/null; then
    printf 'Corresponding-source metadata is invalid.\n' >&2
    exit 1
  fi
  actual_juce_sha=$(jq -r '.juceCommit' "$source_metadata")
  manifest_count=$(wc -l <"$juce_manifest" | tr -d ' ')
  source_count=$(find "$repository_root/external/JUCE" -type f | wc -l | tr -d ' ')
  if [[ "$manifest_count" != "$source_count" ]]; then
    printf 'Corresponding-source JUCE file count does not match its manifest.\n' >&2
    exit 1
  fi
  (
    cd "$repository_root"
    shasum -a 256 -c JUCE-SOURCE.sha256 >/dev/null
  )
fi
if [[ "$actual_juce_sha" != "$expected_juce_sha" ]]; then
  printf 'JUCE must be pinned to %s; found %s.\n' \
    "$expected_juce_sha" "$actual_juce_sha" >&2
  exit 1
fi

mkdir -p "$repository_root/build"
printf 'Verified arm64, Xcode %s, Swift %s, CMake %s, JUCE %s.\n' \
  "$xcode_version" "$swift_version" "$cmake_version" "$actual_juce_sha"
