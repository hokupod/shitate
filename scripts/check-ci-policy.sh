#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

set -euo pipefail

default_repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repository_root=${1:-$default_repository_root}
workflow_directory="$repository_root/.github/workflows"

if [[ ! -d "$workflow_directory" ]]; then
  printf 'workflow directory is missing: %s\n' "$workflow_directory" >&2
  exit 1
fi
if ! command -v yq >/dev/null 2>&1; then
  printf 'yq is missing; enter the pinned environment with nix develop.\n' >&2
  exit 1
fi
if ! command -v actionlint >/dev/null 2>&1; then
  printf 'actionlint is missing; enter the pinned environment with nix develop.\n' >&2
  exit 1
fi
uses_lines=$(grep -ERh '^[[:space:]]*uses:' "$workflow_directory")
if [[ -z "$uses_lines" ]]; then
  printf 'no GitHub Action uses entries found\n' >&2
  exit 1
fi

while IFS= read -r line; do
  if [[ ! "$line" =~ @[0-9a-f]{40}([[:space:]]*#.*)?$ ]]; then
    printf 'GitHub Action is not pinned to a 40-character SHA: %s\n' "$line" >&2
    exit 1
  fi
done <<<"$uses_lines"

if grep -ERn 'pull_request_target|permissions:[[:space:]]*write-all|@[vV][0-9]+([[:space:]]|$)' \
  "$repository_root/.github"; then
  printf 'prohibited GitHub Actions policy found\n' >&2
  exit 1
fi

shopt -s nullglob
workflow_files=("$workflow_directory"/*.yml "$workflow_directory"/*.yaml)
shopt -u nullglob
if [[ ${#workflow_files[@]} -eq 0 ]]; then
  printf 'no GitHub Actions workflow files found\n' >&2
  exit 1
fi
actionlint "${workflow_files[@]}"

for workflow in "${workflow_files[@]}"; do
  if ! yq -o=json '.permissions' "$workflow" |
    jq -e '. == {"contents":"read"}' >/dev/null; then
    printf 'workflow-level permissions must be exactly contents: read: %s\n' "$workflow" >&2
    exit 1
  fi

  while IFS=$'\t' read -r job permission value; do
    [[ "$value" == write ]] || continue
    workflow_name=$(basename "$workflow")
    if [[ "$workflow_name:$job:$permission" == "codeql.yml:analyze:security-events" ||
      "$workflow_name:$job:$permission" == "release.yml:release:attestations" ||
      "$workflow_name:$job:$permission" == "release.yml:release:contents" ||
      "$workflow_name:$job:$permission" == "release.yml:release:id-token" ]]; then
      continue
    fi
    printf 'unexpected job write permission: %s:%s:%s\n' \
      "$workflow_name" "$job" "$permission" >&2
    exit 1
  done < <(yq -o=json '.jobs' "$workflow" | jq -r '
    to_entries[] as $job |
    (($job.value.permissions // {}) | to_entries[]) |
    [$job.key, .key, .value] | @tsv
  ')

  secret_jobs=$(yq -o=json '.jobs' "$workflow" | jq -r '
    to_entries[] |
    select(.value | tostring | contains("${{ secrets.")) |
    .key
  ')
  workflow_name=$(basename "$workflow")
  while IFS= read -r secret_job; do
    [[ -z "$secret_job" ]] && continue
    if [[ "$workflow_name:$secret_job" == release.yml:release ||
      "$workflow_name:$secret_job" == release-preflight.yml:credential ]]; then
      continue
    fi
    printf 'secrets are only allowed in protected release jobs: %s:%s\n' \
      "$workflow" "$secret_job" >&2
    exit 1
  done <<<"$secret_jobs"
done

release_workflow="$workflow_directory/release.yml"
if [[ ! -f "$release_workflow" ]]; then
  printf 'release workflow is missing\n' >&2
  exit 1
fi
if ! yq -o=json '.' "$release_workflow" | jq -e '
  (.on | has("push")) and
  (.on | has("workflow_dispatch")) and
  (.on.push.tags == ["v*.*.*"]) and
  .jobs.release.environment == "release"
' >/dev/null; then
  printf 'release workflow must use tag/manual triggers and protected release environment\n' >&2
  exit 1
fi
if ! yq -o=json '.jobs.release.needs' "$release_workflow" |
  jq -e 'type == "array" and index("gate") != null and index("test") != null' \
    >/dev/null; then
  printf 'release job must depend on gate and test jobs\n' >&2
  exit 1
fi
for required_text in \
  'scripts/validate-release-tag.sh' \
  'shitate_require_publishable_version' \
  'shitate_read_version_contract' \
  'SHITATE_RELEASE_TAGGER_EMAIL' \
  'SHITATE_IMMUTABLE_RELEASE_TAGS' \
  "[[ \"\$SHITATE_IMMUTABLE_RELEASE_TAGS\" == YES ]]" \
  'EXPECTED_TAG_OBJECT' \
  "\"\$tag_ref\" \"\$tag_object\" \"\$EXPECTED_TAG_OBJECT\"" \
  'gh release view' \
  '--verify-tag' \
  "gh \"\${arguments[@]}\"" \
  'scripts/sign-release.sh' \
  'scripts/notarize.sh' \
  'scripts/verify-source-archive.sh'; do
  if ! grep -Fq -- "$required_text" "$release_workflow"; then
    printf 'release workflow gate is missing: %s\n' "$required_text" >&2
    exit 1
  fi
done

credential_library="$repository_root/scripts/lib/apple-credentials.sh"
if [[ ! -f "$credential_library" ]] ||
  ! grep -Eq '^[[:space:]]*export SHITATE_NOTARY_KEY_PATH=' \
    "$credential_library"; then
  printf 'notary key path must be exported for the notarization subprocess\n' >&2
  exit 1
fi

preflight_workflow="$workflow_directory/release-preflight.yml"
if [[ ! -f "$preflight_workflow" ]] ||
  ! yq -o=json '.' "$preflight_workflow" | jq -e '
    (.on | keys == ["workflow_dispatch"]) and
    (.permissions == {"contents":"read"}) and
    (.jobs.gate.environment == null) and
    (.jobs.gate | tostring | contains("${{ secrets.") | not) and
    (.jobs.credential.needs == "gate") and
    (.jobs.credential.environment == "release") and
    ([.jobs.credential.steps[].name] as $names |
      ($names | index("Revalidate identity before materializing credentials")) as $revalidate |
      ($names | index("Validate Apple credential usability without release mutation")) as $validate |
      ($revalidate != null) and ($validate != null) and ($revalidate < $validate))
  ' >/dev/null; then
  printf 'release credential preflight structure is invalid\n' >&2
  exit 1
fi
for required_text in \
  "[[ \"\$GITHUB_REF\" == refs/heads/main ]]" \
  "[[ \"\$GITHUB_SHA\" == \"\$EXPECTED_SHA\" ]]" \
  'scripts/lib/apple-credentials.sh'; do
  if ! grep -Fq -- "$required_text" "$preflight_workflow"; then
    printf 'release credential preflight gate is missing: %s\n' "$required_text" >&2
    exit 1
  fi
done
if grep -En -- 'gh[[:space:]]+release|upload-artifact|attest-build-provenance|contents:[[:space:]]*write' \
  "$preflight_workflow"; then
  printf 'release credential preflight may mutate release state\n' >&2
  exit 1
fi

attestation_subjects=$(yq -o=json '.jobs.release.steps[] |
  select(.name == "Attest release subjects") | .with."subject-path"' \
  "$release_workflow" | jq -r '.')
draft_release_step=$(yq -o=json '.jobs.release.steps[] |
  select(.name == "Create draft release exactly once") | .run' \
  "$release_workflow" | jq -r '.')
asset_variables=(
  SHITATE_DMG
  SHITATE_DMG_SHA256
  SHITATE_SOURCE_ARCHIVE
  SHITATE_SOURCE_SHA256
  SHITATE_PROVENANCE
  SHITATE_NOTICES
)
if [[ $(grep -Ec '^\$\{\{ env\.SHITATE_[A-Z0-9_]+ \}\}$' \
  <<<"$attestation_subjects") -ne ${#asset_variables[@]} ||
  $(grep -Ec "^[[:space:]]*\"\\\$SHITATE_[A-Z0-9_]+\"" \
    <<<"$draft_release_step") -ne ${#asset_variables[@]} ]]; then
  printf 'release upload and attestation subject counts must both be six\n' >&2
  exit 1
fi
for variable in "${asset_variables[@]}"; do
  if ! grep -Fxq "\${{ env.$variable }}" <<<"$attestation_subjects" ||
    ! grep -Fq "\$$variable" <<<"$draft_release_step"; then
    printf 'release asset is not both uploaded and attested: %s\n' "$variable" >&2
    exit 1
  fi
done
if grep -En -- '--clobber|--target|gh[[:space:]]+release[[:space:]]+upload' \
  "$release_workflow"; then
  printf 'release workflow may overwrite or incrementally upload assets\n' >&2
  exit 1
fi

printf 'GitHub Actions policy passed\n'
