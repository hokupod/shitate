// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#import "Public/STPluginBridge.h"

#include "Plugins/PluginCatalog.h"
#include "Plugins/PluginScanCoordinator.h"
#include "Plugins/PluginSignatureVerifier.h"
#import "Public/STAudioEngineBridge.h"
#import "STErrorMapper.h"

#import <Security/Security.h>
#include <climits>
#include <exception>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <sys/stat.h>
#include <vector>

namespace {

using namespace shitate::plugins;

struct PluginBridgeStorage final {
    std::shared_ptr<PluginSignatureVerifier> verifier{std::make_shared<PluginSignatureVerifier>()};
    PluginScanCoordinator coordinator{verifier};
    PluginCatalog catalog;
    std::mutex catalogMutex;
};

PluginBridgeStorage* storage(void* value) noexcept {
    return static_cast<PluginBridgeStorage*>(value);
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

STPluginSignatureKind signatureKind(SignatureKind kind) {
    switch (kind) {
    case SignatureKind::apple:
        return STPluginSignatureKindApple;
    case SignatureKind::developerID:
        return STPluginSignatureKindDeveloperID;
    case SignatureKind::adHoc:
        return STPluginSignatureKindAdHoc;
    case SignatureKind::unsignedCode:
        return STPluginSignatureKindUnsigned;
    case SignatureKind::invalid:
        return STPluginSignatureKindInvalid;
    }
    return STPluginSignatureKindInvalid;
}

STPluginSignatureDecision signatureDecision(SignaturePolicyDecision decision) {
    switch (decision) {
    case SignaturePolicyDecision::allow:
        return STPluginSignatureDecisionAllowed;
    case SignaturePolicyDecision::requireExplicitApproval:
        return STPluginSignatureDecisionRequiresApproval;
    case SignaturePolicyDecision::reject:
        return STPluginSignatureDecisionRejected;
    }
    return STPluginSignatureDecisionRejected;
}

STPluginCompatibility compatibility(PluginCompatibility value) {
    switch (value) {
    case PluginCompatibility::compatible:
        return STPluginCompatibilityCompatible;
    case PluginCompatibility::incompatible:
        return STPluginCompatibilityIncompatible;
    case PluginCompatibility::blocked:
        return STPluginCompatibilityBlocked;
    }
    return STPluginCompatibilityBlocked;
}

NSError* pluginError(STBridgeErrorCode code, NSString* message) {
    return STMakeBridgeError(code, message);
}

NSString* defaultScannerExecutablePath() {
    return [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Contents/Helpers/ShitatePluginScanner"];
}

bool validateStaticCode(NSURL* url, SecCSFlags flags, CFStringRef expectedIdentifier) {
    SecStaticCodeRef code = nullptr;
    if (SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &code) !=
            errSecSuccess ||
        code == nullptr) {
        return false;
    }

    const auto status = SecStaticCodeCheckValidityWithErrors(code, flags, nullptr, nullptr);
    if (status != errSecSuccess) {
        CFRelease(code);
        return false;
    }
    if (expectedIdentifier == nullptr) {
        CFRelease(code);
        return true;
    }

    CFDictionaryRef information = nullptr;
    const auto informationStatus =
        SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information);
    const auto* identifier = information != nullptr
                                 ? CFDictionaryGetValue(information, kSecCodeInfoIdentifier)
                                 : nullptr;
    const auto matches = informationStatus == errSecSuccess && identifier != nullptr &&
                         CFGetTypeID(identifier) == CFStringGetTypeID() &&
                         CFEqual(identifier, expectedIdentifier);
    if (information != nullptr) {
        CFRelease(information);
    }
    CFRelease(code);
    return matches;
}

bool validateEmbeddedScannerExecutable(NSString* scannerPath) {
    NSBundle* bundle = NSBundle.mainBundle;
    if (![bundle.bundleIdentifier isEqualToString:@"dev.hokupod.shitate"] ||
        ![scannerPath isEqualToString:defaultScannerExecutablePath()] ||
        ![scannerPath isEqualToString:[scannerPath stringByStandardizingPath]] ||
        ![scannerPath isEqualToString:[scannerPath stringByResolvingSymlinksInPath]] ||
        ![[NSFileManager defaultManager] isExecutableFileAtPath:scannerPath]) {
        return false;
    }

    struct stat status{};
    if (::lstat(scannerPath.fileSystemRepresentation, &status) != 0 || !S_ISREG(status.st_mode) ||
        S_ISLNK(status.st_mode)) {
        return false;
    }

    const auto strictFlags =
        static_cast<SecCSFlags>(kSecCSStrictValidate | kSecCSCheckAllArchitectures);
    const auto nestedFlags = static_cast<SecCSFlags>(strictFlags | kSecCSCheckNestedCode);
    return validateStaticCode(bundle.bundleURL, nestedFlags, CFSTR("dev.hokupod.shitate")) &&
           validateStaticCode([NSURL fileURLWithPath:scannerPath], strictFlags,
                              CFSTR("dev.hokupod.shitate.plugin-scanner"));
}

NSString* scanTimestamp() {
    NSISO8601DateFormatter* formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter stringFromDate:[NSDate date]];
}

} // namespace

