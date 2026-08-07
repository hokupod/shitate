// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#import "Public/STAudioEngineBridge.h"

#include "ApplicationCore.h"
#include "Audio/AudioBridgeController.h"
#include "Plugins/PluginLoadJournal.h"
#import "Public/STPluginBridge.h"
#import "STErrorMapper.h"

#include <array>
#include <climits>
#include <cmath>
#include <exception>
#include <memory>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <vector>

namespace {

struct BridgeStorage final {
    explicit BridgeStorage(std::string journalPath)
        : controller(
              std::make_shared<shitate::plugins::FilePluginLoadJournal>(std::move(journalPath))) {}

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

NSString* pluginJournalPath() {
    NSURL* applicationSupport =
        [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                               inDomains:NSUserDomainMask]
            .firstObject;
    NSURL* directory = [applicationSupport URLByAppendingPathComponent:@"dev.hokupod.shitate"
                                                           isDirectory:YES];
    NSDictionary<NSFileAttributeKey, id>* attributes = @{NSFilePosixPermissions : @(0700)};
    if (![[NSFileManager defaultManager] createDirectoryAtURL:directory
                                  withIntermediateDirectories:YES
                                                   attributes:attributes
                                                        error:nil]) {
        return @"";
    }
    struct stat directoryStatus{};
    if (::lstat(directory.fileSystemRepresentation, &directoryStatus) != 0 ||
        !S_ISDIR(directoryStatus.st_mode) || directoryStatus.st_uid != ::getuid() ||
        ::chmod(directory.fileSystemRepresentation, 0700) != 0) {
        return @"";
    }
    return [[directory URLByAppendingPathComponent:@"plugin-load-journal.json"] path];
}

shitate::plugins::SlotId slotIDFromUUID(NSUUID* value) {
    std::array<std::uint8_t, shitate::plugins::SlotId::byteCount> bytes{};
    [value getUUIDBytes:bytes.data()];
    return shitate::plugins::SlotId(bytes);
}

NSUUID* uuidFromSlotID(const shitate::plugins::SlotId& value) {
    return [[NSUUID alloc] initWithUUIDBytes:value.bytes().data()];
}

shitate::plugins::SignatureKind signatureKindFromBridge(STPluginSignatureKind value) {
    switch (value) {
    case STPluginSignatureKindApple:
        return shitate::plugins::SignatureKind::apple;
    case STPluginSignatureKindDeveloperID:
        return shitate::plugins::SignatureKind::developerID;
    case STPluginSignatureKindAdHoc:
        return shitate::plugins::SignatureKind::adHoc;
    case STPluginSignatureKindUnsigned:
        return shitate::plugins::SignatureKind::unsignedCode;
    case STPluginSignatureKindInvalid:
        return shitate::plugins::SignatureKind::invalid;
    }
    return shitate::plugins::SignatureKind::invalid;
}

shitate::plugins::PluginCompatibility compatibilityFromBridge(STPluginCompatibility value) {
    switch (value) {
    case STPluginCompatibilityCompatible:
        return shitate::plugins::PluginCompatibility::compatible;
    case STPluginCompatibilityIncompatible:
        return shitate::plugins::PluginCompatibility::incompatible;
    case STPluginCompatibilityBlocked:
        return shitate::plugins::PluginCompatibility::blocked;
    }
    return shitate::plugins::PluginCompatibility::blocked;
}

shitate::plugins::CatalogEntry catalogEntryFromDescriptor(STPluginDescriptor* descriptor) {
    shitate::plugins::CatalogEntry entry;
    entry.fingerprint = stringToUTF8(descriptor.fingerprint);
    entry.bundlePath = stringToUTF8(descriptor.bundlePath);
    entry.classUID = stringToUTF8(descriptor.classUID);
    entry.name = stringToUTF8(descriptor.name);
    entry.manufacturer = stringToUTF8(descriptor.manufacturer);
    entry.version = stringToUTF8(descriptor.version);
    entry.codeDirectoryHash = stringToUTF8(descriptor.codeDirectoryHash);
    entry.teamIdentifier = stringToUTF8(descriptor.teamIdentifier);
    entry.signatureKind = signatureKindFromBridge(descriptor.signatureKind);
    for (NSString* architecture in descriptor.architectures) {
        entry.architectures.push_back(stringToUTF8(architecture));
    }
    entry.inputChannels = static_cast<int>(descriptor.inputChannels);
    entry.outputChannels = static_cast<int>(descriptor.outputChannels);
    entry.latencySamples = static_cast<int>(descriptor.latencySamples);
    entry.hasEditor = descriptor.hasEditor;
    entry.compatibility = compatibilityFromBridge(descriptor.compatibility);
    if (descriptor.reason != nil) {
        entry.reason = stringToUTF8(descriptor.reason);
    }
    entry.bundleModificationTime = descriptor.bundleModificationTime;
    entry.scannerProtocol = static_cast<int>(descriptor.scannerProtocol);
    entry.compatibleAppVersion = stringToUTF8(descriptor.compatibleAppVersion);
    entry.lastScannedAt = stringToUTF8(descriptor.lastScannedAt);
    return entry;
}

NSError* errorFromPluginResult(const shitate::plugins::PluginRuntimeResult& result) {
    return STMakeBridgeError(static_cast<STBridgeErrorCode>(result.error),
                             stringFromUTF8(result.message));
}

BOOL applyPluginResult(const shitate::plugins::PluginRuntimeResult& result, NSError** error) {
    if (result.succeeded()) {
        return YES;
    }
    if (error != nullptr) {
        *error = errorFromPluginResult(result);
    }
    return NO;
}

BOOL requirePluginMainThread(NSError** error) {
    if (NSThread.isMainThread) {
        return YES;
    }
    if (error != nullptr) {
        *error = STMakeBridgeError(STBridgeErrorCodePluginEditorThreadInvalid,
                                   @"Plug-in runtime access requires the main thread.");
    }
    return NO;
}

shitate::plugins::PluginRuntimeResult
capturePluginStates(shitate::AudioBridgeController& controller) {
    for (const auto& snapshot : controller.pluginSlots()) {
        const auto state = controller.serializePluginState(snapshot.slotID);
        if (!state.result.succeeded()) {
            return state.result;
        }
    }
    return shitate::plugins::PluginRuntimeResult::success();
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

@property(nonatomic, copy, nullable) dispatch_block_t pendingPluginOperation;
@property(nonatomic, strong) NSMutableSet<NSUUID*>* deliveredFaultSlots;

- (void)startEventTimer;
- (void)drainCoreEvents:(NSTimer*)timer;
- (void)deliverFaultedPluginSlots;
- (void)servicePendingPluginOperation;
- (void)performPluginOperation:(BOOL (^)(NSError** error))operation
                    completion:(STPluginMutationCompletion)completion;
- (BOOL)addPluginDescriptor:(STPluginDescriptor*)descriptor
                     slotID:(NSUUID*)slotID
                      state:(nullable NSData*)state
                      error:(NSError**)error;
- (BOOL)removePluginSlotWithID:(NSUUID*)slotID error:(NSError**)error;
- (BOOL)movePluginSlotWithID:(NSUUID*)slotID toIndex:(NSInteger)index error:(NSError**)error;
- (nullable NSData*)stateForPluginSlotWithID:(NSUUID*)slotID error:(NSError**)error;
- (BOOL)restoreState:(NSData*)state forPluginSlotWithID:(NSUUID*)slotID error:(NSError**)error;

@end

@interface STPluginSlotInfo ()

- (instancetype)initWithSnapshot:(const shitate::PluginSlotSnapshot&)snapshot;

@end

@implementation STPluginSlotInfo

- (instancetype)initWithSnapshot:(const shitate::PluginSlotSnapshot&)snapshot {
    self = [super init];
    if (self != nil) {
        _slotID = uuidFromSlotID(snapshot.slotID);
        _fingerprint = stringFromUTF8(snapshot.identity.fingerprint);
        _name = stringFromUTF8(snapshot.identity.name);
        _manufacturer = stringFromUTF8(snapshot.identity.manufacturer);
        _version = stringFromUTF8(snapshot.identity.version);
        _bypassed = snapshot.bypassed;
        _faulted = snapshot.faulted;
        _latencySamples = snapshot.latencySamples;
        _hasEditor = snapshot.identity.hasEditor;
    }
    return self;
}

@end

@implementation STAudioEngineBridge

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        try {
            _storage = new BridgeStorage(stringToUTF8(pluginJournalPath()));
        } catch (...) {
            return nil;
        }
        _deliveredFaultSlots = [NSMutableSet set];

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
        case shitate::CoreEventType::pluginSlotFaulted:
            // This is an invalidation signal. The bounded queue may coalesce identities.
            break;
        }
    }
    [self deliverFaultedPluginSlots];
    [self servicePendingPluginOperation];
}

