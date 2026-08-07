#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=scripts/lib/security-policy.sh
source "$repository_root/scripts/lib/security-policy.sh"

shitate_verify_entitlement_files \
  "$repository_root/resources/Shitate.entitlements" \
  "$repository_root/resources/Scanner.entitlements"

if grep -ERn \
  'URLSession|NWConnection|CFHTTP|WKWebView|curl_easy_|JUCE_USE_CURL[[:space:]]+1' \
  "$repository_root/Sources"; then
  printf 'app or helper source contains a prohibited network client\n' >&2
  exit 1
fi

grep -Fq 'JUCE_USE_CURL=0' "$repository_root/cmake/ShitateCompiler.cmake"
grep -Fq 'JUCE_WEB_BROWSER=0' "$repository_root/cmake/ShitateCompiler.cmake"
grep -Fq 'EXCLUDE REGEX "WebKit"' "$repository_root/CMakeLists.txt"
grep -Fq 'LINKER:-dead_strip' "$repository_root/CMakeLists.txt"
grep -Fq 'XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME "YES"' "$repository_root/CMakeLists.txt"

printf 'security source policy passed\n'
