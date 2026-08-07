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
    STBridgeErrorCodePreviewOutputUnavailable = 111,
    STBridgeErrorCodePreviewOutputChanged = 112,
    STBridgeErrorCodeInvalidPluginPath = 200,
    STBridgeErrorCodePluginSignatureRejected = 201,
    STBridgeErrorCodePluginScanFailed = 202,
    STBridgeErrorCodeInvalidPluginFolder = 203,
    STBridgeErrorCodePluginScannerUnavailable = 204,
    STBridgeErrorCodeInvalidPluginDescriptor = 300,
    STBridgeErrorCodePluginIdentityChanged = 301,
    STBridgeErrorCodePluginJournalWriteFailed = 302,
    STBridgeErrorCodePluginInstanceCreationFailed = 303,
    STBridgeErrorCodePluginUnsupportedLayout = 304,
    STBridgeErrorCodePluginStateInvalid = 305,
    STBridgeErrorCodePluginPrepareFailed = 306,
    STBridgeErrorCodePluginChainFull = 307,
    STBridgeErrorCodeDuplicatePluginSlot = 308,
    STBridgeErrorCodePluginSlotNotFound = 309,
    STBridgeErrorCodePluginMutationRequiresStop = 310,
    STBridgeErrorCodeInvalidPluginMove = 311,
    STBridgeErrorCodePluginSessionIncomplete = 312,
    STBridgeErrorCodePluginEditorUnavailable = 313,
    STBridgeErrorCodePluginEditorThreadInvalid = 314,
    STBridgeErrorCodePluginMutationAppliedRestartFailed = 315,
};

@class STAudioEngineBridge;
@class STPluginDescriptor;
@class STPluginSlotInfo;

typedef void (^STPluginMutationCompletion)(NSError* _Nullable error);
typedef void (^STPluginStateCompletion)(NSData* _Nullable state, NSError* _Nullable error);

@protocol STAudioEngineBridgeDelegate <NSObject>
- (void)audioEngineBridge:(STAudioEngineBridge*)bridge didChangeStatus:(STEngineStatus)status;
- (void)audioEngineBridge:(STAudioEngineBridge*)bridge didReceiveError:(NSError*)error;
- (void)audioEngineBridgeDidChangeDevices:(STAudioEngineBridge*)bridge;
@optional
- (void)audioEngineBridge:(STAudioEngineBridge*)bridge didFaultPluginSlotWithID:(NSUUID*)slotID;
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
- (nullable STAudioDeviceInfo*)defaultOutputDevice;
- (BOOL)configureInputDeviceUID:(NSString*)inputUID
                   channelIndex:(NSInteger)channelIndex
                outputDeviceUID:(NSString*)outputUID
             blackHoleDeviceUID:(NSString*)blackHoleUID
                           mode:(STAudioRoutingMode)mode
       manualOutputChannelStart:(NSInteger)manualOutputChannelStart
                     sampleRate:(double)sampleRate
                   bufferFrames:(NSInteger)bufferFrames
                          error:(NSError* _Nullable* _Nullable)error;
- (BOOL)configureInputDeviceUID:(NSString*)inputUID
                   channelIndex:(NSInteger)channelIndex
                outputDeviceUID:(NSString*)outputUID
             blackHoleDeviceUID:(NSString*)blackHoleUID
                           mode:(STAudioRoutingMode)mode
                   outputTarget:(STAudioOutputTarget)outputTarget
       manualOutputChannelStart:(NSInteger)manualOutputChannelStart
                     sampleRate:(double)sampleRate
                   bufferFrames:(NSInteger)bufferFrames
                          error:(NSError* _Nullable* _Nullable)error;
- (BOOL)startWithError:(NSError* _Nullable* _Nullable)error;
- (void)stop;
- (void)setMasterMuted:(BOOL)muted;
- (STMeterSnapshot*)meterSnapshot;
- (STEngineDiagnostics*)diagnostics;

/// Synchronous plug-in runtime access must occur on the main thread.
- (BOOL)setPluginSlotWithID:(NSUUID*)slotID
                   bypassed:(BOOL)bypassed
                      error:(NSError* _Nullable* _Nullable)error;
- (BOOL)openEditorForPluginSlotWithID:(NSUUID*)slotID error:(NSError* _Nullable* _Nullable)error;
- (BOOL)closeEditorForPluginSlotWithID:(NSUUID*)slotID error:(NSError* _Nullable* _Nullable)error;
- (NSArray<STPluginSlotInfo*>*)pluginSlots;

- (void)addPluginDescriptor:(STPluginDescriptor*)descriptor
                     slotID:(NSUUID*)slotID
                      state:(nullable NSData*)state
                 completion:(STPluginMutationCompletion)completion;
- (void)removePluginSlotWithID:(NSUUID*)slotID completion:(STPluginMutationCompletion)completion;
- (void)movePluginSlotWithID:(NSUUID*)slotID
                     toIndex:(NSInteger)index
                  completion:(STPluginMutationCompletion)completion;
- (void)restoreState:(NSData*)state
    forPluginSlotWithID:(NSUUID*)slotID
             completion:(STPluginMutationCompletion)completion;
- (void)saveStateForPluginSlotWithID:(NSUUID*)slotID completion:(STPluginStateCompletion)completion;

- (BOOL)exerciseExceptionForTesting:(NSError* _Nullable* _Nullable)error;

@end

NS_ASSUME_NONNULL_END
