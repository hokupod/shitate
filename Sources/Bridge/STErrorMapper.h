// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NSError* STMakeBridgeError(NSInteger code, NSString* message);
NSError* STMakeAudioBridgeError(NSInteger code, NSString* technicalDetail);

NS_ASSUME_NONNULL_END
