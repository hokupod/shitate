# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

function(shitate_read_display_version output_variable)
  if(DEFINED SHITATE_VERSION_FILE)
    set(version_file "${SHITATE_VERSION_FILE}")
  else()
    set(version_file "${CMAKE_SOURCE_DIR}/VERSION")
  endif()

  if(NOT EXISTS "${version_file}")
    message(FATAL_ERROR "VERSION file does not exist: ${version_file}")
  endif()

  file(READ "${version_file}" display_version)
  string(STRIP "${display_version}" display_version)

  if(NOT display_version MATCHES "^[0-9]+\\.[0-9]+\\.[0-9]+-dev$")
    message(FATAL_ERROR
      "VERSION must use the <major>.<minor>.<patch>-dev form; got '${display_version}'")
  endif()

  set(${output_variable} "${display_version}" PARENT_SCOPE)
endfunction()
