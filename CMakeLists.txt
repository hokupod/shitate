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
  Sources/Core/ApplicationCore.h
  Sources/Core/Audio/AudioBridgeController.cpp
  Sources/Core/Audio/AudioBridgeController.h
  Sources/Core/Audio/AudioEngine.cpp
  Sources/Core/Audio/AudioEngine.h
  Sources/Core/Audio/AudioTypes.h
  Sources/Core/Audio/DeviceService.cpp
  Sources/Core/Audio/DeviceService.h
  Sources/Core/Audio/InputMapper.cpp
  Sources/Core/Audio/InputMapper.h
  Sources/Core/Audio/MasterOutputStage.cpp
  Sources/Core/Audio/MasterOutputStage.h
  Sources/Core/Audio/MeterAccumulator.cpp
  Sources/Core/Audio/MeterAccumulator.h
  Sources/Core/Audio/OutputSafetyProcessor.cpp
  Sources/Core/Audio/OutputSafetyProcessor.h
  Sources/Core/Audio/HostedPluginSlot.cpp
  Sources/Core/Audio/HostedPluginSlot.h
  Sources/Core/Audio/PluginChain.cpp
  Sources/Core/Audio/PluginChain.h
  Sources/Core/Audio/PluginChainTypes.h
  Sources/Core/Audio/RealtimeEventQueue.cpp
  Sources/Core/Audio/RealtimeEventQueue.h
  Sources/Core/Audio/RealtimeSafety.h
  Sources/Core/Plugins/PluginCatalog.cpp
  Sources/Core/Plugins/PluginCatalog.h
  Sources/Core/Plugins/PluginEditorWindowManager.cpp
  Sources/Core/Plugins/PluginEditorWindowManager.h
  Sources/Core/Plugins/PluginFactory.cpp
  Sources/Core/Plugins/PluginFactory.h
  Sources/Core/Plugins/PluginLoadJournal.cpp
  Sources/Core/Plugins/PluginLoadJournal.h
  Sources/Core/Plugins/PluginRuntimeTypes.cpp
  Sources/Core/Plugins/PluginRuntimeTypes.h
  Sources/Core/Plugins/PluginScanCoordinator.cpp
  Sources/Core/Plugins/PluginScanCoordinator.h
  Sources/Core/Plugins/PluginScanProtocol.cpp
  Sources/Core/Plugins/PluginScanProtocol.h
  Sources/Core/Plugins/PluginScanTypes.h
  Sources/Core/Plugins/PluginSignatureVerifier.h
  Sources/Core/Plugins/PluginSignatureVerifier.mm
  external/JUCE/modules/juce_audio_processors_headless/format_types/VST3_SDK/public.sdk/source/vst/hosting/module.cpp
  external/JUCE/modules/juce_audio_processors_headless/format_types/VST3_SDK/public.sdk/source/vst/hosting/module_mac.mm)
target_include_directories(ShitateCore PUBLIC
  Sources/Core
  external/JUCE/modules)
target_link_libraries(ShitateCore PRIVATE
  juce::juce_audio_devices
  juce::juce_audio_processors
  juce::juce_cryptography
  juce::juce_gui_basics
  "-framework Security")
target_compile_definitions(ShitateCore PRIVATE
  SHITATE_DISPLAY_VERSION="${SHITATE_DISPLAY_VERSION}")
shitate_apply_juce_definitions(ShitateCore)
shitate_enable_warnings(ShitateCore)
target_compile_options(ShitateCore PRIVATE
  $<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wno-unnecessary-virtual-specifier>)

