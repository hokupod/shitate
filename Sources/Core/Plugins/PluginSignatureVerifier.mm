// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "PluginSignatureVerifier.h"

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#include <algorithm>
#include <filesystem>
#include <iomanip>
#include <mach/machine.h>
#include <sstream>
#include <sys/stat.h>
#include <utility>

namespace shitate::plugins {
namespace {

[[nodiscard]] std::string stringValue(CFTypeRef value) {
    if (value == nullptr || CFGetTypeID(value) != CFStringGetTypeID()) {
        return {};
    }

    const auto string = static_cast<CFStringRef>(value);
    const auto length = CFStringGetLength(string);
    const auto maximum = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    std::string result(static_cast<std::size_t>(maximum), '\0');
    if (!CFStringGetCString(string, result.data(), maximum, kCFStringEncodingUTF8)) {
        return {};
    }
    result.resize(std::char_traits<char>::length(result.c_str()));
    return result;
}

[[nodiscard]] std::string hexValue(CFTypeRef value) {
    if (value == nullptr || CFGetTypeID(value) != CFDataGetTypeID()) {
        return {};
    }

    const auto data = static_cast<CFDataRef>(value);
    const auto* bytes = CFDataGetBytePtr(data);
    const auto length = CFDataGetLength(data);
    std::ostringstream output;
    output << std::hex << std::setfill('0');
    for (CFIndex index = 0; index < length; ++index) {
        output << std::setw(2) << static_cast<unsigned int>(bytes[index]);
    }
    return output.str();
}

[[nodiscard]] std::uint32_t numberValue(CFTypeRef value) {
    if (value == nullptr || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return 0;
    }
    std::uint32_t result = 0;
    CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberSInt32Type, &result);
    return result;
}

[[nodiscard]] std::string dictionaryString(CFDictionaryRef dictionary, CFStringRef key) {
    return stringValue(CFDictionaryGetValue(dictionary, key));
}

[[nodiscard]] bool satisfiesRequirement(SecStaticCodeRef code, CFStringRef requirementText) {
    SecRequirementRef requirement = nullptr;
    if (SecRequirementCreateWithString(requirementText, kSecCSDefaultFlags, &requirement) !=
            errSecSuccess ||
        requirement == nullptr) {
        return false;
    }

    const auto status = SecStaticCodeCheckValidityWithErrors(
        code, kSecCSStrictValidate | kSecCSCheckAllArchitectures, requirement, nullptr);
    CFRelease(requirement);
    return status == errSecSuccess;
}

[[nodiscard]] std::vector<std::string> bundleArchitectures(const std::string& path) {
    std::vector<std::string> result;
    @autoreleasepool {
        NSString* bundlePath = [NSString stringWithUTF8String:path.c_str()];
        NSBundle* bundle = [NSBundle bundleWithPath:bundlePath];
        for (NSNumber* architecture in bundle.executableArchitectures) {
            const auto cpuType = static_cast<cpu_type_t>(architecture.intValue);
            if (cpuType == CPU_TYPE_ARM64) {
                result.emplace_back("arm64");
            } else if (cpuType == CPU_TYPE_X86_64) {
                result.emplace_back("x86_64");
            }
        }
    }
    std::sort(result.begin(), result.end());
    result.erase(std::unique(result.begin(), result.end()), result.end());
    return result;
}

[[nodiscard]] std::int64_t modificationTime(const std::string& path) {
    struct stat status{};
    if (::stat(path.c_str(), &status) != 0) {
        return 0;
    }
    return static_cast<std::int64_t>(status.st_mtimespec.tv_sec) * 1'000'000'000LL +
           status.st_mtimespec.tv_nsec;
}

[[nodiscard]] std::string bundleVersion(CFDictionaryRef information) {
    const auto value = CFDictionaryGetValue(information, kSecCodeInfoPList);
    if (value == nullptr || CFGetTypeID(value) != CFDictionaryGetTypeID()) {
        return {};
    }
    const auto plist = static_cast<CFDictionaryRef>(value);
    if (const auto version = dictionaryString(plist, CFSTR("CFBundleShortVersionString"));
        !version.empty()) {
        return version;
    }
    return dictionaryString(plist, kCFBundleVersionKey);
}

[[nodiscard]] SignatureInfo failure(SignatureKind kind, std::string canonicalPath,
                                    std::string errorCode) {
    SignatureInfo info;
    info.kind = kind;
    info.canonicalPath = std::move(canonicalPath);
    info.errorCode = std::move(errorCode);
    return info;
}

} // namespace

