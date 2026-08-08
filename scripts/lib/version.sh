#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

shitate_version_error() {
  printf 'version contract error: %s\n' "$1" >&2
  return 1
}

shitate_read_single_line_file() {
  local path=$1
  local label=$2
  local line=
  local lines=()

  if [[ ! -f "$path" ]]; then
    shitate_version_error "$label file does not exist: $path"
    return 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    lines[${#lines[@]}]=$line
  done <"$path"
  if [[ ${#lines[@]} -ne 1 || -z ${lines[0]} ]]; then
    shitate_version_error "$label must contain exactly one line"
    return 1
  fi

  SHITATE_READ_VALUE=${lines[0]}
}

shitate_parse_version() {
  local value=${1-}
  local number='(0|[1-9][0-9]*)'
  local pattern="^(${number}\\.${number}\\.${number})(-(dev|(alpha|beta|rc)\\.${number}))?$"

  if [[ ! "$value" =~ $pattern ]]; then
    shitate_version_error \
      "VERSION must be X.Y.Z-dev, X.Y.Z, or X.Y.Z-(alpha|beta|rc).N without leading zeroes; got '$value'"
    return 1
  fi

  SHITATE_VERSION=$value
  # Public output for scripts sourcing this library.
  # shellcheck disable=SC2034
  SHITATE_VERSION_CORE=${BASH_REMATCH[1]}
  SHITATE_VERSION_IS_PRERELEASE=false
  case ${BASH_REMATCH[6]-} in
    "") SHITATE_VERSION_CHANNEL=stable ;;
    dev) SHITATE_VERSION_CHANNEL=development ;;
    *)
      SHITATE_VERSION_CHANNEL=${BASH_REMATCH[7]}
      # Public output for scripts sourcing this library.
      # shellcheck disable=SC2034
      SHITATE_VERSION_IS_PRERELEASE=true
      ;;
  esac
}

shitate_require_publishable_version() {
  shitate_parse_version "${1-}" || return 1
  if [[ "$SHITATE_VERSION_CHANNEL" == development ]]; then
    shitate_version_error "development VERSION is not publishable: '$SHITATE_VERSION'"
    return 1
  fi
}

shitate_validate_bundle_version() {
  local value=${1-}
  if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
    shitate_version_error \
      "BUNDLE_VERSION must be a positive integer without leading zeroes; got '$value'"
    return 1
  fi
  # Public output for scripts sourcing this library.
  # shellcheck disable=SC2034
  SHITATE_BUNDLE_VERSION=$value
}

shitate_read_version_contract() {
  local repository_root=$1
  local version_file=${SHITATE_VERSION_FILE:-"$repository_root/VERSION"}
  local bundle_version_file=${SHITATE_BUNDLE_VERSION_FILE:-"$repository_root/BUNDLE_VERSION"}
  local version=
  local bundle_version=

  shitate_read_single_line_file "$version_file" VERSION || return 1
  version=$SHITATE_READ_VALUE
  shitate_read_single_line_file "$bundle_version_file" BUNDLE_VERSION || return 1
  bundle_version=$SHITATE_READ_VALUE

  shitate_parse_version "$version" || return 1
  shitate_validate_bundle_version "$bundle_version" || return 1
}
