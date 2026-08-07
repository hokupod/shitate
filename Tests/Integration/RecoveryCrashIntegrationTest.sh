#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

if [[ $# -ne 3 ]]; then
  printf 'usage: %s <termination-observer> <state-harness> <runtime-host>\n' "$0" >&2
  exit 2
fi

termination_observer=$1
state_harness=$2
runtime_host=$3
test_root=$(mktemp -d "${TMPDIR:-/tmp}/shitate-recovery-crash.XXXXXX")
trap 'chmod -R u+w "$test_root" 2>/dev/null || true; rm -rf "$test_root"' EXIT

support_directory="$test_root/support"
negative_support_directory="$test_root/negative-support"
runtime_directory="$test_root/runtime"
negative_runtime_directory="$test_root/negative-runtime"
exit134_runtime_directory="$test_root/exit134-runtime"
mkdir -m 700 "$runtime_directory"
mkdir -m 700 "$negative_runtime_directory"
mkdir -m 700 "$exit134_runtime_directory"
fingerprint=$(printf 'c%.0s' {1..64})

has_crash_plugin_sentinel() {
  local sentinel=$1
  [[ -f "$sentinel" &&
    $(<"$sentinel") == 'CrashPlugin processBlock' &&
    $(/usr/bin/stat -f '%Lp' "$sentinel") == 600 ]]
}

has_crash_plugin_evidence() {
  local observation=$1
  local sentinel=$2
  [[ "$observation" == 'termination=signal:6' ]] &&
    has_crash_plugin_sentinel "$sentinel"
}

set +e
TMPDIR="$negative_runtime_directory" "$runtime_host" --crash >/dev/null 2>&1
negative_child_status=$?
"$state_harness" assert-safe-mode "$negative_support_directory" >/dev/null 2>&1
negative_recovery_status=$?
set -e
if [[ $negative_child_status -eq 0 || $negative_recovery_status -eq 0 ]]; then
  printf 'a crash before the write-before-load marker produced false recovery evidence\n' >&2
  exit 1
fi

unrelated_support_directory="$test_root/unrelated-support"
unrelated_sentinel="$test_root/unrelated-crash-sentinel"
set +e
unrelated_observation=$(SHITATE_TEST_CRASH_SENTINEL="$unrelated_sentinel" \
  "$termination_observer" "$state_harness" mark-and-crash \
  "$unrelated_support_directory" /usr/bin/false "$fingerprint" 2>/dev/null)
unrelated_observer_status=$?
set -e
if [[ $unrelated_observer_status -ne 0 ]]; then
  printf 'termination observer failed for pre-plugin failure\n' >&2
  exit 1
fi
if has_crash_plugin_evidence "$unrelated_observation" "$unrelated_sentinel"; then
  printf 'failure before CrashPlugin entry produced valid crash evidence\n' >&2
  exit 1
fi

exit134_support_directory="$test_root/exit134-support"
exit134_sentinel="$test_root/exit134-crash-sentinel"
set +e
exit134_observation=$(SHITATE_TEST_CRASH_SENTINEL="$exit134_sentinel" \
  SHITATE_TEST_CRASH_TERMINATION=Exit134 \
  TMPDIR="$exit134_runtime_directory" \
  "$termination_observer" "$state_harness" mark-and-crash \
  "$exit134_support_directory" "$runtime_host" "$fingerprint" 2>/dev/null)
exit134_observer_status=$?
set -e
if [[ $exit134_observer_status -ne 0 || "$exit134_observation" != 'termination=exit:134' ]]; then
  printf 'exit(134) negative control returned unexpected termination evidence\n' >&2
  exit 1
fi
if ! has_crash_plugin_sentinel "$exit134_sentinel"; then
  printf 'exit(134) negative control did not reach CrashPlugin processBlock\n' >&2
  exit 1
fi
if has_crash_plugin_evidence "$exit134_observation" "$exit134_sentinel"; then
  printf 'exit(134) was incorrectly accepted as SIGABRT evidence\n' >&2
  exit 1
fi

crash_sentinel="$test_root/crash-plugin-sentinel"
set +e
child_observation=$(SHITATE_TEST_CRASH_SENTINEL="$crash_sentinel" \
  TMPDIR="$runtime_directory" "$termination_observer" \
  "$state_harness" mark-and-crash "$support_directory" \
  "$runtime_host" "$fingerprint" 2>/dev/null)
child_observer_status=$?
set -e
if [[ $child_observer_status -ne 0 ]] ||
  ! has_crash_plugin_evidence "$child_observation" "$crash_sentinel"; then
  printf 'CrashPlugin child did not provide signal and processBlock evidence\n' >&2
  exit 1
fi

result=$("$state_harness" assert-safe-mode "$support_directory")
if [[ "$result" != "safe-mode-before-plugin-factory" ]]; then
  printf 'unexpected recovery proof: %s\n' "$result" >&2
  exit 1
fi

printf 'disposable runtime crash entered safe mode before any fresh-process plug-in factory call\n'
