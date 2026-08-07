// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, STEngineStatus) {
    STEngineStatusStopped = 0,
    STEngineStatusConfigured = 1,
    STEngineStatusStarting = 2,
    STEngineStatusRunning = 3,
    STEngineStatusMuted = 4,
    STEngineStatusStopping = 5,
    STEngineStatusBlocked = 6,
};

typedef NS_ENUM(NSInteger, STAudioRoutingMode) {
    STAudioRoutingModeAutomaticPrivateAggregate = 0,
    STAudioRoutingModeManualAggregate = 1,
};

@interface STAudioDeviceInfo : NSObject

@property(nonatomic, readonly, copy) NSString* uid;
@property(nonatomic, readonly, copy) NSString* displayName;
@property(nonatomic, readonly, copy) NSArray<NSString*>* inputChannelNames;
@property(nonatomic, readonly, copy) NSArray<NSString*>* outputChannelNames;
@property(nonatomic, readonly, copy) NSArray<NSNumber*>* sampleRates;
@property(nonatomic, readonly, copy) NSArray<NSNumber*>* allowedBufferFrames;
@property(nonatomic, readonly) NSInteger minimumBufferFrames;
@property(nonatomic, readonly) NSInteger maximumBufferFrames;
@property(nonatomic, readonly, getter=isAlive) BOOL alive;
@property(nonatomic, readonly, getter=isAggregate) BOOL aggregate;

- (instancetype)initWithUID:(NSString*)uid
                displayName:(NSString*)displayName
          inputChannelNames:(NSArray<NSString*>*)inputChannelNames
         outputChannelNames:(NSArray<NSString*>*)outputChannelNames
                sampleRates:(NSArray<NSNumber*>*)sampleRates
        allowedBufferFrames:(NSArray<NSNumber*>*)allowedBufferFrames
        minimumBufferFrames:(NSInteger)minimumBufferFrames
        maximumBufferFrames:(NSInteger)maximumBufferFrames
                      alive:(BOOL)alive
                  aggregate:(BOOL)aggregate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface STMeterSnapshot : NSObject

@property(nonatomic, readonly) float inputPeakDb;
@property(nonatomic, readonly) float inputRmsDb;
@property(nonatomic, readonly) float outputPeakDb;
@property(nonatomic, readonly) float outputRmsDb;
@property(nonatomic, readonly) BOOL inputClipping;
@property(nonatomic, readonly) BOOL outputClipping;
@property(nonatomic, readonly) BOOL inputSignalPresent;
@property(nonatomic, readonly) BOOL outputSignalPresent;

- (instancetype)initWithInputPeakDb:(float)inputPeakDb
                         inputRmsDb:(float)inputRmsDb
                       outputPeakDb:(float)outputPeakDb
                        outputRmsDb:(float)outputRmsDb
                      inputClipping:(BOOL)inputClipping
                     outputClipping:(BOOL)outputClipping
                 inputSignalPresent:(BOOL)inputSignalPresent
                outputSignalPresent:(BOOL)outputSignalPresent NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface STEngineDiagnostics : NSObject

@property(nonatomic, readonly) double sampleRate;
@property(nonatomic, readonly) NSInteger bufferFrames;
@property(nonatomic, readonly) NSInteger inputLatencySamples;
@property(nonatomic, readonly) NSInteger outputLatencySamples;
@property(nonatomic, readonly) NSInteger xrunCount;
@property(nonatomic, readonly) double callbackTimeEmaMicroseconds;

- (instancetype)initWithSampleRate:(double)sampleRate
                      bufferFrames:(NSInteger)bufferFrames
               inputLatencySamples:(NSInteger)inputLatencySamples
              outputLatencySamples:(NSInteger)outputLatencySamples
                         xrunCount:(NSInteger)xrunCount
       callbackTimeEmaMicroseconds:(double)callbackTimeEmaMicroseconds NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