add_library(ShitateBridge STATIC
  Sources/Bridge/Public/ShitateBridge.h
  Sources/Bridge/Public/STAudioEngineBridge.h
  Sources/Bridge/Public/STModels.h
  Sources/Bridge/Public/STPluginBridge.h
  Sources/Bridge/STAudioEngineBridge.mm
  Sources/Bridge/STErrorMapper.h
  Sources/Bridge/STErrorMapper.mm
  Sources/Bridge/STModels.mm
  Sources/Bridge/STPluginBridge.mm)
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
  Sources/App/ApplicationState.swift
  Sources/App/AppModel.swift
  Sources/App/AudioDevice.swift
  Sources/App/ShitateApp.swift
  Sources/Services/MicrophonePermissionService.swift
  Sources/Services/Persistence/AtomicFileWriter.swift
  Sources/Services/Persistence/PersistenceModels.swift
  Sources/Services/Persistence/PluginCatalogService.swift
  Sources/Services/Persistence/PluginCatalogStore.swift
  Sources/Services/Persistence/SecurePersistence.swift
  Sources/Services/Persistence/SessionStore.swift
  Sources/Services/WorkspaceEventService.swift
  Sources/UI/AudioRoutingView.swift)
target_link_libraries(Shitate PRIVATE
  ShitateBridge
  "-framework AppKit"
  "-framework AVFoundation"
  "-framework SwiftUI")
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

add_executable(ShitatePluginScanner
  Sources/Scanner/main.cpp
  Sources/Scanner/ScanRequest.cpp
  Sources/Scanner/ScanRequest.h
  Sources/Scanner/ScanResultWriter.cpp
  Sources/Scanner/ScanResultWriter.h
  Sources/Scanner/VST3Scanner.cpp
  Sources/Scanner/VST3Scanner.h)
