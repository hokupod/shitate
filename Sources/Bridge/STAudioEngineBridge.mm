// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#import "Public/STAudioEngineBridge.h"

#include "ApplicationCore.h"
#include "Audio/AudioBridgeController.h"
#import "STErrorMapper.h"

#include <climits>
#include <cmath>
#include <exception>
#include <string>
#include <vector>

namespace {

struct BridgeStorage final {
    shitate::AudioBridgeController controller;
};

BridgeStorage* storage(void* value) noexcept {
    return static_cast<BridgeStorage*>(value);
}

NSString* stringFromUTF8(const std::string& value) {
    NSString* result = [[NSString alloc] initWithBytes:value.data()
                                                length:value.size()
                                              encoding:NSUTF8StringEncoding];
    return result != nil ? result : @"";
}

std::string stringToUTF8(NSString* value) {
    const char* utf8 = value.UTF8String;
    return utf8 != nullptr ? std::string(utf8) : std::string{};
}

NSArray<NSString*>* stringsFromUTF8(const std::vector<std::string>& values) {
    NSMutableArray<NSString*>* result = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto& value : values) {
        [result addObject:stringFromUTF8(value)];
    }
    return [result copy];
}

NSArray<NSNumber*>* numbersFromDoubles(const std::vector<double>& values) {
    NSMutableArray<NSNumber*>* result = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto value : values) {
        [result addObject:@(value)];
    }
    return [result copy];
}

NSArray<NSNumber*>* numbersFromIntegers(const std::vector<int>& values) {
    NSMutableArray<NSNumber*>* result = [NSMutableArray arrayWithCapacity:values.size()];
    for (const auto value : values) {
        [result addObject:@(value)];
    }
    return [result copy];
}

STAudioDeviceInfo* deviceFromCpp(const shitate::AudioDeviceInfo& device) {
    return [[STAudioDeviceInfo alloc] initWithUID:stringFromUTF8(device.uid)
                                      displayName:stringFromUTF8(device.displayName)
                                inputChannelNames:stringsFromUTF8(device.inputChannelNames)
                               outputChannelNames:stringsFromUTF8(device.outputChannelNames)
                                      sampleRates:numbersFromDoubles(device.sampleRates)
                              allowedBufferFrames:numbersFromIntegers(device.allowedBufferFrames)
                              minimumBufferFrames:device.minimumBufferFrames
                              maximumBufferFrames:device.maximumBufferFrames
                                            alive:device.alive
                                        aggregate:device.aggregate];
}

NSArray<STAudioDeviceInfo*>* devicesFromCpp(const std::vector<shitate::AudioDeviceInfo>& devices,
                                            bool requireInput) {
    NSMutableArray<STAudioDeviceInfo*>* result = [NSMutableArray arrayWithCapacity:devices.size()];
    for (const auto& device : devices) {
        if ((requireInput && !device.hasInputs()) || (!requireInput && !device.hasOutputs())) {
            continue;
        }
        [result addObject:deviceFromCpp(device)];
    }
    return [result copy];
}

NSArray<STAudioDeviceInfo*>*
allDevicesFromCpp(const std::vector<shitate::AudioDeviceInfo>& devices) {
    NSMutableArray<STAudioDeviceInfo*>* result = [NSMutableArray arrayWithCapacity:devices.size()];
    for (const auto& device : devices) {
        [result addObject:deviceFromCpp(device)];
    }
    return [result copy];
}

NSError* errorFromResult(const shitate::AudioResult& result) {
    return STMakeAudioBridgeError(static_cast<NSInteger>(result.code),
                                  stringFromUTF8(result.message));
}

NSError* exceptionError(const std::exception& exception) {
    NSString* message = [NSString stringWithUTF8String:exception.what()];
    return STMakeBridgeError(STBridgeErrorCodeCppException,
                             message != nil ? message : @"Invalid C++ exception message");
}

} // namespace

@interface STAudioEngineBridge ()

- (void)startEventTimer;
- (void)drainCoreEvents:(NSTimer*)timer;

@end

