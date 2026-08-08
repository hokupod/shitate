# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

include("${CMAKE_CURRENT_LIST_DIR}/../../cmake/ShitateVersion.cmake")
shitate_read_version_contract(
  validated_version
  validated_core
  validated_channel
  validated_prerelease
  validated_bundle)

foreach(field IN ITEMS version core channel prerelease bundle)
  string(TOUPPER "${field}" field_upper)
  if(DEFINED EXPECTED_${field_upper} AND
     NOT validated_${field} STREQUAL EXPECTED_${field_upper})
    message(FATAL_ERROR
      "Expected ${field} '${EXPECTED_${field_upper}}'; got '${validated_${field}}'")
  endif()
endforeach()

if(VALIDATE_PLISTS)
  if(NOT DEFINED PLIST_OUTPUT_DIR)
    message(FATAL_ERROR "PLIST_OUTPUT_DIR is required with VALIDATE_PLISTS")
  endif()
  file(MAKE_DIRECTORY "${PLIST_OUTPUT_DIR}")
  set(SHITATE_DISPLAY_VERSION "${validated_version}")
  set(SHITATE_VERSION_CORE "${validated_core}")
  set(SHITATE_BUNDLE_VERSION "${validated_bundle}")
  set(SHITATE_GIT_COMMIT "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
  configure_file(
    "${CMAKE_CURRENT_LIST_DIR}/../../resources/Info.plist.in"
    "${PLIST_OUTPUT_DIR}/Info.plist"
    @ONLY)
  configure_file(
    "${CMAKE_CURRENT_LIST_DIR}/../../resources/Scanner-Info.plist.in"
    "${PLIST_OUTPUT_DIR}/Scanner-Info.plist"
    @ONLY)

  foreach(plist IN ITEMS Info.plist Scanner-Info.plist)
    foreach(mapping IN ITEMS
      "ShitateVersion;${validated_version}"
      "CFBundleShortVersionString;${validated_core}"
      "CFBundleVersion;${validated_bundle}")
      list(GET mapping 0 key)
      list(GET mapping 1 expected)
      execute_process(
        COMMAND /usr/bin/plutil -extract "${key}" raw -o - "${PLIST_OUTPUT_DIR}/${plist}"
        OUTPUT_VARIABLE actual
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE result)
      if(NOT result EQUAL 0 OR NOT actual STREQUAL expected)
        message(FATAL_ERROR
          "${plist} ${key}: expected '${expected}'; got '${actual}'")
      endif()
    endforeach()
  endforeach()
endif()