set_source_files_properties(
  external/JUCE/modules/juce_audio_processors_headless/format_types/VST3_SDK/public.sdk/source/vst/hosting/module_mac.mm
  PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
target_include_directories(ShitatePluginScanner PRIVATE Sources/Scanner)
target_link_libraries(ShitatePluginScanner PRIVATE
  ShitateCore
  juce::juce_audio_processors
  juce::juce_gui_basics)
shitate_apply_juce_definitions(ShitatePluginScanner)
shitate_enable_warnings(ShitatePluginScanner)
target_compile_options(ShitatePluginScanner PRIVATE
  $<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wno-unnecessary-virtual-specifier>)
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

  function(shitate_add_test_plugin target product_name plugin_code plugin_kind is_synth)
    string(TOLOWER "${product_name}" bundle_component)
    juce_add_plugin(${target}
      VERSION 1.0.0
      COMPANY_NAME "Shi-tate Tests"
      BUNDLE_ID "dev.hokupod.shitate.tests.${bundle_component}"
      IS_SYNTH ${is_synth}
      NEEDS_MIDI_INPUT FALSE
      NEEDS_MIDI_OUTPUT FALSE
      IS_MIDI_EFFECT FALSE
      COPY_PLUGIN_AFTER_BUILD FALSE
      PLUGIN_MANUFACTURER_CODE Hkpd
      PLUGIN_CODE ${plugin_code}
      FORMATS VST3
      PRODUCT_NAME ${product_name}
      NEEDS_WEB_BROWSER FALSE
      NEEDS_CURL FALSE)
    target_sources(${target} PRIVATE
      Tests/TestPlugins/TestPluginProcessor.cpp
      Tests/TestPlugins/TestPluginProcessor.h)
    target_compile_definitions(${target} PRIVATE
      SHITATE_TEST_PLUGIN_KIND=${plugin_kind}
      JUCE_VST3_CAN_REPLACE_VST2=0
      JUCE_USE_CURL=0
      JUCE_WEB_BROWSER=0)
    target_link_libraries(${target} PRIVATE juce::juce_audio_utils)
    shitate_enable_warnings(${target})
    target_compile_options(${target} PRIVATE
      $<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wno-unnecessary-virtual-specifier>)
  endfunction()

  shitate_add_test_plugin(ShitateGainPlugin GainPlugin Gai0 0 FALSE)
  shitate_add_test_plugin(ShitateLatencyPlugin LatencyPlugin Lat0 1 FALSE)
  shitate_add_test_plugin(ShitateNaNPlugin NaNPlugin Nan0 2 FALSE)
  shitate_add_test_plugin(ShitateThrowPlugin ThrowPlugin Thr0 3 FALSE)
  shitate_add_test_plugin(ShitateCrashPlugin CrashPlugin Cra0 4 FALSE)
  shitate_add_test_plugin(ShitateHangPlugin HangPlugin Han0 5 FALSE)
  shitate_add_test_plugin(ShitateMonoOnlyPlugin MonoOnlyPlugin Mon0 6 FALSE)
  shitate_add_test_plugin(ShitateInstrumentPlugin InstrumentPlugin Ins0 7 TRUE)

  add_custom_target(TestVST3Plugins DEPENDS
    ShitateGainPlugin_VST3
    ShitateLatencyPlugin_VST3
    ShitateNaNPlugin_VST3
    ShitateThrowPlugin_VST3
    ShitateCrashPlugin_VST3
    ShitateHangPlugin_VST3
    ShitateMonoOnlyPlugin_VST3
    ShitateInstrumentPlugin_VST3)

  add_executable(ShitateCppTests
    Tests/Cpp/TestMain.cpp
    Tests/Cpp/AudioEngineTest.cpp
    Tests/Cpp/AudioPrimitivesTest.cpp
    Tests/Cpp/CoreVersionTest.cpp
    Tests/Cpp/DeviceServiceTest.cpp
    Tests/Cpp/HostedPluginSlotTest.cpp
    Tests/Cpp/PluginCatalogTest.cpp
    Tests/Cpp/PluginChainTest.cpp
    Tests/Cpp/PluginEditorWindowManagerTest.cpp
    Tests/Cpp/PluginFactoryTest.cpp
    Tests/Cpp/PluginLoadJournalTest.cpp
    Tests/Cpp/PluginRuntimeAudioTest.cpp
    Tests/Cpp/PluginRuntimeTestSupport.h
    Tests/Cpp/PluginScanCoordinatorTest.cpp
    Tests/Cpp/PluginScanProtocolTest.cpp
    Tests/Cpp/PluginSignatureVerifierTest.cpp
    Tests/Cpp/RealtimeEventQueueTest.cpp
    Tests/Cpp/TestAllocationTracker.cpp
    Tests/Cpp/TestAllocationTracker.h)
  target_link_libraries(ShitateCppTests PRIVATE
    ShitateCore
    juce::juce_core
    juce::juce_gui_basics)
  target_compile_definitions(ShitateCppTests PRIVATE JUCE_UNIT_TESTS=1)
  shitate_apply_juce_definitions(ShitateCppTests)
  shitate_enable_warnings(ShitateCppTests)

  add_executable(ShitateAudioHardwareTest
    Tests/Integration/AudioHardwareIntegrationTest.cpp)
  target_link_libraries(ShitateAudioHardwareTest PRIVATE ShitateCore)
  shitate_enable_warnings(ShitateAudioHardwareTest)

  add_executable(ShitateScannerProtocolFixture
    Tests/Integration/ScannerProtocolFixture.cpp)
  shitate_enable_warnings(ShitateScannerProtocolFixture)

  add_executable(ShitateScannerIntegrationTest
    Tests/Integration/ScannerIntegrationTest.cpp)
  target_link_libraries(ShitateScannerIntegrationTest PRIVATE ShitateCore)
  target_compile_definitions(ShitateScannerIntegrationTest PRIVATE
    SHITATE_SCANNER_PATH="$<TARGET_FILE:ShitatePluginScanner>"
    SHITATE_SCANNER_PROTOCOL_FIXTURE_PATH="$<TARGET_FILE:ShitateScannerProtocolFixture>"
    SHITATE_GAIN_PLUGIN_PATH="$<TARGET_BUNDLE_DIR:ShitateGainPlugin_VST3>"
    SHITATE_LATENCY_PLUGIN_PATH="$<TARGET_BUNDLE_DIR:ShitateLatencyPlugin_VST3>"
    SHITATE_NAN_PLUGIN_PATH="$<TARGET_BUNDLE_DIR:ShitateNaNPlugin_VST3>"
    SHITATE_THROW_PLUGIN_PATH="$<TARGET_BUNDLE_DIR:ShitateThrowPlugin_VST3>"
    SHITATE_CRASH_PLUGIN_PATH="$<TARGET_BUNDLE_DIR:ShitateCrashPlugin_VST3>"
    SHITATE_HANG_PLUGIN_PATH="$<TARGET_BUNDLE_DIR:ShitateHangPlugin_VST3>"
    SHITATE_MONO_PLUGIN_PATH="$<TARGET_BUNDLE_DIR:ShitateMonoOnlyPlugin_VST3>"
    SHITATE_INSTRUMENT_PLUGIN_PATH="$<TARGET_BUNDLE_DIR:ShitateInstrumentPlugin_VST3>")
  add_dependencies(ShitateScannerIntegrationTest
    ShitatePluginScanner
    ShitateScannerProtocolFixture
    TestVST3Plugins)
  shitate_enable_warnings(ShitateScannerIntegrationTest)

  add_executable(ShitatePluginRuntimeHost
    Tests/Integration/PluginRuntimeHost.cpp)
  target_link_libraries(ShitatePluginRuntimeHost PRIVATE
    ShitateCore
    juce::juce_audio_processors
    juce::juce_gui_basics)
  target_compile_definitions(ShitatePluginRuntimeHost PRIVATE
    SHITATE_SCANNER_PATH="$<TARGET_FILE:ShitatePluginScanner>"
    SHITATE_GAIN_PLUGIN_PATH="$<TARGET_BUNDLE_DIR:ShitateGainPlugin_VST3>")
  add_dependencies(ShitatePluginRuntimeHost
    ShitatePluginScanner
    ShitateGainPlugin_VST3)
  shitate_apply_juce_definitions(ShitatePluginRuntimeHost)
  shitate_enable_warnings(ShitatePluginRuntimeHost)
  target_compile_options(ShitatePluginRuntimeHost PRIVATE
    $<$<COMPILE_LANGUAGE:CXX,OBJCXX>:-Wno-unnecessary-virtual-specifier>)

  xctest_add_bundle(ShitateSwiftTests Shitate
    Sources/App/ApplicationState.swift
    Sources/App/AudioDevice.swift
    Sources/Services/MicrophonePermissionService.swift
    Sources/Services/Persistence/AtomicFileWriter.swift
    Sources/Services/Persistence/PersistenceModels.swift
    Sources/Services/Persistence/PluginCatalogService.swift
    Sources/Services/Persistence/PluginCatalogStore.swift
    Sources/Services/Persistence/SecurePersistence.swift
    Sources/Services/Persistence/SessionStore.swift
    Sources/Services/WorkspaceEventService.swift
    Tests/Swift/ApplicationStateTests.swift
    Tests/Swift/AtomicFileWriterTests.swift
    Tests/Swift/AudioEnvironmentTests.swift
    Tests/Swift/BridgeVersionTests.swift
    Tests/Swift/MicrophonePermissionTests.swift
    Tests/Swift/PersistenceStoreTests.swift
    Tests/Swift/PluginBundleDiscoveryTests.swift
    Tests/Swift/PluginCatalogStoreTests.swift
    Tests/Swift/SessionStoreTests.swift
    Tests/Swift/WorkspaceEventServiceTests.swift)
  target_link_libraries(ShitateSwiftTests PRIVATE
    ShitateBridge
    "-framework AppKit"
    "-framework AVFoundation")
  target_link_options(ShitateSwiftTests PRIVATE
    "LINKER:-force_load,$<TARGET_FILE:ShitateBridge>"
    "LINKER:-force_load,$<TARGET_FILE:ShitateCore>")
  set_target_properties(ShitateSwiftTests PROPERTIES
    XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER
      "${CMAKE_SOURCE_DIR}/Sources/Bridge/Public/ShitateBridge.h"
    XCODE_ATTRIBUTE_SWIFT_STRICT_CONCURRENCY "complete"
    XCODE_ATTRIBUTE_SWIFT_VERSION "6.0")

  add_test(NAME CoreVersionTest COMMAND ShitateCppTests --test "Core display version")
  set_tests_properties(CoreVersionTest PROPERTIES LABELS "unit;cpp")

  foreach(audio_test IN ITEMS InputMapper Meter OutputSafety MasterOutput RealtimeEventQueue)
    add_test(NAME ${audio_test}Test COMMAND ShitateCppTests --test ${audio_test})
    set_tests_properties(${audio_test}Test PROPERTIES LABELS "unit;cpp;audio-unit")
  endforeach()

  add_test(NAME DeviceServiceTest COMMAND ShitateCppTests --test DeviceService)
  set_tests_properties(DeviceServiceTest PROPERTIES LABELS "unit;cpp;audio-unit")

  add_test(NAME AudioEngineTest COMMAND ShitateCppTests --test AudioEngine)
  set_tests_properties(AudioEngineTest PROPERTIES LABELS "unit;cpp;audio-unit;audio-integration")

  add_test(NAME PluginScanProtocolTest COMMAND ShitateCppTests --test PluginScanProtocol)
  set_tests_properties(PluginScanProtocolTest PROPERTIES LABELS "unit;cpp;scanner")

  add_test(NAME PluginSignatureVerifierTest
    COMMAND ShitateCppTests --test PluginSignatureVerifier)
  set_tests_properties(PluginSignatureVerifierTest PROPERTIES LABELS "unit;cpp;signature")

  add_test(NAME PluginCatalogTest COMMAND ShitateCppTests --test PluginCatalog)
  set_tests_properties(PluginCatalogTest PROPERTIES LABELS "unit;cpp;scanner")

  add_test(NAME PluginScanCoordinatorTest
    COMMAND ShitateCppTests --test PluginScanCoordinator)
  set_tests_properties(PluginScanCoordinatorTest PROPERTIES LABELS "unit;cpp;scanner")

  foreach(runtime_test IN ITEMS
      HostedPluginSlot
      PluginChain
      PluginEditorWindowManager
      PluginFactory
      PluginLoadJournal
      PluginRuntimeAudio)
    add_test(NAME ${runtime_test}Test COMMAND ShitateCppTests --test ${runtime_test})
    set_tests_properties(${runtime_test}Test PROPERTIES
      LABELS "unit;cpp;plugin-runtime-unit")
  endforeach()

  add_test(NAME ScannerIntegrationTest COMMAND ShitateScannerIntegrationTest)
  set_tests_properties(ScannerIntegrationTest PROPERTIES
    LABELS "integration;scanner;signature"
    TIMEOUT 30)

  add_test(NAME PluginRuntimeIntegrationTest COMMAND ShitatePluginRuntimeHost)
  set_tests_properties(PluginRuntimeIntegrationTest PROPERTIES
    LABELS "integration;plugin-runtime-integration"
    TIMEOUT 30)

  xctest_add_test(BridgeVersionTest ShitateSwiftTests)
  set_tests_properties(BridgeVersionTest PROPERTIES
    LABELS "unit;swift;audio-unit;swift-state;persistence;ui-integration")

  add_test(NAME AudioHardwareIntegrationTest COMMAND ShitateAudioHardwareTest)
  set_tests_properties(AudioHardwareIntegrationTest PROPERTIES
    LABELS "audio-integration;hardware"
    SKIP_RETURN_CODE 77)

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