@interface STPluginInspection ()
- (instancetype)initWithSignature:(const SignatureInfo&)signature
                         decision:(SignaturePolicyDecision)decision;
@end

@implementation STPluginInspection

- (instancetype)initWithSignature:(const SignatureInfo&)signature
                         decision:(SignaturePolicyDecision)decision {
    self = [super init];
    if (self != nil) {
        _canonicalPath = stringFromUTF8(signature.canonicalPath);
        _signingIdentifier = stringFromUTF8(signature.signingIdentifier);
        _teamIdentifier = stringFromUTF8(signature.teamIdentifier);
        _codeDirectoryHash = stringFromUTF8(signature.codeDirectoryHash);
        _signatureKind = signatureKind(signature.kind);
        _decision = signatureDecision(decision);
        _architectures = stringsFromUTF8(signature.architectures);
        _bundleVersion = stringFromUTF8(signature.bundleVersion);
        _bundleModificationTime = signature.modificationTime;
        _diagnosticCode = stringFromUTF8(signature.errorCode);
    }
    return self;
}

@end

@interface STPluginDescriptor ()
- (instancetype)initWithCatalogEntry:(const CatalogEntry&)entry;
@end

@implementation STPluginDescriptor

- (instancetype)initWithCatalogEntry:(const CatalogEntry&)entry {
    self = [super init];
    if (self != nil) {
        _fingerprint = stringFromUTF8(entry.fingerprint);
        _bundlePath = stringFromUTF8(entry.bundlePath);
        _classUID = stringFromUTF8(entry.classUID);
        _name = stringFromUTF8(entry.name);
        _manufacturer = stringFromUTF8(entry.manufacturer);
        _version = stringFromUTF8(entry.version);
        _codeDirectoryHash = stringFromUTF8(entry.codeDirectoryHash);
        _teamIdentifier = stringFromUTF8(entry.teamIdentifier);
        _signatureKind = signatureKind(entry.signatureKind);
        _architectures = stringsFromUTF8(entry.architectures);
        _inputChannels = entry.inputChannels;
        _outputChannels = entry.outputChannels;
        _latencySamples = entry.latencySamples;
        _hasEditor = entry.hasEditor;
        _compatibility = compatibility(entry.compatibility);
        _reason = entry.reason.has_value() ? stringFromUTF8(*entry.reason) : nil;
        _bundleModificationTime = entry.bundleModificationTime;
        _scannerProtocol = entry.scannerProtocol;
        _compatibleAppVersion = stringFromUTF8(entry.compatibleAppVersion);
        _lastScannedAt = stringFromUTF8(entry.lastScannedAt);
    }
    return self;
}

@end

@interface STPluginBridge ()
@property(atomic, readwrite) STPluginScanProgress scanProgress;
@end

