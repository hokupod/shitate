# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

function(shitate_read_contract_file path label output_variable)
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "${label} file does not exist: ${path}")
  endif()

  file(READ "${path}" raw_value)
  string(REGEX REPLACE "\n$" "" value "${raw_value}")
  if(value MATCHES "[\r\n]")
    message(FATAL_ERROR "${label} must contain exactly one line")
  endif()
  set(${output_variable} "${value}" PARENT_SCOPE)
endfunction()

function(shitate_parse_version value full_output core_output channel_output prerelease_output)
  set(number "(0|[1-9][0-9]*)")
  set(version_pattern
    "^${number}\\.${number}\\.${number}(-(dev|(alpha|beta|rc)\\.${number}))?$")
  if(NOT value MATCHES "${version_pattern}")
    message(FATAL_ERROR
      "VERSION must be X.Y.Z-dev, X.Y.Z, or X.Y.Z-(alpha|beta|rc).N without leading zeroes; got '${value}'")
  endif()

  string(REGEX MATCH "^[0-9]+\\.[0-9]+\\.[0-9]+" version_core "${value}")
  if(value STREQUAL version_core)
    set(channel stable)
    set(is_prerelease FALSE)
  elseif(value MATCHES "-dev$")
    set(channel development)
    set(is_prerelease FALSE)
  else()
    string(REGEX MATCH "-(alpha|beta|rc)\\." channel_match "${value}")
    set(channel "${CMAKE_MATCH_1}")
    set(is_prerelease TRUE)
  endif()

  set(${full_output} "${value}" PARENT_SCOPE)
  set(${core_output} "${version_core}" PARENT_SCOPE)
  set(${channel_output} "${channel}" PARENT_SCOPE)
  set(${prerelease_output} "${is_prerelease}" PARENT_SCOPE)
endfunction()

function(shitate_read_version_contract full_output core_output channel_output prerelease_output bundle_output)
  if(DEFINED SHITATE_VERSION_FILE)
    set(version_file "${SHITATE_VERSION_FILE}")
  else()
    set(version_file "${CMAKE_SOURCE_DIR}/VERSION")
  endif()
  if(DEFINED SHITATE_BUNDLE_VERSION_FILE)
    set(bundle_version_file "${SHITATE_BUNDLE_VERSION_FILE}")
  else()
    set(bundle_version_file "${CMAKE_SOURCE_DIR}/BUNDLE_VERSION")
  endif()

  shitate_read_contract_file("${version_file}" VERSION version)
  shitate_read_contract_file("${bundle_version_file}" BUNDLE_VERSION bundle_version)
  shitate_parse_version("${version}" full_version version_core channel is_prerelease)

  if(NOT bundle_version MATCHES "^[1-9][0-9]*$")
    message(FATAL_ERROR
      "BUNDLE_VERSION must be a positive integer without leading zeroes; got '${bundle_version}'")
  endif()

  set(${full_output} "${full_version}" PARENT_SCOPE)
  set(${core_output} "${version_core}" PARENT_SCOPE)
  set(${channel_output} "${channel}" PARENT_SCOPE)
  set(${prerelease_output} "${is_prerelease}" PARENT_SCOPE)
  set(${bundle_output} "${bundle_version}" PARENT_SCOPE)
endfunction()
