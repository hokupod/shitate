#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

repository_root=${1:?repository root is required}
# shellcheck source=scripts/lib/version.sh
source "$repository_root/scripts/lib/version.sh"

test_root=$(mktemp -d "${TMPDIR:-/tmp}/shitate-version-policy.XXXXXX")
trap 'rm -rf "$test_root"' EXIT
version_file="$test_root/VERSION"
bundle_file="$test_root/BUNDLE_VERSION"
printf '1\n' >"$bundle_file"

expected_fields() {
  case $1 in
    0.2.0-dev) printf '%s\t%s\t%s\n' 0.2.0 development FALSE ;;
    0.2.0) printf '%s\t%s\t%s\n' 0.2.0 stable FALSE ;;
    0.2.0-alpha.1) printf '%s\t%s\t%s\n' 0.2.0 alpha TRUE ;;
    0.2.0-beta.2) printf '%s\t%s\t%s\n' 0.2.0 beta TRUE ;;
    0.2.0-rc.0) printf '%s\t%s\t%s\n' 0.2.0 rc TRUE ;;
    *) return 1 ;;
  esac
}

expect_version_acceptance() {
  local value=$1
  local core=
  local channel=
  local prerelease=
  IFS=$'\t' read -r core channel prerelease < <(expected_fields "$value")
  shitate_parse_version "$value"
  [[ "$SHITATE_VERSION_CORE" == "$core" ]]
  [[ "$SHITATE_VERSION_CHANNEL" == "$channel" ]]
  local expected_prerelease=false
  if [[ "$prerelease" == TRUE ]]; then
    expected_prerelease=true
  fi
  [[ "$SHITATE_VERSION_IS_PRERELEASE" == "$expected_prerelease" ]]
  printf '%s\n' "$value" >"$version_file"
  cmake \
    -DSHITATE_VERSION_FILE="$version_file" \
    -DSHITATE_BUNDLE_VERSION_FILE="$bundle_file" \
    -DEXPECTED_VERSION="$value" \
    -DEXPECTED_CORE="$core" \
    -DEXPECTED_CHANNEL="$channel" \
    -DEXPECTED_PRERELEASE="$prerelease" \
    -DEXPECTED_BUNDLE=1 \
    -DVALIDATE_PLISTS=ON \
    -DPLIST_OUTPUT_DIR="$test_root/plists" \
    -P "$repository_root/Tests/Integration/ValidateVersion.cmake" >/dev/null
}

expect_version_rejection() {
  local value=$1
  if shitate_parse_version "$value" >/dev/null 2>&1; then
    printf 'Bash accepted invalid version: %q\n' "$value" >&2
    exit 1
  fi
  printf '%s\n' "$value" >"$version_file"
  if cmake \
    -DSHITATE_VERSION_FILE="$version_file" \
    -DSHITATE_BUNDLE_VERSION_FILE="$bundle_file" \
    -P "$repository_root/Tests/Integration/ValidateVersion.cmake" >/dev/null 2>&1; then
    printf 'CMake accepted invalid version: %q\n' "$value" >&2
    exit 1
  fi
}

for value in \
  0.2.0-dev \
  0.2.0 \
  0.2.0-alpha.1 \
  0.2.0-beta.2 \
  0.2.0-rc.0; do
  expect_version_acceptance "$value"
done

invalid_versions=(
  v0.2.0
  01.2.0
  0.02.0
  0.2.00
  0.2.0-alpha
  0.2.0-alpha.01
  0.2.0-preview.1
  0.2.0+build.1
  ' 0.2.0'
  '0.2.0 '
)
for value in "${invalid_versions[@]}"; do
  expect_version_rejection "$value"
done

for value in 0.2.0 0.2.0-alpha.1 0.2.0-beta.2 0.2.0-rc.0; do
  shitate_require_publishable_version "$value"
done
if shitate_require_publishable_version 0.2.0-dev >/dev/null 2>&1; then
  printf 'development version was publishable\n' >&2
  exit 1
fi

for bundle in 1 2 10; do
  shitate_validate_bundle_version "$bundle"
done
for bundle in 0 01 -1 value ' 1' '1 '; do
  if shitate_validate_bundle_version "$bundle" >/dev/null 2>&1; then
    printf 'accepted invalid bundle version: %q\n' "$bundle" >&2
    exit 1
  fi
  printf '0.2.0-dev\n' >"$version_file"
  printf '%s\n' "$bundle" >"$bundle_file"
  if cmake \
    -DSHITATE_VERSION_FILE="$version_file" \
    -DSHITATE_BUNDLE_VERSION_FILE="$bundle_file" \
    -P "$repository_root/Tests/Integration/ValidateVersion.cmake" >/dev/null 2>&1; then
    printf 'CMake accepted invalid bundle version: %q\n' "$bundle" >&2
    exit 1
  fi
done

printf '0.2.0-dev\n\n' >"$version_file"
printf '1\n' >"$bundle_file"
if shitate_read_version_contract "$test_root" >/dev/null 2>&1; then
  printf 'accepted multiline VERSION file\n' >&2
  exit 1
fi

printf '0.2.0-dev\nignored' >"$version_file"
if shitate_read_version_contract "$test_root" >/dev/null 2>&1; then
  printf 'Bash accepted unterminated second VERSION line\n' >&2
  exit 1
fi
if cmake \
  -DSHITATE_VERSION_FILE="$version_file" \
  -DSHITATE_BUNDLE_VERSION_FILE="$bundle_file" \
  -P "$repository_root/Tests/Integration/ValidateVersion.cmake" >/dev/null 2>&1; then
  printf 'CMake accepted unterminated second VERSION line\n' >&2
  exit 1
fi

printf 'version policy matrix passed\n'