@implementation STAudioEngineBridge

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        try {
            _storage = new BridgeStorage();
        } catch (...) {
            return nil;
        }

        if (NSThread.isMainThread) {
            [self startEventTimer];
        } else {
            __weak STAudioEngineBridge* weakSelf = self;
            dispatch_async(dispatch_get_main_queue(), ^{
              [weakSelf startEventTimer];
            });
        }
    }
    return self;
}

- (void)dealloc {
    NSTimer* timer = _eventTimer;
    BridgeStorage* bridgeStorage = storage(_storage);
    _eventTimer = nil;
    _storage = nullptr;
    void (^cleanup)(void) = ^{
      [timer invalidate];
      delete bridgeStorage;
    };
    if (NSThread.isMainThread) {
        cleanup();
    } else {
        dispatch_async(dispatch_get_main_queue(), cleanup);
    }
}

- (void)startEventTimer {
    if (_eventTimer != nil) {
        return;
    }
    __weak STAudioEngineBridge* weakSelf = self;
    _eventTimer = [NSTimer timerWithTimeInterval:0.05
                                         repeats:YES
                                           block:^(NSTimer* timer) {
                                             [weakSelf drainCoreEvents:timer];
                                           }];
    [[NSRunLoop mainRunLoop] addTimer:_eventTimer forMode:NSRunLoopCommonModes];
}

- (void)drainCoreEvents:(NSTimer*)timer {
    (void)timer;
    NSAssert(NSThread.isMainThread, @"Core events must be delivered on the main thread");
    auto* bridgeStorage = storage(_storage);
    if (bridgeStorage == nullptr) {
        return;
    }

    shitate::CoreEvent event;
    while (bridgeStorage->controller.popEvent(event)) {
        switch (event.type) {
        case shitate::CoreEventType::engineStateChanged:
            [self.delegate audioEngineBridge:self
                             didChangeStatus:static_cast<STEngineStatus>(event.value)];
            break;
        case shitate::CoreEventType::devicesChanged:
            [self.delegate audioEngineBridgeDidChangeDevices:self];
            break;
        case shitate::CoreEventType::xrunDetected:
            // Xruns remain visible in diagnostics without hiding an active Stop action.
            break;
        case shitate::CoreEventType::recoveryRequested:
        case shitate::CoreEventType::fatalError:
            bridgeStorage->controller.failClosed();
            [self.delegate
                audioEngineBridge:self
                  didReceiveError:STMakeAudioBridgeError(
                                      static_cast<NSInteger>(event.error),
                                      @"The audio engine requested fail-closed recovery.")];
            break;
        }
    }
}

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

- (STEngineStatus)status {
    auto* bridgeStorage = storage(_storage);
    return bridgeStorage != nullptr
               ? static_cast<STEngineStatus>(bridgeStorage->controller.status())
               : STEngineStatusBlocked;
}

- (NSArray<STAudioDeviceInfo*>*)inputDevices {
    try {
        auto* bridgeStorage = storage(_storage);
        return bridgeStorage != nullptr
                   ? devicesFromCpp(bridgeStorage->controller.enumerateDevices(), true)
                   : @[];
    } catch (...) {
        return @[];
    }
}

- (NSArray<STAudioDeviceInfo*>*)outputDevices {
    try {
        auto* bridgeStorage = storage(_storage);
        return bridgeStorage != nullptr
                   ? devicesFromCpp(bridgeStorage->controller.enumerateDevices(), false)
                   : @[];
    } catch (...) {
        return @[];
    }
}

- (NSArray<STAudioDeviceInfo*>*)audioDevices {
    try {
        auto* bridgeStorage = storage(_storage);
        return bridgeStorage != nullptr
                   ? allDevicesFromCpp(bridgeStorage->controller.enumerateDevices())
                   : @[];
    } catch (...) {
        return @[];
    }
}