SignatureInfo PluginSignatureVerifier::inspect(const std::string& bundlePath) const noexcept {
    try {
        std::error_code fileError;
        const auto canonical = std::filesystem::canonical(bundlePath, fileError);
        if (fileError || !std::filesystem::is_directory(canonical, fileError) ||
            canonical.extension() != ".vst3") {
            return failure(SignatureKind::invalid, {}, "invalidCanonicalBundle");
        }
        const auto canonicalPath = canonical.string();

        const auto* bytes = reinterpret_cast<const UInt8*>(canonicalPath.data());
        CFURLRef url = CFURLCreateFromFileSystemRepresentation(
            kCFAllocatorDefault, bytes, static_cast<CFIndex>(canonicalPath.size()), true);
        if (url == nullptr) {
            return failure(SignatureKind::invalid, canonicalPath, "securityURLFailed");
        }

        SecStaticCodeRef code = nullptr;
        const auto createStatus = SecStaticCodeCreateWithPath(url, kSecCSDefaultFlags, &code);
        CFRelease(url);
        if (createStatus != errSecSuccess || code == nullptr) {
            return failure(createStatus == errSecCSUnsigned ? SignatureKind::unsignedCode
                                                            : SignatureKind::invalid,
                           canonicalPath,
                           createStatus == errSecCSUnsigned ? "unsignedCode"
                                                            : "staticCodeCreationFailed");
        }

        CFDictionaryRef information = nullptr;
        const auto informationStatus =
            SecCodeCopySigningInformation(code, kSecCSSigningInformation, &information);
        if (informationStatus != errSecSuccess || information == nullptr) {
            CFRelease(code);
            return failure(informationStatus == errSecCSUnsigned ? SignatureKind::unsignedCode
                                                                 : SignatureKind::invalid,
                           canonicalPath,
                           informationStatus == errSecCSUnsigned ? "unsignedCode"
                                                                 : "signingInformationFailed");
        }

        SignatureInfo info;
        info.canonicalPath = canonicalPath;
        info.signingIdentifier = dictionaryString(information, kSecCodeInfoIdentifier);
        info.teamIdentifier = dictionaryString(information, kSecCodeInfoTeamIdentifier);
        info.codeDirectoryHash = hexValue(CFDictionaryGetValue(information, kSecCodeInfoUnique));
        info.flags = numberValue(CFDictionaryGetValue(information, kSecCodeInfoFlags));
        info.architectures = bundleArchitectures(canonicalPath);
        info.bundleVersion = bundleVersion(information);
        info.modificationTime = modificationTime(canonicalPath);

        if (info.codeDirectoryHash.empty() || info.signingIdentifier.empty()) {
            info.kind = SignatureKind::unsignedCode;
            info.errorCode = "unsignedCode";
            CFRelease(information);
            CFRelease(code);
            return info;
        }

        CFErrorRef validationError = nullptr;
        const auto validityStatus = SecStaticCodeCheckValidityWithErrors(
            code, kSecCSStrictValidate | kSecCSCheckAllArchitectures, nullptr, &validationError);
        if (validationError != nullptr) {
            CFRelease(validationError);
        }
        if (validityStatus != errSecSuccess) {
            info.kind = validityStatus == errSecCSUnsigned ? SignatureKind::unsignedCode
                                                           : SignatureKind::invalid;
            info.errorCode =
                validityStatus == errSecCSUnsigned ? "unsignedCode" : "invalidSignature";
            CFRelease(information);
            CFRelease(code);
            return info;
        }

        if ((info.flags & kSecCodeSignatureAdhoc) != 0U) {
            info.kind = SignatureKind::adHoc;
        } else if (satisfiesRequirement(
                       code, CFSTR("anchor apple generic and "
                                   "certificate 1[field.1.2.840.113635.100.6.2.6] exists and "
                                   "certificate leaf[field.1.2.840.113635.100.6.1.13] exists"))) {
            info.kind = SignatureKind::developerID;
        } else if (satisfiesRequirement(code, CFSTR("anchor apple"))) {
            info.kind = SignatureKind::apple;
        } else {
            info.kind = SignatureKind::invalid;
            info.errorCode = "untrustedSigningAnchor";
        }
        if (info.architectures.empty()) {
            info.kind = SignatureKind::invalid;
            info.errorCode = "architectureUnavailable";
        }

        CFRelease(information);
        CFRelease(code);
        return info;
    } catch (...) {
        return failure(SignatureKind::invalid, {}, "signatureInspectionException");
    }
}

SignaturePolicyDecision evaluateSignaturePolicy(const SignatureInfo& info,
                                                bool fingerprintApproved) {
    if (!supportsRequiredArchitecture(info)) {
        return SignaturePolicyDecision::reject;
    }
    switch (info.kind) {
    case SignatureKind::apple:
    case SignatureKind::developerID:
        return SignaturePolicyDecision::allow;
    case SignatureKind::adHoc:
        return fingerprintApproved ? SignaturePolicyDecision::allow
                                   : SignaturePolicyDecision::requireExplicitApproval;
    case SignatureKind::unsignedCode:
    case SignatureKind::invalid:
        return SignaturePolicyDecision::reject;
    }
    return SignaturePolicyDecision::reject;
}

bool supportsRequiredArchitecture(const SignatureInfo& info) {
    return std::find(info.architectures.begin(), info.architectures.end(), "arm64") !=
           info.architectures.end();
}

} // namespace shitate::plugins