- (void)deliverFaultedPluginSlots {
    NSAssert(NSThread.isMainThread, @"Plug-in faults must be delivered on the main thread");
    const auto* bridgeStorage = storage(_storage);
    if (bridgeStorage == nullptr) {
        return;
    }

    NSMutableSet<NSUUID*>* currentlyFaulted = [NSMutableSet set];
    const BOOL canDeliver = [self.delegate respondsToSelector:@selector(audioEngineBridge:
                                                                  didFaultPluginSlotWithID:)];
    for (const auto& snapshot : bridgeStorage->controller.pluginSlots()) {
        if (!snapshot.faulted) {
            continue;
        }
        NSUUID* slotID = uuidFromSlotID(snapshot.slotID);
        [currentlyFaulted addObject:slotID];
        if (canDeliver && ![self.deliveredFaultSlots containsObject:slotID]) {
            [self.delegate audioEngineBridge:self didFaultPluginSlotWithID:slotID];
            [self.deliveredFaultSlots addObject:slotID];
        }
    }
    [self.deliveredFaultSlots intersectSet:currentlyFaulted];
}

- (void)servicePendingPluginOperation {
    if (self.pendingPluginOperation == nil) {
        return;
    }
    const auto currentStatus = self.status;
    if (currentStatus == STEngineStatusStarting || currentStatus == STEngineStatusRunning ||
        currentStatus == STEngineStatusMuted || currentStatus == STEngineStatusStopping) {
        return;
    }
    dispatch_block_t operation = self.pendingPluginOperation;
    self.pendingPluginOperation = nil;
    operation();
}

