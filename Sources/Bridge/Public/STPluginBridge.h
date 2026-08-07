// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, STPluginSignatureKind) {
    STPluginSignatureKindApple = 0,
    STPluginSignatureKindDeveloperID = 1,
    STPluginSignatureKindAdHoc = 2,
    STPluginSignatureKindUnsigned = 3,
    STPluginSignatureKindInvalid = 4,
};

typedef NS_ENUM(NSInteger, STPluginSignatureDecision) {
    STPluginSignatureDecisionAllowed = 0,
    STPluginSignatureDecisionRequiresApproval = 1,
    STPluginSignatureDecisionRejected = 2,
};

typedef NS_ENUM(NSInteger, STPluginCompatibility) {
    STPluginCompatibilityCompatible = 0,
    STPluginCompatibilityIncompatible = 1,
    STPluginCompatibilityBlocked = 2,
};

typedef NS_ENUM(NSInteger, STPluginScanProgress) {
    STPluginScanProgressIdle = 0,
    STPluginScanProgressValidating = 1,
    STPluginScanProgressScanning = 2,
    STPluginScanProgressComplete = 3,
    STPluginScanProgressFailed = 4,
};

@interface STPluginInspection : NSObject

@property(nonatomic, readonly, copy) NSString* canonicalPath;
@property(nonatomic, readonly, copy) NSString* signingIdentifier;
@property(nonatomic, readonly, copy) NSString* teamIdentifier;
@property(nonatomic, readonly, copy) NSString* codeDirectoryHash;
@property(nonatomic, readonly) STPluginSignatureKind signatureKind;
@property(nonatomic, readonly) STPluginSignatureDecision decision;
@property(nonatomic, readonly, copy) NSArray<NSString*>* architectures;
@property(nonatomic, readonly, copy) NSString* bundleVersion;
@property(nonatomic, readonly) int64_t bundleModificationTime;
@property(nonatomic, readonly, copy) NSString* diagnosticCode;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface STPluginDescriptor : NSObject

@property(nonatomic, readonly, copy) NSString* fingerprint;
@property(nonatomic, readonly, copy) NSString* bundlePath;
@property(nonatomic, readonly, copy) NSString* classUID;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly, copy) NSString* manufacturer;
@property(nonatomic, readonly, copy) NSString* version;
@property(nonatomic, readonly, copy) NSString* codeDirectoryHash;
@property(nonatomic, readonly, copy) NSString* teamIdentifier;
@property(nonatomic, readonly) STPluginSignatureKind signatureKind;
@property(nonatomic, readonly, copy) NSArray<NSString*>* architectures;
@property(nonatomic, readonly) NSInteger inputChannels;
@property(nonatomic, readonly) NSInteger outputChannels;
@property(nonatomic, readonly) NSInteger latencySamples;
@property(nonatomic, readonly) BOOL hasEditor;
@property(nonatomic, readonly) STPluginCompatibility compatibility;
@property(nonatomic, readonly, copy, nullable) NSString* reason;
@property(nonatomic, readonly) int64_t bundleModificationTime;
@property(nonatomic, readonly) NSInteger scannerProtocol;
@property(nonatomic, readonly, copy) NSString* compatibleAppVersion;
@property(nonatomic, readonly, copy) NSString* lastScannedAt;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface STPluginSlotInfo : NSObject

@property(nonatomic, readonly, copy) NSUUID* slotID;
@property(nonatomic, readonly, copy) NSString* fingerprint;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly, copy) NSString* manufacturer;
@property(nonatomic, readonly, copy) NSString* version;
@property(nonatomic, readonly, getter=isBypassed) BOOL bypassed;
@property(nonatomic, readonly, getter=isFaulted) BOOL faulted;
@property(nonatomic, readonly) NSInteger latencySamples;
@property(nonatomic, readonly) BOOL hasEditor;

- (instancetype)init NS_UNAVAILABLE;

@end

@interface STPluginBridge : NSObject {
  @private
    void* _storage;
    NSString* _scannerExecutablePath;
}

@property(atomic, readonly) STPluginScanProgress scanProgress;
@property(nonatomic, readonly, copy) NSArray<NSString*>* standardSearchPaths;

- (instancetype)init NS_DESIGNATED_INITIALIZER;
- (nullable STPluginInspection*)inspectBundleAtPath:(NSString*)bundlePath
                                              error:(NSError* _Nullable* _Nullable)error;
- (nullable NSArray<STPluginDescriptor*>*)rescanBundleAtPath:(NSString*)bundlePath
                                   approvedAdHocFingerprints:
                                       (NSSet<NSString*>*)approvedAdHocFingerprints
                                                       error:(NSError* _Nullable* _Nullable)error;
- (NSArray<STPluginDescriptor*>*)catalogDescriptors;
- (BOOL)hasValidCacheForBundlePath:(NSString*)bundlePath
                 codeDirectoryHash:(NSString*)codeDirectoryHash
                  modificationTime:(int64_t)modificationTime
                   protocolVersion:(NSInteger)protocolVersion
              compatibleAppVersion:(NSString*)compatibleAppVersion;
- (void)removeCatalogEntriesNotAtPaths:(NSSet<NSString*>*)canonicalPaths;
- (nullable NSArray<NSString*>*)validatedAdditionalFolders:(NSArray<NSString*>*)folders
                                                     error:(NSError* _Nullable* _Nullable)error;

@end

NS_ASSUME_NONNULL_END