- (BOOL)configureInputDeviceUID:(NSString*)inputUID
                   channelIndex:(NSInteger)channelIndex
                outputDeviceUID:(NSString*)outputUID
             blackHoleDeviceUID:(NSString*)blackHoleUID
                           mode:(STAudioRoutingMode)mode
       manualOutputChannelStart:(NSInteger)manualOutputChannelStart
                     sampleRate:(double)sampleRate
                   bufferFrames:(NSInteger)bufferFrames
                          error:(NSError**)error {
    if (channelIndex < 0 || channelIndex > INT_MAX || manualOutputChannelStart < 0 ||
        manualOutputChannelStart > INT_MAX || bufferFrames < 0 || bufferFrames > INT_MAX ||
        !std::isfinite(sampleRate)) {
        if (error != nullptr) {
            *error = STMakeAudioBridgeError(STBridgeErrorCodeInvalidConfiguration,
                                            @"A numeric configuration value is out of range.");
        }
        return NO;
    }

    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr) {
            if (error != nullptr) {
                *error = STMakeAudioBridgeError(STBridgeErrorCodeUnknown,
                                                @"The audio bridge is unavailable.");
            }
            return NO;
        }

        const shitate::AudioConfiguration configuration{
            .mode = static_cast<shitate::RoutingMode>(mode),
            .inputDeviceUID = stringToUTF8(inputUID),
            .outputDeviceUID = stringToUTF8(outputUID),
            .blackHoleDeviceUID = stringToUTF8(blackHoleUID),
            .inputChannelIndex = static_cast<int>(channelIndex),
            .manualOutputChannelStart = static_cast<int>(manualOutputChannelStart),
            .sampleRate = sampleRate,
            .bufferFrames = static_cast<int>(bufferFrames),
        };
        const auto result = bridgeStorage->controller.configure(configuration);
        if (!result.succeeded()) {
            if (error != nullptr) {
                *error = errorFromResult(result);
            }
            return NO;
        }
        return YES;
    } catch (const std::exception& exception) {
        if (error != nullptr) {
            *error = exceptionError(exception);
        }
        return NO;
    } catch (...) {
        if (error != nullptr) {
            *error = STMakeBridgeError(STBridgeErrorCodeUnknown, @"Unknown C++ exception");
        }
        return NO;
    }
}

- (BOOL)startWithError:(NSError**)error {
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr) {
            if (error != nullptr) {
                *error = STMakeAudioBridgeError(STBridgeErrorCodeUnknown,
                                                @"The audio bridge is unavailable.");
            }
            return NO;
        }
        const auto result = bridgeStorage->controller.start();
        if (!result.succeeded()) {
            if (error != nullptr) {
                *error = errorFromResult(result);
            }
            return NO;
        }
        return YES;
    } catch (const std::exception& exception) {
        if (error != nullptr) {
            *error = exceptionError(exception);
        }
        return NO;
    } catch (...) {
        if (error != nullptr) {
            *error = STMakeBridgeError(STBridgeErrorCodeUnknown, @"Unknown C++ exception");
        }
        return NO;
    }
}

- (void)stop {
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage != nullptr) {
            bridgeStorage->controller.stop();
        }
    } catch (...) {
    }
}

- (void)setMasterMuted:(BOOL)muted {
    auto* bridgeStorage = storage(_storage);
    if (bridgeStorage != nullptr) {
        bridgeStorage->controller.setMasterMuted(muted);
    }
}

- (STMeterSnapshot*)meterSnapshot {
    const auto* bridgeStorage = storage(_storage);
    const auto meters = bridgeStorage != nullptr ? bridgeStorage->controller.meterSnapshot()
                                                 : shitate::MeterSnapshot{};
    return [[STMeterSnapshot alloc] initWithInputPeakDb:meters.inputPeakDb
                                             inputRmsDb:meters.inputRmsDb
                                           outputPeakDb:meters.outputPeakDb
                                            outputRmsDb:meters.outputRmsDb
                                          inputClipping:meters.inputClipping
                                         outputClipping:meters.outputClipping
                                     inputSignalPresent:meters.inputSignalPresent
                                    outputSignalPresent:meters.outputSignalPresent];
}

- (STEngineDiagnostics*)diagnostics {
    const auto* bridgeStorage = storage(_storage);
    const auto values = bridgeStorage != nullptr ? bridgeStorage->controller.diagnostics()
                                                 : shitate::EngineDiagnostics{};
    return [[STEngineDiagnostics alloc] initWithSampleRate:values.sampleRate
                                              bufferFrames:values.bufferFrames
                                       inputLatencySamples:values.inputLatencySamples
                                      outputLatencySamples:values.outputLatencySamples
                                                 xrunCount:values.xrunCount
                               callbackTimeEmaMicroseconds:values.callbackTimeEmaMicroseconds];
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