- (void)performPluginOperation:(BOOL (^)(NSError** error))operation
                    completion:(STPluginMutationCompletion)completion {
    if (!NSThread.isMainThread) {
        __weak STAudioEngineBridge* weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
          [weakSelf performPluginOperation:operation completion:completion];
        });
        return;
    }
    if (operation == nil || completion == nil) {
        return;
    }
    if (self.pendingPluginOperation != nil || self.status == STEngineStatusStarting) {
        completion(STMakeBridgeError(STBridgeErrorCodePluginMutationRequiresStop,
                                     @"Another plug-in operation is already in progress."));
        return;
    }

    const BOOL restart = self.status == STEngineStatusRunning || self.status == STEngineStatusMuted;
    __weak STAudioEngineBridge* weakSelf = self;
    dispatch_block_t execute = ^{
      STAudioEngineBridge* strongSelf = weakSelf;
      if (strongSelf == nil) {
          completion(
              STMakeBridgeError(STBridgeErrorCodeUnknown, @"The audio bridge became unavailable."));
          return;
      }
      NSError* operationError = nil;
      BOOL succeeded = operation(&operationError);
      if (succeeded && restart) {
          NSError* restartError = nil;
          if (![strongSelf startWithError:&restartError]) {
              succeeded = NO;
              operationError = STMakeBridgeError(
                  STBridgeErrorCodePluginMutationAppliedRestartFailed,
                  @"The plug-in change was applied, but audio routing could not restart. Output "
                   "remains stopped.");
          }
      }
      // Design section 12.3: a failed operation intentionally leaves routing stopped.
      if (!succeeded && operationError == nil) {
          operationError =
              STMakeBridgeError(STBridgeErrorCodeUnknown, @"The plug-in operation failed safely.");
      }
      completion(succeeded ? nil : operationError);
    };

    if (restart || self.status == STEngineStatusStopping) {
        self.pendingPluginOperation = execute;
        if (restart) {
            [self stop];
        }
        return;
    }
    self.pendingPluginOperation = execute;
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf servicePendingPluginOperation];
    });
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
                                      pluginLatencySamples:values.pluginLatencySamples
                                   aggregateLatencySamples:values.aggregateLatencySamples
                                                 xrunCount:values.xrunCount
                               callbackTimeEmaMicroseconds:values.callbackTimeEmaMicroseconds];
}

