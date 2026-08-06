# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

cmake_minimum_required(VERSION 3.31)

set(CMAKE_OSX_SYSROOT "macosx" CACHE STRING "macOS SDK" FORCE)
project(Shitate VERSION 0.1.0 LANGUAGES C CXX OBJC OBJCXX Swift)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/cmake")
include(CTest)
include(ShitateBundle)
include(ShitateCompiler)
include(ShitateVersion)

if(NOT APPLE)
  message(FATAL_ERROR "Shi-tate v0.1 supports macOS only")
endif()

if(NOT CMAKE_GENERATOR STREQUAL "Xcode")
  message(FATAL_ERROR "Shi-tate requires the CMake Xcode generator")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "Supported architecture" FORCE)
set(CMAKE_OSX_DEPLOYMENT_TARGET "14.0" CACHE STRING "Minimum macOS version" FORCE)
set(CMAKE_XCODE_GENERATE_SCHEME ON)

shitate_read_display_version(SHITATE_DISPLAY_VERSION)
if(NOT SHITATE_DISPLAY_VERSION STREQUAL "${PROJECT_VERSION}-dev")
  message(FATAL_ERROR
    "VERSION (${SHITATE_DISPLAY_VERSION}) must match project version (${PROJECT_VERSION}-dev)")
endif()

set(JUCE_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(JUCE_BUILD_EXTRAS OFF CACHE BOOL "" FORCE)
set(JUCE_ENABLE_MODULE_SOURCE_GROUPS OFF CACHE BOOL "" FORCE)
add_subdirectory(external/JUCE)

add_library(ShitateCore STATIC
  Sources/Core/ApplicationCore.cpp
  Sources/Core/ApplicationCore.h)
target_include_directories(ShitateCore PUBLIC Sources/Core)
target_compile_definitions(ShitateCore PRIVATE
  SHITATE_DISPLAY_VERSION="${SHITATE_DISPLAY_VERSION}")
shitate_apply_juce_definitions(ShitateCore)
shitate_enable_warnings(ShitateCore)

add_library(ShitateBridge STATIC
  Sources/Bridge/Public/ShitateBridge.h
  Sources/Bridge/Public/STAudioEngineBridge.h
  Sources/Bridge/Public/STModels.h
  Sources/Bridge/STAudioEngineBridge.mm
  Sources/Bridge/STErrorMapper.h
  Sources/Bridge/STErrorMapper.mm)
target_include_directories(ShitateBridge PUBLIC Sources/Bridge/Public)
target_include_directories(ShitateBridge PRIVATE Sources/Bridge Sources/Core)
target_link_libraries(ShitateBridge PUBLIC ShitateCore "-framework Foundation")
shitate_enable_warnings(ShitateBridge)
set_target_properties(ShitateBridge PROPERTIES
  XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES")

configure_file(resources/Info.plist.in resources/Info.plist @ONLY)
configure_file(resources/Scanner-Info.plist.in resources/Scanner-Info.plist @ONLY)

add_executable(Shitate MACOSX_BUNDLE
  Sources/App/AppDelegate.swift
  Sources/App/ShitateApp.swift)
target_link_libraries(Shitate PRIVATE ShitateBridge "-framework AppKit" "-framework SwiftUI")
set_target_properties(Shitate PROPERTIES
  OUTPUT_NAME "Shi-tate"
  MACOSX_BUNDLE_BUNDLE_NAME "Shi-tate"
  MACOSX_BUNDLE_GUI_IDENTIFIER "dev.hokupod.shitate"
  MACOSX_BUNDLE_INFO_PLIST "${CMAKE_BINARY_DIR}/resources/Info.plist"
  XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++20"
  XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_SOURCE_DIR}/resources/Shitate.entitlements"
  XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME "YES"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "dev.hokupod.shitate"
  XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER
    "${CMAKE_SOURCE_DIR}/Sources/Bridge/Public/ShitateBridge.h"
  XCODE_ATTRIBUTE_SWIFT_STRICT_CONCURRENCY "complete"
  XCODE_ATTRIBUTE_SWIFT_VERSION "6.0")

add_executable(ShitatePluginScanner Sources/Scanner/main.cpp)
target_link_libraries(ShitatePluginScanner PRIVATE ShitateCore)
shitate_enable_warnings(ShitatePluginScanner)
set_target_properties(ShitatePluginScanner PROPERTIES
  OUTPUT_NAME "ShitatePluginScanner"
  XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++20"
  XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_SOURCE_DIR}/resources/Scanner.entitlements"
  XCODE_ATTRIBUTE_CREATE_INFOPLIST_SECTION_IN_BINARY "YES"
  XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME "YES"
  XCODE_ATTRIBUTE_INFOPLIST_FILE "${CMAKE_BINARY_DIR}/resources/Scanner-Info.plist"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "dev.hokupod.shitate.plugin-scanner")

