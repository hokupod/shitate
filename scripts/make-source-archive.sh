#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/version.sh
source "$repository_root/scripts/lib/version.sh"
shitate_read_version_contract "$repository_root"
tar_bin=$(type -P tar || true)
if [[ -z "$tar_bin" ]] ||
  ! "$tar_bin" --version 2>/dev/null | grep -Fq 'tar (GNU tar)'; then
  printf 'GNU tar is required; run this script through nix develop\n' >&2
  exit 127
fi
if [[ $# -ne 1 ]]; then
  printf 'usage: %s <version-from-VERSION>\n' "$0" >&2
  exit 2
fi
version=$1
if [[ "$version" != "$SHITATE_VERSION" ]]; then
  printf 'source version must exactly match VERSION: expected %s; got %s\n' \
    "$SHITATE_VERSION" "$version" >&2
  exit 1
fi
if [[ -n $(git -C "$repository_root" status --short --untracked-files=no) &&
  ${SHITATE_ALLOW_DIRTY_SOURCE:-} != YES ]]; then
  printf 'source archive requires a clean tracked worktree\n' >&2
  exit 1
fi

expected_juce_sha=f8f8864172464b9adf9eba6101e1f784838d1597
actual_juce_sha=$(git -C "$repository_root/external/JUCE" rev-parse HEAD)
if [[ "$actual_juce_sha" != "$expected_juce_sha" ]]; then
  printf 'JUCE pin mismatch\n' >&2
  exit 1
fi

artifact_directory=${SHITATE_ARTIFACT_DIR:-"$repository_root/build/artifacts"}
archive_name="shitate-$version-source.tar.zst"
archive="$artifact_directory/$archive_name"
hash_file="$archive.sha256"
for destination in "$archive" "$hash_file"; do
  if [[ -e "$destination" ]]; then
    printf 'refusing to overwrite source artifact: %s\n' "$destination" >&2
    exit 1
  fi
done

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/shitate-source.XXXXXX")
trap 'chmod -R u+w "$temporary_directory" 2>/dev/null || true; rm -rf "$temporary_directory"' EXIT
staging="$temporary_directory/shitate-$version"
mkdir -m 700 "$staging"

git -C "$repository_root" ls-files -z |
  grep -zv '^external/JUCE$' |
  "$tar_bin" -C "$repository_root" --null -T - -cf - |
  "$tar_bin" -C "$staging" -xf -
mkdir -p "$staging/external/JUCE"
git -C "$repository_root/external/JUCE" ls-files -z |
  "$tar_bin" -C "$repository_root/external/JUCE" --null -T - -cf - |
  "$tar_bin" -C "$staging/external/JUCE" -xf -

(
  cd "$staging"
  find external/JUCE -type f -print0 | sort -z |
    xargs -0 shasum -a 256 >JUCE-SOURCE.sha256
)
commit=$(git -C "$repository_root" rev-parse HEAD)
jq -n \
  --arg version "$version" \
  --arg version_core "$SHITATE_VERSION_CORE" \
  --arg bundle_version "$SHITATE_BUNDLE_VERSION" \
  --arg commit "$commit" \
  --arg juce "$actual_juce_sha" \
  '{schemaVersion:2,version:$version,versionCore:$version_core,bundleVersion:$bundle_version,commit:$commit,juceCommit:$juce}' \
  >"$staging/SOURCE-METADATA.json"

source_date_epoch=${SOURCE_DATE_EPOCH:-$(git -C "$repository_root" show -s --format=%ct HEAD)}
mkdir -p "$artifact_directory"
"$tar_bin" -C "$temporary_directory" \
  --sort=name \
  --mtime="@$source_date_epoch" \
  --owner=0 --group=0 --numeric-owner \
  --pax-option=delete=atime,delete=ctime \
  -cf - "shitate-$version" |
  zstd -19 --threads=1 -q -o "$archive"
(
  cd "$artifact_directory"
  shasum -a 256 "$archive_name" >"$archive_name.sha256"
)

printf 'created recursive corresponding-source archive: %s\n' "$archive"