- (BOOL)addPluginDescriptor:(STPluginDescriptor*)descriptor
                     slotID:(NSUUID*)slotID
                      state:(NSData*)state
                      error:(NSError**)error {
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr || descriptor == nil || slotID == nil) {
            if (error != nullptr) {
                *error = STMakeBridgeError(STBridgeErrorCodeInvalidPluginDescriptor,
                                           @"The plug-in runtime request is invalid.");
            }
            return NO;
        }
        return applyPluginResult(
            bridgeStorage->controller.addPlugin(catalogEntryFromDescriptor(descriptor),
                                                slotIDFromUUID(slotID), state.bytes, state.length),
            error);
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

- (BOOL)removePluginSlotWithID:(NSUUID*)slotID error:(NSError**)error {
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr || slotID == nil) {
            if (error != nullptr) {
                *error = STMakeBridgeError(STBridgeErrorCodePluginSlotNotFound,
                                           @"The plug-in slot is unavailable.");
            }
            return NO;
        }
        return applyPluginResult(bridgeStorage->controller.removePlugin(slotIDFromUUID(slotID)),
                                 error);
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

- (BOOL)movePluginSlotWithID:(NSUUID*)slotID toIndex:(NSInteger)index error:(NSError**)error {
    if (index < 0) {
        if (error != nullptr) {
            *error = STMakeBridgeError(STBridgeErrorCodeInvalidPluginMove,
                                       @"The destination slot index is invalid.");
        }
        return NO;
    }
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr || slotID == nil) {
            if (error != nullptr) {
                *error = STMakeBridgeError(STBridgeErrorCodePluginSlotNotFound,
                                           @"The plug-in slot is unavailable.");
            }
            return NO;
        }
        return applyPluginResult(bridgeStorage->controller.movePlugin(
                                     slotIDFromUUID(slotID), static_cast<std::size_t>(index)),
                                 error);
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

- (BOOL)setPluginSlotWithID:(NSUUID*)slotID bypassed:(BOOL)bypassed error:(NSError**)error {
    if (!requirePluginMainThread(error)) {
        return NO;
    }
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr || slotID == nil) {
            if (error != nullptr) {
                *error = STMakeBridgeError(STBridgeErrorCodePluginSlotNotFound,
                                           @"The plug-in slot is unavailable.");
            }
            return NO;
        }
        return applyPluginResult(
            bridgeStorage->controller.setPluginBypassed(slotIDFromUUID(slotID), bypassed), error);
    } catch (...) {
        if (error != nullptr) {
            *error = STMakeBridgeError(STBridgeErrorCodeUnknown,
                                       @"The plug-in bypass state could not be changed.");
        }
        return NO;
    }
}