@implementation STPluginBridge

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        try {
            _storage = new PluginBridgeStorage();
            static_cast<void>(storage(_storage)->coordinator.cleanupStaleTasks());
            _scannerExecutablePath = [defaultScannerExecutablePath() copy];
            _scanProgress = STPluginScanProgressIdle;
        } catch (...) {
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    delete storage(_storage);
    _storage = nullptr;
}

- (NSArray<NSString*>*)standardSearchPaths {
    NSString* userPath =
        [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Audio/Plug-Ins/VST3"];
    return @[ [userPath stringByStandardizingPath], @"/Library/Audio/Plug-Ins/VST3" ];
}

- (STPluginInspection*)inspectBundleAtPath:(NSString*)bundlePath error:(NSError**)error {
    self.scanProgress = STPluginScanProgressValidating;
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr || bundlePath.length == 0) {
            if (error != nullptr) {
                *error = pluginError(STBridgeErrorCodeInvalidPluginPath,
                                     @"The plug-in path is unavailable.");
            }
            self.scanProgress = STPluginScanProgressFailed;
            return nil;
        }
        const auto signature = bridgeStorage->verifier->inspect(stringToUTF8(bundlePath));
        const auto decision = evaluateSignaturePolicy(signature, false);
        self.scanProgress = decision == SignaturePolicyDecision::reject
                                ? STPluginScanProgressFailed
                                : STPluginScanProgressComplete;
        return [[STPluginInspection alloc] initWithSignature:signature decision:decision];
    } catch (const std::exception&) {
        if (error != nullptr) {
            *error =
                pluginError(STBridgeErrorCodeCppException, @"Plug-in inspection failed safely.");
        }
    } catch (...) {
        if (error != nullptr) {
            *error =
                pluginError(STBridgeErrorCodeCppException, @"Plug-in inspection failed safely.");
        }
    }
    self.scanProgress = STPluginScanProgressFailed;
    return nil;
}

- (NSArray<STPluginDescriptor*>*)rescanBundleAtPath:(NSString*)bundlePath
                          approvedAdHocFingerprints:(NSSet<NSString*>*)approvedFingerprints
                                              error:(NSError**)error {
    self.scanProgress = STPluginScanProgressValidating;
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr || bundlePath.length == 0) {
            if (error != nullptr) {
                *error = pluginError(STBridgeErrorCodeInvalidPluginPath,
                                     @"The plug-in path is unavailable.");
            }
            self.scanProgress = STPluginScanProgressFailed;
            return nil;
        }
        const auto signature = bridgeStorage->verifier->inspect(stringToUTF8(bundlePath));
        if (evaluateSignaturePolicy(signature, false) == SignaturePolicyDecision::reject) {
            if (error != nullptr) {
                *error = pluginError(STBridgeErrorCodePluginSignatureRejected,
                                     @"The plug-in signature or architecture was rejected.");
            }
            self.scanProgress = STPluginScanProgressFailed;
            return nil;
        }
        if (!validateEmbeddedScannerExecutable(_scannerExecutablePath)) {
            if (error != nullptr) {
                *error = pluginError(STBridgeErrorCodePluginScannerUnavailable,
                                     @"The isolated plug-in scanner is unavailable.");
            }
            self.scanProgress = STPluginScanProgressFailed;
            return nil;
        }

        self.scanProgress = STPluginScanProgressScanning;
        const auto outcome = bridgeStorage->coordinator.scan(stringToUTF8(_scannerExecutablePath),
                                                             stringToUTF8(bundlePath));
        if (outcome.kind != ScanOutcomeKind::success || !outcome.result.has_value()) {
            if (error != nullptr) {
                *error = pluginError(STBridgeErrorCodePluginScanFailed,
                                     @"The isolated plug-in scan did not produce a valid result.");
            }
            self.scanProgress = STPluginScanProgressFailed;
            return nil;
        }

        std::set<std::string> approvals;
        for (NSString* fingerprint in approvedFingerprints) {
            approvals.insert(stringToUTF8(fingerprint));
        }
        std::lock_guard lock(bridgeStorage->catalogMutex);
        if (!bridgeStorage->catalog.replaceBundle(*outcome.result, approvals,
                                                  stringToUTF8(scanTimestamp()))) {
            if (error != nullptr) {
                *error = pluginError(STBridgeErrorCodePluginScanFailed,
                                     @"The validated scan result could not enter the catalog.");
            }
            self.scanProgress = STPluginScanProgressFailed;
            return nil;
        }

        NSMutableArray<STPluginDescriptor*>* descriptors = [NSMutableArray array];
        for (const auto& entry : bridgeStorage->catalog.entries()) {
            if (entry.bundlePath == outcome.result->bundle.path) {
                [descriptors addObject:[[STPluginDescriptor alloc] initWithCatalogEntry:entry]];
            }
        }
        self.scanProgress = STPluginScanProgressComplete;
        return [descriptors copy];
    } catch (...) {
        if (error != nullptr) {
            *error = pluginError(STBridgeErrorCodeCppException,
                                 @"The isolated plug-in scan failed safely.");
        }
        self.scanProgress = STPluginScanProgressFailed;
        return nil;
    }
}

