# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

function(shitate_embed_helper app_target helper_target)
  add_dependencies(${app_target} ${helper_target})

  set(helper_directory "$<TARGET_BUNDLE_DIR:${app_target}>/Contents/Helpers")
  set(resource_directory "$<TARGET_BUNDLE_DIR:${app_target}>/Contents/Resources")

  add_custom_command(TARGET ${app_target} POST_BUILD
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${helper_directory}"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
      "$<TARGET_FILE:${helper_target}>"
      "${helper_directory}/ShitatePluginScanner"
    COMMAND "${CMAKE_COMMAND}" -E make_directory "${resource_directory}"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
      "${CMAKE_SOURCE_DIR}/LICENSE"
      "${resource_directory}/LICENSE"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
      "${CMAKE_SOURCE_DIR}/THIRD_PARTY_NOTICES.md"
      "${resource_directory}/THIRD_PARTY_NOTICES.md"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different
      "${CMAKE_SOURCE_DIR}/LICENSES/JUCE-LICENSE.md"
      "${resource_directory}/JUCE-LICENSE.md"
    VERBATIM)
endfunction()
