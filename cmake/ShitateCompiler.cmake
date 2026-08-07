# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Hokuto Takemiya

function(shitate_enable_warnings target)
  target_compile_options(${target} PRIVATE
    $<$<COMPILE_LANGUAGE:C,CXX,OBJC,OBJCXX>:-Wall;-Wextra;-Wpedantic;-Werror>)
endfunction()

function(shitate_apply_juce_definitions target)
  target_compile_definitions(${target} PRIVATE
    JUCE_PLUGINHOST_VST3=1
    JUCE_PLUGINHOST_VST=0
    JUCE_PLUGINHOST_AU=0
    JUCE_PLUGINHOST_LADSPA=0
    JUCE_PLUGINHOST_LV2=0
    JUCE_COREAUDIO_LOGGING_ENABLED=0
    JUCE_USE_CURL=0
    JUCE_WEB_BROWSER=0
    JUCE_USE_FLAC=0
    JUCE_USE_OGGVORBIS=0
    JUCE_USE_MP3AUDIOFORMAT=0
    JUCE_USE_LAME_AUDIO_FORMAT=0
    JUCE_USE_CDREADER=0
    JUCE_USE_CDBURNER=0
    JUCE_USE_CAMERA=0
    JUCE_DISPLAY_SPLASH_SCREEN=0
    JUCE_REPORT_APP_USAGE=0
    JUCE_MODAL_LOOPS_PERMITTED=1)
endfunction()
