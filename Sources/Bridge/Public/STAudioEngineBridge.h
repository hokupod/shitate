// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const STBridgeErrorDomain;

typedef NS_ERROR_ENUM(STBridgeErrorDomain, STBridgeErrorCode){
    STBridgeErrorCodeUnknown = 1,
    STBridgeErrorCodeCppException = 2,
};

@interface STAudioEngineBridge : NSObject

@property(nonatomic, readonly, copy) NSString* displayVersion;

- (BOOL)exerciseExceptionForTesting:(NSError* _Nullable* _Nullable)error;

@end

NS_ASSUME_NONNULL_END
