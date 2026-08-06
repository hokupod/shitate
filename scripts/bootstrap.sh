#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
expected_juce_sha=f8f8864172464b9adf9eba6101e1f784838d1597

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

git -C "$repository_root" submodule update --init --recursive external/JUCE
actual_juce_sha=$(git -C "$repository_root/external/JUCE" rev-parse HEAD)
if [[ "$actual_juce_sha" != "$expected_juce_sha" ]]; then
  printf 'JUCE must be pinned to %s; found %s.\n' \
    "$expected_juce_sha" "$actual_juce_sha" >&2
  exit 1
fi

mkdir -p "$repository_root/build"
printf 'Verified arm64, Xcode %s, Swift %s, CMake %s, JUCE %s.\n' \
  "$xcode_version" "$swift_version" "$cmake_version" "$actual_juce_sha"