- (NSArray<STPluginDescriptor*>*)catalogDescriptors {
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr) {
            return @[];
        }
        std::lock_guard lock(bridgeStorage->catalogMutex);
        NSMutableArray<STPluginDescriptor*>* result = [NSMutableArray array];
        for (const auto& entry : bridgeStorage->catalog.entries()) {
            [result addObject:[[STPluginDescriptor alloc] initWithCatalogEntry:entry]];
        }
        return [result copy];
    } catch (...) {
        return @[];
    }
}

- (BOOL)hasValidCacheForBundlePath:(NSString*)bundlePath
                 codeDirectoryHash:(NSString*)codeDirectoryHash
                  modificationTime:(int64_t)modificationTime
                   protocolVersion:(NSInteger)protocolVersion
              compatibleAppVersion:(NSString*)compatibleAppVersion {
    if (protocolVersion < 0 || protocolVersion > INT_MAX) {
        return NO;
    }
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr) {
            return NO;
        }
        std::lock_guard lock(bridgeStorage->catalogMutex);
        return bridgeStorage->catalog.hasValidCache(
            stringToUTF8(bundlePath), stringToUTF8(codeDirectoryHash), modificationTime,
            static_cast<int>(protocolVersion), stringToUTF8(compatibleAppVersion));
    } catch (...) {
        return NO;
    }
}

- (void)removeCatalogEntriesNotAtPaths:(NSSet<NSString*>*)canonicalPaths {
    try {
        auto* bridgeStorage = storage(_storage);
        if (bridgeStorage == nullptr) {
            return;
        }
        std::set<std::string> paths;
        for (NSString* path in canonicalPaths) {
            paths.insert(stringToUTF8(path));
        }
        std::lock_guard lock(bridgeStorage->catalogMutex);
        bridgeStorage->catalog.removeStalePaths(paths);
    } catch (...) {
    }
}

- (NSArray<NSString*>*)validatedAdditionalFolders:(NSArray<NSString*>*)folders
                                            error:(NSError**)error {
    NSMutableOrderedSet<NSString*>* result = [NSMutableOrderedSet orderedSet];
    for (NSString* folder in folders) {
        if (![folder isAbsolutePath]) {
            if (error != nullptr) {
                *error = pluginError(STBridgeErrorCodeInvalidPluginFolder,
                                     @"Additional plug-in folders must use absolute paths.");
            }
            return nil;
        }
        NSString* canonical = [[folder stringByStandardizingPath] stringByResolvingSymlinksInPath];
        BOOL isDirectory = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:canonical isDirectory:&isDirectory] ||
            !isDirectory) {
            if (error != nullptr) {
                *error = pluginError(STBridgeErrorCodeInvalidPluginFolder,
                                     @"An additional plug-in folder is unavailable.");
            }
            return nil;
        }
        [result addObject:canonical];
    }
    return result.array;
}

@end
