// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#import "Public/STAudioEngineBridge.h"

#include "ApplicationCore.h"
#import "STErrorMapper.h"

#include <exception>

@implementation STAudioEngineBridge

- (NSString*)displayVersion {
    try {
        const auto version = shitate::ApplicationCore::displayVersion();
        NSString* displayVersion = [[NSString alloc] initWithBytes:version.data()
                                                            length:version.size()
                                                          encoding:NSUTF8StringEncoding];
        return displayVersion != nil ? displayVersion : @"unknown";
    } catch (...) {
        return @"unknown";
    }
}

- (BOOL)exerciseExceptionForTesting:(NSError**)error {
    try {
        shitate::ApplicationCore::throwForTesting();
        return YES;
    } catch (const std::exception& exception) {
        if (error != nullptr) {
            NSString* message = [NSString stringWithUTF8String:exception.what()];
            *error = STMakeBridgeError(STBridgeErrorCodeCppException, message);
        }
        return NO;
    } catch (...) {
        if (error != nullptr) {
            *error = STMakeBridgeError(STBridgeErrorCodeUnknown, @"Unknown C++ exception");
        }
        return NO;
    }
}

@end