- (NSData*)stateForPluginSlotWithID:(NSUUID*)slotID error:(NSError**)error {
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr || slotID == nil) {
            if (error != nullptr) {
                *error = STMakeBridgeError(STBridgeErrorCodePluginSlotNotFound,
                                           @"The plug-in slot is unavailable.");
            }
            return nil;
        }
        const auto state = bridgeStorage->controller.serializePluginState(slotIDFromUUID(slotID));
        if (!state.result.succeeded()) {
            if (error != nullptr) {
                *error = errorFromPluginResult(state.result);
            }
            return nil;
        }
        return [NSData dataWithBytes:state.data.data() length:state.data.size()];
    } catch (const std::exception& exception) {
        if (error != nullptr) {
            *error = exceptionError(exception);
        }
        return nil;
    } catch (...) {
        if (error != nullptr) {
            *error = STMakeBridgeError(STBridgeErrorCodeUnknown, @"Unknown C++ exception");
        }
        return nil;
    }
}

- (BOOL)restoreState:(NSData*)state forPluginSlotWithID:(NSUUID*)slotID error:(NSError**)error {
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr || slotID == nil || state == nil) {
            if (error != nullptr) {
                *error = STMakeBridgeError(STBridgeErrorCodePluginStateInvalid,
                                           @"The plug-in state is invalid.");
            }
            return NO;
        }
        return applyPluginResult(bridgeStorage->controller.restorePluginState(
                                     slotIDFromUUID(slotID), state.bytes, state.length),
                                 error);
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

- (BOOL)openEditorForPluginSlotWithID:(NSUUID*)slotID error:(NSError**)error {
    if (!requirePluginMainThread(error)) {
        return NO;
    }
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr || slotID == nil) {
            if (error != nullptr) {
                *error = STMakeBridgeError(STBridgeErrorCodePluginSlotNotFound,
                                           @"The plug-in slot is unavailable.");
            }
            return NO;
        }
        return applyPluginResult(bridgeStorage->controller.openPluginEditor(slotIDFromUUID(slotID)),
                                 error);
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

- (BOOL)closeEditorForPluginSlotWithID:(NSUUID*)slotID error:(NSError**)error {
    if (!requirePluginMainThread(error)) {
        return NO;
    }
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr || slotID == nil) {
            if (error != nullptr) {
                *error = STMakeBridgeError(STBridgeErrorCodePluginSlotNotFound,
                                           @"The plug-in slot is unavailable.");
            }
            return NO;
        }
        return applyPluginResult(
            bridgeStorage->controller.closePluginEditor(slotIDFromUUID(slotID)), error);
    } catch (...) {
        if (error != nullptr) {
            *error = STMakeBridgeError(STBridgeErrorCodeUnknown,
                                       @"The plug-in editor could not be closed.");
        }
        return NO;
    }
}

- (NSArray<STPluginSlotInfo*>*)pluginSlots {
    if (!NSThread.isMainThread) {
        return @[];
    }
    try {
        const auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr) {
            return @[];
        }
        const auto snapshots = bridgeStorage->controller.pluginSlots();
        NSMutableArray<STPluginSlotInfo*>* result =
            [NSMutableArray arrayWithCapacity:snapshots.size()];
        for (const auto& snapshot : snapshots) {
            [result addObject:[[STPluginSlotInfo alloc] initWithSnapshot:snapshot]];
        }
        return [result copy];
    } catch (...) {
        return @[];
    }
}

- (void)addPluginDescriptor:(STPluginDescriptor*)descriptor
                     slotID:(NSUUID*)slotID
                      state:(NSData*)state
                 completion:(STPluginMutationCompletion)completion {
    __weak STAudioEngineBridge* weakSelf = self;
    [self
        performPluginOperation:^BOOL(NSError** operationError) {
          STAudioEngineBridge* strongSelf = weakSelf;
          auto* bridgeStorage = strongSelf != nil ? storage(strongSelf->_storage) : nullptr;
          if (bridgeStorage == nullptr) {
              if (operationError != nullptr) {
                  *operationError = STMakeBridgeError(STBridgeErrorCodeUnknown,
                                                      @"The audio bridge is unavailable.");
              }
              return NO;
          }
          if (descriptor == nil || slotID == nil) {
              if (operationError != nullptr) {
                  *operationError = STMakeBridgeError(STBridgeErrorCodeInvalidPluginDescriptor,
                                                      @"The plug-in runtime request is invalid.");
              }
              return NO;
          }
          if (!applyPluginResult(
                  bridgeStorage->controller.validatePluginAdd(slotIDFromUUID(slotID)),
                  operationError)) {
              return NO;
          }
          if (!applyPluginResult(capturePluginStates(bridgeStorage->controller), operationError)) {
              return NO;
          }
          return [strongSelf addPluginDescriptor:descriptor
                                          slotID:slotID
                                           state:state
                                           error:operationError];
        }
                    completion:completion];
}

