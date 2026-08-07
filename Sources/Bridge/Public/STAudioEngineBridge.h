// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#import "STModels.h"

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const STBridgeErrorDomain;

typedef NS_ERROR_ENUM(STBridgeErrorDomain, STBridgeErrorCode){
    STBridgeErrorCodeUnknown = 1,
    STBridgeErrorCodeCppException = 2,
    STBridgeErrorCodeBlackHoleMissing = 100,
    STBridgeErrorCodeMicrophonePermissionDenied = 101,
    STBridgeErrorCodeInputDeviceMissing = 102,
    STBridgeErrorCodeOutputDeviceMissing = 103,
    STBridgeErrorCodeUnsupportedSampleRate = 104,
    STBridgeErrorCodeUnsupportedBufferSize = 105,
    STBridgeErrorCodeAggregateDeviceCreationFailed = 106,
    STBridgeErrorCodeEngineStartFailed = 107,
    STBridgeErrorCodeEngineXRun = 108,
    STBridgeErrorCodeInvalidConfiguration = 109,
    STBridgeErrorCodeCallbackLayoutInvalid = 110,
    STBridgeErrorCodeInvalidPluginPath = 200,
    STBridgeErrorCodePluginSignatureRejected = 201,
    STBridgeErrorCodePluginScanFailed = 202,
    STBridgeErrorCodeInvalidPluginFolder = 203,
    STBridgeErrorCodePluginScannerUnavailable = 204,
};

@class STAudioEngineBridge;

@protocol STAudioEngineBridgeDelegate <NSObject>
- (void)audioEngineBridge:(STAudioEngineBridge*)bridge didChangeStatus:(STEngineStatus)status;
- (void)audioEngineBridge:(STAudioEngineBridge*)bridge didReceiveError:(NSError*)error;
- (void)audioEngineBridgeDidChangeDevices:(STAudioEngineBridge*)bridge;
@end

@interface STAudioEngineBridge : NSObject {
  @private
    void* _storage;
    NSTimer* _eventTimer;
}

@property(nonatomic, weak, nullable) id<STAudioEngineBridgeDelegate> delegate;
@property(nonatomic, readonly, copy) NSString* displayVersion;
@property(nonatomic, readonly) STEngineStatus status;

- (NSArray<STAudioDeviceInfo*>*)inputDevices;
- (NSArray<STAudioDeviceInfo*>*)outputDevices;
- (NSArray<STAudioDeviceInfo*>*)audioDevices;
- (BOOL)configureInputDeviceUID:(NSString*)inputUID
                   channelIndex:(NSInteger)channelIndex
                outputDeviceUID:(NSString*)outputUID
             blackHoleDeviceUID:(NSString*)blackHoleUID
                           mode:(STAudioRoutingMode)mode
       manualOutputChannelStart:(NSInteger)manualOutputChannelStart
                     sampleRate:(double)sampleRate
                   bufferFrames:(NSInteger)bufferFrames
                          error:(NSError* _Nullable* _Nullable)error;
- (BOOL)startWithError:(NSError* _Nullable* _Nullable)error;
- (void)stop;
- (void)setMasterMuted:(BOOL)muted;
- (STMeterSnapshot*)meterSnapshot;
- (STEngineDiagnostics*)diagnostics;

- (BOOL)exerciseExceptionForTesting:(NSError* _Nullable* _Nullable)error;

@end

NS_ASSUME_NONNULL_END
