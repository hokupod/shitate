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