shitate_embed_helper(Shitate ShitatePluginScanner)

if(BUILD_TESTING)
  find_package(XCTest REQUIRED)

  add_executable(ShitateCppTests
    Tests/Cpp/TestMain.cpp
    Tests/Cpp/CoreVersionTest.cpp)
  target_link_libraries(ShitateCppTests PRIVATE ShitateCore juce::juce_core)
  target_compile_definitions(ShitateCppTests PRIVATE JUCE_UNIT_TESTS=1)
  shitate_apply_juce_definitions(ShitateCppTests)
  shitate_enable_warnings(ShitateCppTests)

  xctest_add_bundle(ShitateSwiftTests Shitate
    Tests/Swift/BridgeVersionTests.swift)
  target_link_libraries(ShitateSwiftTests PRIVATE ShitateBridge)
  target_link_options(ShitateSwiftTests PRIVATE
    "LINKER:-force_load,$<TARGET_FILE:ShitateBridge>"
    "LINKER:-force_load,$<TARGET_FILE:ShitateCore>")
  set_target_properties(ShitateSwiftTests PROPERTIES
    XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER
      "${CMAKE_SOURCE_DIR}/Sources/Bridge/Public/ShitateBridge.h"
    XCODE_ATTRIBUTE_SWIFT_STRICT_CONCURRENCY "complete"
    XCODE_ATTRIBUTE_SWIFT_VERSION "6.0")

  add_test(NAME CoreVersionTest COMMAND ShitateCppTests)
  set_tests_properties(CoreVersionTest PROPERTIES LABELS "unit;cpp")

  xctest_add_test(BridgeVersionTest ShitateSwiftTests)
  set_tests_properties(BridgeVersionTest PROPERTIES LABELS "unit;swift")

  add_test(NAME ScannerArgumentsTest
    COMMAND "${CMAKE_SOURCE_DIR}/Tests/Integration/ScannerArgumentsTest.sh"
      "$<TARGET_FILE:ShitatePluginScanner>")
  set_tests_properties(ScannerArgumentsTest PROPERTIES LABELS "integration;helper")

  add_test(NAME BundleLayoutTest
    COMMAND "${CMAKE_SOURCE_DIR}/Tests/Integration/BundleLayoutTest.sh"
      "$<TARGET_BUNDLE_DIR:Shitate>")
  set_tests_properties(BundleLayoutTest PROPERTIES
    DEPENDS ScannerArgumentsTest
    LABELS "integration;bundle")

  add_test(NAME InvalidVersionTest
    COMMAND "${CMAKE_COMMAND}"
      -DSHITATE_VERSION_FILE=${CMAKE_SOURCE_DIR}/Tests/Fixtures/invalid-version.txt
      -P ${CMAKE_SOURCE_DIR}/Tests/Integration/ValidateVersion.cmake)
  set_tests_properties(InvalidVersionTest PROPERTIES
    LABELS "unit;cmake"
    WILL_FAIL TRUE)
endif()
