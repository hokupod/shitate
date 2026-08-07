#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

if [[ $# -ne 1 ]]; then
  printf 'usage: %s <source.tar.zst>\n' "$0" >&2
  exit 2
fi
archive=$1
if [[ -f "$archive.sha256" ]]; then
  (
    cd "$(dirname "$archive")"
    shasum -a 256 -c "$(basename "$archive.sha256")"
  )
fi
test_root=$(mktemp -d "${TMPDIR:-/tmp}/shitate-source-verify.XXXXXX")
trap 'chmod -R u+w "$test_root" 2>/dev/null || true; rm -rf "$test_root"' EXIT
zstd -dc "$archive" | gtar -C "$test_root" -xf -
source_root=$(find "$test_root" -mindepth 1 -maxdepth 1 -type d -print -quit)
root_count=$(find "$test_root" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
if [[ -z "$source_root" || "$root_count" != 1 ||
  ! -f "$source_root/SOURCE-METADATA.json" || -e "$source_root/.git" ]]; then
  printf 'source metadata is missing\n' >&2
  exit 1
fi
git -C "$test_root" init -q
git -C "$test_root" config user.name 'Shi-tate Source Test'
git -C "$test_root" config user.email 'source-test@invalid.example'
printf 'unrelated parent checkout\n' >"$test_root/PARENT-COMMIT"
git -C "$test_root" add PARENT-COMMIT
git -C "$test_root" commit -q -m 'test: create unrelated parent checkout'
parent_commit=$(git -C "$test_root" rev-parse HEAD)
(
  cd "$source_root"
  shasum -a 256 -c JUCE-SOURCE.sha256 >/dev/null
  ./scripts/bootstrap.sh
  ./scripts/configure.sh dev
  ./scripts/build.sh dev
  ./scripts/test.sh dev
  ./scripts/check-docs.sh
  expected_commit=$(jq -r '.commit' SOURCE-METADATA.json)
  expected_version=$(jq -r '.version' SOURCE-METADATA.json)
  [[ "$expected_commit" != "$parent_commit" ]]
  info_plist=build/dev/Debug/Shi-tate.app/Contents/Info.plist
  [[ $(plutil -extract ShitateCommit raw -o - "$info_plist") == "$expected_commit" ]]
  [[ $(plutil -extract CFBundleShortVersionString raw -o - "$info_plist") == \
    "$expected_version" ]]
)

printf 'fresh extracted corresponding source built and tested without dependency download\n'