- (void)removePluginSlotWithID:(NSUUID*)slotID completion:(STPluginMutationCompletion)completion {
    __weak STAudioEngineBridge* weakSelf = self;
    [self
        performPluginOperation:^BOOL(NSError** operationError) {
          STAudioEngineBridge* strongSelf = weakSelf;
          auto* bridgeStorage = strongSelf != nil ? storage(strongSelf->_storage) : nullptr;
          if (bridgeStorage == nullptr) {
              if (operationError != nullptr) {
                  *operationError = STMakeBridgeError(STBridgeErrorCodeUnknown,
                                                      @"The audio bridge is unavailable.");
              }
              return NO;
          }
          if (!applyPluginResult(capturePluginStates(bridgeStorage->controller), operationError)) {
              return NO;
          }
          return [strongSelf removePluginSlotWithID:slotID error:operationError];
        }
                    completion:completion];
}

- (void)movePluginSlotWithID:(NSUUID*)slotID
                     toIndex:(NSInteger)index
                  completion:(STPluginMutationCompletion)completion {
    __weak STAudioEngineBridge* weakSelf = self;
    [self
        performPluginOperation:^BOOL(NSError** operationError) {
          STAudioEngineBridge* strongSelf = weakSelf;
          auto* bridgeStorage = strongSelf != nil ? storage(strongSelf->_storage) : nullptr;
          if (bridgeStorage == nullptr) {
              if (operationError != nullptr) {
                  *operationError = STMakeBridgeError(STBridgeErrorCodeUnknown,
                                                      @"The audio bridge is unavailable.");
              }
              return NO;
          }
          if (!applyPluginResult(capturePluginStates(bridgeStorage->controller), operationError)) {
              return NO;
          }
          return [strongSelf movePluginSlotWithID:slotID toIndex:index error:operationError];
        }
                    completion:completion];
}

- (void)restoreState:(NSData*)state
    forPluginSlotWithID:(NSUUID*)slotID
             completion:(STPluginMutationCompletion)completion {
    __weak STAudioEngineBridge* weakSelf = self;
    [self
        performPluginOperation:^BOOL(NSError** operationError) {
          STAudioEngineBridge* strongSelf = weakSelf;
          if (strongSelf == nil) {
              if (operationError != nullptr) {
                  *operationError = STMakeBridgeError(STBridgeErrorCodeUnknown,
                                                      @"The audio bridge is unavailable.");
              }
              return NO;
          }
          return [strongSelf restoreState:state forPluginSlotWithID:slotID error:operationError];
        }
                    completion:completion];
}

- (void)saveStateForPluginSlotWithID:(NSUUID*)slotID
                          completion:(STPluginStateCompletion)completion {
    if (completion == nil) {
        return;
    }
    __block NSData* savedState = nil;
    __weak STAudioEngineBridge* weakSelf = self;
    [self
        performPluginOperation:^BOOL(NSError** operationError) {
          STAudioEngineBridge* strongSelf = weakSelf;
          if (strongSelf == nil) {
              if (operationError != nullptr) {
                  *operationError = STMakeBridgeError(STBridgeErrorCodeUnknown,
                                                      @"The audio bridge is unavailable.");
              }
              return NO;
          }
          savedState = [strongSelf stateForPluginSlotWithID:slotID error:operationError];
          return savedState != nil;
        }
        completion:^(NSError* operationError) {
          completion(operationError == nil ? savedState : nil, operationError);
        }];
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
