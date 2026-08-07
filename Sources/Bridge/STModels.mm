// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#import "Public/STModels.h"

@implementation STAudioDeviceInfo

- (instancetype)initWithUID:(NSString*)uid
                displayName:(NSString*)displayName
          inputChannelNames:(NSArray<NSString*>*)inputChannelNames
         outputChannelNames:(NSArray<NSString*>*)outputChannelNames
                sampleRates:(NSArray<NSNumber*>*)sampleRates
        allowedBufferFrames:(NSArray<NSNumber*>*)allowedBufferFrames
        minimumBufferFrames:(NSInteger)minimumBufferFrames
        maximumBufferFrames:(NSInteger)maximumBufferFrames
                      alive:(BOOL)alive
                  aggregate:(BOOL)aggregate {
    return [self initWithUID:uid
                 displayName:displayName
           inputChannelNames:inputChannelNames
          outputChannelNames:outputChannelNames
                 sampleRates:sampleRates
         allowedBufferFrames:allowedBufferFrames
         minimumBufferFrames:minimumBufferFrames
         maximumBufferFrames:maximumBufferFrames
                       alive:alive
                   aggregate:aggregate
                    physical:NO];
}

- (instancetype)initWithUID:(NSString*)uid
                displayName:(NSString*)displayName
          inputChannelNames:(NSArray<NSString*>*)inputChannelNames
         outputChannelNames:(NSArray<NSString*>*)outputChannelNames
                sampleRates:(NSArray<NSNumber*>*)sampleRates
        allowedBufferFrames:(NSArray<NSNumber*>*)allowedBufferFrames
        minimumBufferFrames:(NSInteger)minimumBufferFrames
        maximumBufferFrames:(NSInteger)maximumBufferFrames
                      alive:(BOOL)alive
                  aggregate:(BOOL)aggregate
                   physical:(BOOL)physical {
    self = [super init];
    if (self != nil) {
        _uid = [uid copy];
        _displayName = [displayName copy];
        _inputChannelNames = [inputChannelNames copy];
        _outputChannelNames = [outputChannelNames copy];
        _sampleRates = [sampleRates copy];
        _allowedBufferFrames = [allowedBufferFrames copy];
        _minimumBufferFrames = minimumBufferFrames;
        _maximumBufferFrames = maximumBufferFrames;
        _alive = alive;
        _aggregate = aggregate;
        _physical = physical;
    }
    return self;
}

@end

@implementation STMeterSnapshot

- (instancetype)initWithInputPeakDb:(float)inputPeakDb
                         inputRmsDb:(float)inputRmsDb
                       outputPeakDb:(float)outputPeakDb
                        outputRmsDb:(float)outputRmsDb
                      inputClipping:(BOOL)inputClipping
                     outputClipping:(BOOL)outputClipping
                 inputSignalPresent:(BOOL)inputSignalPresent
                outputSignalPresent:(BOOL)outputSignalPresent {
    self = [super init];
    if (self != nil) {
        _inputPeakDb = inputPeakDb;
        _inputRmsDb = inputRmsDb;
        _outputPeakDb = outputPeakDb;
        _outputRmsDb = outputRmsDb;
        _inputClipping = inputClipping;
        _outputClipping = outputClipping;
        _inputSignalPresent = inputSignalPresent;
        _outputSignalPresent = outputSignalPresent;
    }
    return self;
}

@end

@implementation STEngineDiagnostics

- (instancetype)initWithSampleRate:(double)sampleRate
                      bufferFrames:(NSInteger)bufferFrames
               inputLatencySamples:(NSInteger)inputLatencySamples
              outputLatencySamples:(NSInteger)outputLatencySamples
              pluginLatencySamples:(NSInteger)pluginLatencySamples
           aggregateLatencySamples:(NSInteger)aggregateLatencySamples
                         xrunCount:(NSInteger)xrunCount
       callbackTimeEmaMicroseconds:(double)callbackTimeEmaMicroseconds {
    self = [super init];
    if (self != nil) {
        _sampleRate = sampleRate;
        _bufferFrames = bufferFrames;
        _inputLatencySamples = inputLatencySamples;
        _outputLatencySamples = outputLatencySamples;
        _pluginLatencySamples = pluginLatencySamples;
        _aggregateLatencySamples = aggregateLatencySamples;
        _xrunCount = xrunCount;
        _callbackTimeEmaMicroseconds = callbackTimeEmaMicroseconds;
    }
    return self;
}

@end
