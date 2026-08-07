// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#import "STErrorMapper.h"

#import "Public/STAudioEngineBridge.h"

NSErrorDomain const STBridgeErrorDomain = @"dev.hokupod.shitate.error";

NSError* STMakeBridgeError(NSInteger code, NSString* message) {
    return [NSError errorWithDomain:STBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : [message copy]}];
}

NSError* STMakeAudioBridgeError(NSInteger code, NSString* technicalDetail) {
    (void)technicalDetail;
    NSString* description;
    switch (code) {
    case STBridgeErrorCodeBlackHoleMissing:
        description = @"Routing did not start because BlackHole 2ch was not found. Shi-tate did "
                      @"not select another output. Install BlackHole, then check again.";
        break;
    case STBridgeErrorCodeMicrophonePermissionDenied:
        description = @"Routing stopped because microphone access is unavailable. Allow access in "
                      @"System Settings, then check again.";
        break;
    case STBridgeErrorCodeInputDeviceMissing:
        description = @"Routing stopped because the selected microphone is unavailable. Shi-tate "
                      @"did not select another input.";
        break;
    case STBridgeErrorCodeOutputDeviceMissing:
        description = @"Routing stopped because the selected output is unavailable. Shi-tate did "
                      @"not send audio to another device.";
        break;
    case STBridgeErrorCodeUnsupportedSampleRate:
        description = @"Routing did not start because both devices must support 48 kHz.";
        break;
    case STBridgeErrorCodeUnsupportedBufferSize:
        description = @"Routing did not start because the selected buffer size is unsupported.";
        break;
    case STBridgeErrorCodeAggregateDeviceCreationFailed:
        description = @"Routing did not start because the private CoreAudio route could not be "
                      @"created. Output remains silent.";
        break;
    case STBridgeErrorCodeEngineXRun:
        description = @"CoreAudio reported an overrun or underrun. Check the audio configuration "
                      @"before continuing.";
        break;
    default:
        description = @"Audio routing is unavailable and output remains silent. Review Audio "
                      @"Settings before trying again.";
        break;
    }

    return [NSError errorWithDomain:STBridgeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : description}];
}
