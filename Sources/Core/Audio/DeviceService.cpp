// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "DeviceService.h"

#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <unistd.h>
#include <utility>

#if !defined(JUCE_COREAUDIO_LOGGING_ENABLED) || JUCE_COREAUDIO_LOGGING_ENABLED != 0
#error "Shipped Shi-tate configurations require private JUCE CoreAudio aggregate devices"
#endif

namespace shitate {
namespace {

constexpr std::string_view blackHoleName = "BlackHole 2ch";
constexpr std::string_view juceAggregatePrefix = "_JucePrivateAggregateDevice_";

AudioObjectPropertyAddress
address(AudioObjectPropertySelector selector,
        AudioObjectPropertyScope scope = kAudioObjectPropertyScopeGlobal,
        AudioObjectPropertyElement element = kAudioObjectPropertyElementMain) {
    return {selector, scope, element};
}

template <typename Value>
std::optional<Value> scalarProperty(AudioObjectID object, AudioObjectPropertyAddress property) {
    if (!AudioObjectHasProperty(object, &property)) {
        return std::nullopt;
    }

    Value value{};
    auto size = static_cast<UInt32>(sizeof(value));
    if (AudioObjectGetPropertyData(object, &property, 0, nullptr, &size, &value) != noErr ||
        size != sizeof(value)) {
        return std::nullopt;
    }
    return value;
}

template <typename Value>
std::vector<Value> arrayProperty(AudioObjectID object, AudioObjectPropertyAddress property) {
    UInt32 size = 0;
    if (!AudioObjectHasProperty(object, &property) ||
        AudioObjectGetPropertyDataSize(object, &property, 0, nullptr, &size) != noErr ||
        size == 0 || size % sizeof(Value) != 0) {
        return {};
    }

    std::vector<Value> values(size / sizeof(Value));
    if (AudioObjectGetPropertyData(object, &property, 0, nullptr, &size, values.data()) != noErr) {
        return {};
    }
    return values;
}

std::string stringFromCFString(CFStringRef value) {
    if (value == nullptr) {
        return {};
    }

    const auto length = CFStringGetLength(value);
    const auto maximum = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    std::string result(static_cast<std::size_t>(maximum), '\0');
    if (!CFStringGetCString(value, result.data(), maximum, kCFStringEncodingUTF8)) {
        return {};
    }
    result.resize(std::char_traits<char>::length(result.c_str()));
    return result;
}

std::string stringProperty(AudioObjectID object, AudioObjectPropertyAddress property) {
    auto value = scalarProperty<CFStringRef>(object, property);
    if (!value.has_value() || *value == nullptr) {
        return {};
    }

    const auto result = stringFromCFString(*value);
    CFRelease(*value);
    return result;
}

int channelCount(AudioObjectID device, AudioObjectPropertyScope scope) {
    auto property = address(kAudioDevicePropertyStreamConfiguration, scope);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &property, 0, nullptr, &size) != noErr ||
        size == 0) {
        return 0;
    }

    std::vector<std::byte> storage(size);
    auto* buffers = reinterpret_cast<AudioBufferList*>(storage.data());
    if (AudioObjectGetPropertyData(device, &property, 0, nullptr, &size, buffers) != noErr) {
        return 0;
    }

    auto channels = 0;
    for (UInt32 index = 0; index < buffers->mNumberBuffers; ++index) {
        channels += static_cast<int>(buffers->mBuffers[index].mNumberChannels);
    }
    return channels;
}

std::vector<std::string> channelNames(AudioObjectID device, AudioObjectPropertyScope scope,
                                      std::string_view fallbackPrefix) {
    const auto count = channelCount(device, scope);
    std::vector<std::string> names;
    names.reserve(static_cast<std::size_t>(count));

    for (auto index = 0; index < count; ++index) {
        auto name = stringProperty(device, address(kAudioObjectPropertyElementName, scope,
                                                   static_cast<UInt32>(index + 1)));
        if (name.empty()) {
            name = std::string(fallbackPrefix) + " " + std::to_string(index + 1);
        }
        names.push_back(std::move(name));
    }
    return names;
}

std::vector<double> sampleRates(AudioObjectID device) {
    const auto ranges = arrayProperty<AudioValueRange>(
        device, address(kAudioDevicePropertyAvailableNominalSampleRates));
    constexpr std::array commonRates{44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0};
    std::set<double> rates;

    for (const auto& range : ranges) {
        if (range.mMinimum > 0.0 && range.mMinimum == range.mMaximum) {
            rates.insert(range.mMinimum);
        }
        for (const auto rate : commonRates) {
            if (rate >= range.mMinimum && rate <= range.mMaximum) {
                rates.insert(rate);
            }
        }
    }
    return {rates.begin(), rates.end()};
}

bool contains(const std::vector<double>& values, double expected) {
    return std::any_of(values.begin(), values.end(),
                       [expected](double value) { return std::abs(value - expected) < 0.5; });
}

bool contains(const std::vector<int>& values, int expected) {
    return std::find(values.begin(), values.end(), expected) != values.end();
}

std::vector<int> supportedBufferFrames(int minimum, int maximum) {
    std::vector<int> values;
    for (const auto candidate : {128, 256, 512}) {
        if (candidate >= minimum && candidate <= maximum) {
            values.push_back(candidate);
        }
    }
    return values;
}

std::vector<AudioObjectID> systemAudioDevices() {
    return arrayProperty<AudioObjectID>(kAudioObjectSystemObject,
                                        address(kAudioHardwarePropertyDevices));
}

std::optional<std::string> systemDefaultOutputDeviceUID() {
    const auto device = scalarProperty<AudioObjectID>(
        kAudioObjectSystemObject, address(kAudioHardwarePropertyDefaultOutputDevice));
    if (!device.has_value() || *device == kAudioObjectUnknown) {
        return std::nullopt;
    }
    auto uid = stringProperty(*device, address(kAudioDevicePropertyDeviceUID));
    if (uid.empty()) {
        return std::nullopt;
    }
    return uid;
}

std::optional<AudioObjectID> audioDeviceForUID(std::string_view uid) {
    const auto uidString =
        CFStringCreateWithBytes(kCFAllocatorDefault, reinterpret_cast<const UInt8*>(uid.data()),
                                static_cast<CFIndex>(uid.size()), kCFStringEncodingUTF8, false);
    if (uidString == nullptr) {
        return std::nullopt;
    }

    auto property = address(kAudioHardwarePropertyTranslateUIDToDevice);
    auto device = AudioObjectID{kAudioObjectUnknown};
    auto size = static_cast<UInt32>(sizeof(device));
    const CFStringRef qualifier = uidString;
    const auto status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &property,
                                                   static_cast<UInt32>(sizeof(uidString)),
                                                   &qualifier, &size, &device);
    CFRelease(uidString);
    if (status != noErr || size != sizeof(device) || device == kAudioObjectUnknown) {
        return std::nullopt;
    }
    return device;
}

bool isAggregate(AudioObjectID device) {
    return scalarProperty<AudioClassID>(device, address(kAudioObjectPropertyClass)) ==
           kAudioAggregateDeviceClassID;
}

bool hasPhysicalTransport(AudioObjectID device) {
    const auto transport =
        scalarProperty<UInt32>(device, address(kAudioDevicePropertyTransportType));
    if (!transport.has_value()) {
        return false;
    }

    switch (*transport) {
    case kAudioDeviceTransportTypeBuiltIn:
    case kAudioDeviceTransportTypePCI:
    case kAudioDeviceTransportTypeUSB:
    case kAudioDeviceTransportTypeFireWire:
    case kAudioDeviceTransportTypeBluetooth:
    case kAudioDeviceTransportTypeBluetoothLE:
    case kAudioDeviceTransportTypeHDMI:
    case kAudioDeviceTransportTypeDisplayPort:
    case kAudioDeviceTransportTypeThunderbolt:
        return true;
    default:
        return false;
    }
}

std::optional<AudioObjectID> activePrivateAggregateDevice() {
    const auto expectedName = std::string(juceAggregatePrefix) + std::to_string(getpid());
    std::optional<AudioObjectID> match;
    for (const auto device : systemAudioDevices()) {
        if (isAggregate(device) &&
            stringProperty(device, address(kAudioDevicePropertyDeviceNameCFString)) ==
                expectedName) {
            if (match.has_value()) {
                return std::nullopt;
            }
            match = device;
        }
    }
    return match;
}

std::vector<AudioDeviceInfo> discoverDevices(juce::AudioIODeviceType& type) {
    type.scanForDevices();
    const auto inputBackendNames = type.getDeviceNames(true);
    const auto outputBackendNames = type.getDeviceNames(false);
    juce::StringArray expectedInputBackendNames;
    juce::StringArray expectedOutputBackendNames;
    std::vector<std::size_t> inputDeviceIndices;
    std::vector<std::size_t> outputDeviceIndices;
    std::vector<AudioDeviceInfo> devices;

    for (const auto device : systemAudioDevices()) {
        auto name = stringProperty(device, address(kAudioDevicePropertyDeviceNameCFString));
        if (name.starts_with(juceAggregatePrefix)) {
            continue;
        }

        const auto inputs = channelNames(device, kAudioDevicePropertyScopeInput, "Input");
        const auto outputs = channelNames(device, kAudioDevicePropertyScopeOutput, "Output");
        if (inputs.empty() && outputs.empty()) {
            continue;
        }

        const auto range = scalarProperty<AudioValueRange>(
            device, address(kAudioDevicePropertyBufferFrameSizeRange));
        const auto minimum = range.has_value() ? static_cast<int>(std::ceil(range->mMinimum)) : 0;
        const auto maximum = range.has_value() ? static_cast<int>(std::floor(range->mMaximum)) : 0;
        const auto deviceIndex = devices.size();
        AudioDeviceInfo info{
            .uid = stringProperty(device, address(kAudioDevicePropertyDeviceUID)),
            .displayName = name,
            .inputChannelNames = inputs,
            .outputChannelNames = outputs,
            .sampleRates = sampleRates(device),
            .allowedBufferFrames = supportedBufferFrames(minimum, maximum),
            .minimumBufferFrames = minimum,
            .maximumBufferFrames = maximum,
            .alive = scalarProperty<UInt32>(device, address(kAudioDevicePropertyDeviceIsAlive))
                         .value_or(0) != 0,
            .aggregate = isAggregate(device),
            .physical = hasPhysicalTransport(device),
        };

        if (!inputs.empty()) {
            expectedInputBackendNames.add(name);
            inputDeviceIndices.push_back(deviceIndex);
        }
        if (!outputs.empty()) {
            expectedOutputBackendNames.add(name);
            outputDeviceIndices.push_back(deviceIndex);
        }
        devices.push_back(std::move(info));
    }

    expectedInputBackendNames.appendNumbersToDuplicates(false, true);
    expectedOutputBackendNames.appendNumbersToDuplicates(false, true);
    const auto namesMatch = [](const juce::StringArray& expected, const juce::StringArray& actual) {
        if (expected.size() != actual.size()) {
            return false;
        }
        for (auto index = 0; index < expected.size(); ++index) {
            if (expected[index] != actual[index]) {
                return false;
            }
        }
        return true;
    };

    if (namesMatch(expectedInputBackendNames, inputBackendNames)) {
        for (auto index = std::size_t{0}; index < inputDeviceIndices.size(); ++index) {
            devices[inputDeviceIndices[index]].backendInputName =
                inputBackendNames[static_cast<int>(index)].toStdString();
        }
    }
    if (namesMatch(expectedOutputBackendNames, outputBackendNames)) {
        for (auto index = std::size_t{0}; index < outputDeviceIndices.size(); ++index) {
            devices[outputDeviceIndices[index]].backendOutputName =
                outputBackendNames[static_cast<int>(index)].toStdString();
        }
    }

    return devices;
}

std::optional<CFTypeRef> cfProperty(AudioObjectID object, AudioObjectPropertyAddress property) {
    auto value = scalarProperty<CFTypeRef>(object, property);
    if (!value.has_value() || *value == nullptr) {
        return std::nullopt;
    }
    return value;
}

bool numberIsTrue(CFTypeRef value) {
    if (value == nullptr || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return false;
    }
    int number = 0;
    return CFNumberGetValue(static_cast<CFNumberRef>(value), kCFNumberIntType, &number) &&
           number != 0;
}

struct CompositionDetails {
    bool privateDevice = false;
    std::string clockDeviceUID;
    std::vector<std::string> orderedSubdeviceUIDs;
    std::map<std::string, bool> driftCompensationByUID;
};

CompositionDetails compositionDetails(CFDictionaryRef composition) {
    CompositionDetails details;
    details.privateDevice =
        numberIsTrue(CFDictionaryGetValue(composition, CFSTR(kAudioAggregateDeviceIsPrivateKey)));

    const auto clock =
        CFDictionaryGetValue(composition, CFSTR(kAudioAggregateDeviceClockDeviceKey));
    if (clock != nullptr && CFGetTypeID(clock) == CFStringGetTypeID()) {
        details.clockDeviceUID = stringFromCFString(static_cast<CFStringRef>(clock));
    }

    const auto subdevices =
        CFDictionaryGetValue(composition, CFSTR(kAudioAggregateDeviceSubDeviceListKey));
    if (subdevices == nullptr || CFGetTypeID(subdevices) != CFArrayGetTypeID()) {
        return details;
    }

    const auto array = static_cast<CFArrayRef>(subdevices);
    for (CFIndex index = 0; index < CFArrayGetCount(array); ++index) {
        const auto item = CFArrayGetValueAtIndex(array, index);
        if (item == nullptr || CFGetTypeID(item) != CFDictionaryGetTypeID()) {
            continue;
        }
        const auto dictionary = static_cast<CFDictionaryRef>(item);
        const auto uidValue = CFDictionaryGetValue(dictionary, CFSTR(kAudioSubDeviceUIDKey));
        if (uidValue == nullptr || CFGetTypeID(uidValue) != CFStringGetTypeID()) {
            continue;
        }
        auto uid = stringFromCFString(static_cast<CFStringRef>(uidValue));
        details.orderedSubdeviceUIDs.push_back(uid);
        details.driftCompensationByUID[std::move(uid)] = numberIsTrue(
            CFDictionaryGetValue(dictionary, CFSTR(kAudioSubDeviceDriftCompensationKey)));
    }
    return details;
}

AggregateEvidence evidenceFromComposition(CFDictionaryRef composition,
                                          std::string_view expectedInputUID,
                                          std::string_view expectedOutputUID,
                                          const std::vector<std::string>& expectedSubdevices) {
    AggregateEvidence evidence{.aggregateFound = true};
    const auto details = compositionDetails(composition);
    evidence.privateDevice = details.privateDevice;
    evidence.outputOwnsClock = details.clockDeviceUID == expectedOutputUID;
    evidence.inputPresent =
        std::find(details.orderedSubdeviceUIDs.begin(), details.orderedSubdeviceUIDs.end(),
                  expectedInputUID) != details.orderedSubdeviceUIDs.end();
    evidence.outputPresent =
        std::find(details.orderedSubdeviceUIDs.begin(), details.orderedSubdeviceUIDs.end(),
                  expectedOutputUID) != details.orderedSubdeviceUIDs.end();
    if (expectedInputUID == expectedOutputUID) {
        evidence.inputDriftCompensated = true;
    } else if (const auto found =
                   details.driftCompensationByUID.find(std::string(expectedInputUID));
               found != details.driftCompensationByUID.end()) {
        evidence.inputDriftCompensated = found->second;
    }
    evidence.subdevicesMatch = details.orderedSubdeviceUIDs == expectedSubdevices;
    return evidence;
}

ManualAggregateEvidence manualEvidence(const AudioConfiguration& configuration) {
    ManualAggregateEvidence evidence;
    const auto aggregateDevice = audioDeviceForUID(configuration.inputDeviceUID);
    if (!aggregateDevice.has_value() || !isAggregate(*aggregateDevice)) {
        return evidence;
    }

    auto composition =
        cfProperty(*aggregateDevice, address(kAudioAggregateDevicePropertyComposition));
    if (!composition.has_value() || CFGetTypeID(*composition) != CFDictionaryGetTypeID()) {
        if (composition.has_value()) {
            CFRelease(*composition);
        }
        return evidence;
    }

    evidence.aggregateFound = true;
    const auto details = compositionDetails(static_cast<CFDictionaryRef>(*composition));
    CFRelease(*composition);
    evidence.orderedSubdeviceUIDs = details.orderedSubdeviceUIDs;
    evidence.outputOwnsClock = details.clockDeviceUID == configuration.blackHoleDeviceUID;

    auto aggregateInputOffset = 0;
    auto aggregateOutputOffset = 0;
    auto blackHoleCount = 0;
    for (const auto& uid : details.orderedSubdeviceUIDs) {
        const auto device = audioDeviceForUID(uid);
        if (!device.has_value()) {
            continue;
        }
        const auto inputChannels = channelCount(*device, kAudioDevicePropertyScopeInput);
        const auto outputChannels = channelCount(*device, kAudioDevicePropertyScopeOutput);
        const auto isBlackHole =
            uid == configuration.blackHoleDeviceUID &&
            stringProperty(*device, address(kAudioDevicePropertyDeviceNameCFString)) ==
                blackHoleName;
        if (isBlackHole) {
            ++blackHoleCount;
        }

        if (configuration.inputChannelIndex >= aggregateInputOffset &&
            configuration.inputChannelIndex < aggregateInputOffset + inputChannels) {
            evidence.selectedInputSubdeviceUID = uid;
            evidence.selectedInputIsPhysical = !isBlackHole && !isAggregate(*device);
            if (const auto found = details.driftCompensationByUID.find(uid);
                found != details.driftCompensationByUID.end()) {
                evidence.inputDriftCompensated = found->second;
            }
        }

        if (configuration.manualOutputChannelStart >= aggregateOutputOffset &&
            configuration.manualOutputChannelStart + 1 < aggregateOutputOffset + outputChannels) {
            evidence.outputChannelsOwnedByBlackHole = isBlackHole;
        }

        aggregateInputOffset += inputChannels;
        aggregateOutputOffset += outputChannels;
    }
    evidence.blackHolePresent = blackHoleCount == 1;
    return evidence;
}

} // namespace

DeviceService::DeviceService(RealtimeEventQueue& eventQueue) : eventQueue_(eventQueue) {
    jassert(juce::MessageManager::getInstanceWithoutCreating() != nullptr);
    coreAudioType_ = coreAudioType();
    if (coreAudioType_ != nullptr) {
        coreAudioType_->addListener(this);
    }
    auto property = address(kAudioHardwarePropertyDefaultOutputDevice);
    defaultOutputListenerInstalled_ =
        AudioObjectAddPropertyListener(kAudioObjectSystemObject, &property,
                                       &DeviceService::defaultOutputPropertyChanged, this) == noErr;
}

DeviceService::~DeviceService() {
    if (defaultOutputListenerInstalled_) {
        auto property = address(kAudioHardwarePropertyDefaultOutputDevice);
        (void)AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &property,
                                                &DeviceService::defaultOutputPropertyChanged, this);
        defaultOutputListenerInstalled_ = false;
    }
    if (coreAudioType_ != nullptr) {
        coreAudioType_->removeListener(this);
    }
    close();
}

juce::AudioIODeviceType* DeviceService::coreAudioType() noexcept {
    for (auto* type : deviceManager_.getAvailableDeviceTypes()) {
        if (type != nullptr && type->getTypeName() == "CoreAudio") {
            return type;
        }
    }
    return nullptr;
}

std::vector<AudioDeviceInfo> DeviceService::enumerateDevices() {
    if (coreAudioType_ == nullptr) {
        return {};
    }
    return discoverDevices(*coreAudioType_);
}

std::optional<AudioDeviceInfo> DeviceService::defaultOutputDevice() {
    const auto uid = systemDefaultOutputDeviceUID();
    if (!uid.has_value()) {
        return std::nullopt;
    }
    const auto devices = enumerateDevices();
    const auto* device = findByUID(devices, *uid);
    if (device == nullptr) {
        return std::nullopt;
    }
    return *device;
}

const AudioDeviceInfo* DeviceService::findByUID(const std::vector<AudioDeviceInfo>& devices,
                                                std::string_view uid) noexcept {
    const auto found = std::find_if(devices.begin(), devices.end(),
                                    [uid](const auto& device) { return device.uid == uid; });
    return found == devices.end() ? nullptr : &*found;
}

const AudioDeviceInfo*
DeviceService::findBlackHole(const std::vector<AudioDeviceInfo>& devices) noexcept {
    const AudioDeviceInfo* match = nullptr;
    for (const auto& device : devices) {
        if (!device.alive || !device.hasOutputs() || device.displayName != blackHoleName) {
            continue;
        }
        if (match != nullptr) {
            return nullptr;
        }
        match = &device;
    }
    return match;
}

int DeviceService::choosePreferredBuffer(const AudioDeviceInfo& input,
                                         const AudioDeviceInfo& output) noexcept {
    for (const auto candidate : {256, 128, 512}) {
        if (contains(input.allowedBufferFrames, candidate) &&
            contains(output.allowedBufferFrames, candidate)) {
            return candidate;
        }
    }
    return 0;
}

AudioResult DeviceService::validateConfiguration(const AudioConfiguration& configuration,
                                                 const std::vector<AudioDeviceInfo>& devices,
                                                 std::string_view defaultOutputDeviceUID) {
    const auto* blackHole = findBlackHole(devices);
    if (blackHole == nullptr || blackHole->uid != configuration.blackHoleDeviceUID) {
        return AudioResult::failure(
            AudioErrorCode::blackHoleMissing,
            "The saved BlackHole 2ch identity is unavailable or ambiguous.");
    }

    const auto* input = findByUID(devices, configuration.inputDeviceUID);
    if (input == nullptr || !input->alive || !input->hasInputs()) {
        return AudioResult::failure(AudioErrorCode::inputDeviceMissing,
                                    "The saved input device UID is unavailable.");
    }

    const auto* output = findByUID(devices, configuration.outputDeviceUID);
    if (configuration.outputTarget == AudioOutputTarget::systemPreview) {
        if (configuration.mode != RoutingMode::automaticPrivateAggregate || input->aggregate ||
            !input->physical) {
            return AudioResult::failure(
                AudioErrorCode::invalidConfiguration,
                "System preview requires the automatic physical-input configuration.");
        }
        if (defaultOutputDeviceUID.empty()) {
            return AudioResult::failure(AudioErrorCode::previewOutputUnavailable,
                                        "The macOS default output is unavailable.");
        }
        if (configuration.outputDeviceUID != defaultOutputDeviceUID) {
            return AudioResult::failure(
                AudioErrorCode::previewOutputChanged,
                "The macOS default output changed before preview could start.");
        }
        if (output == nullptr || !output->alive || !output->hasOutputs() || output->aggregate ||
            !output->physical || output->outputChannelNames.size() < 2 ||
            configuration.outputDeviceUID == configuration.blackHoleDeviceUID ||
            output->displayName == blackHoleName) {
            return AudioResult::failure(AudioErrorCode::previewOutputUnavailable,
                                        "Preview requires a live, physical, non-aggregate, "
                                        "two-channel system output other than "
                                        "BlackHole 2ch.");
        }
    } else if (output == nullptr || !output->alive || !output->hasOutputs()) {
        return AudioResult::failure(AudioErrorCode::outputDeviceMissing,
                                    "The saved output device UID is unavailable.");
    } else if (configuration.mode == RoutingMode::automaticPrivateAggregate) {
        if (configuration.outputDeviceUID != configuration.blackHoleDeviceUID ||
            output->displayName != blackHoleName) {
            return AudioResult::failure(AudioErrorCode::blackHoleMissing,
                                        "The selected output is not BlackHole 2ch.");
        }
        if (input->aggregate) {
            return AudioResult::failure(AudioErrorCode::invalidConfiguration,
                                        "Automatic mode requires a physical input device.");
        }
    } else if (configuration.inputDeviceUID != configuration.outputDeviceUID || !input->aggregate) {
        return AudioResult::failure(
            AudioErrorCode::invalidConfiguration,
            "Manual mode requires one explicitly selected aggregate device.");
    }

    if (configuration.inputChannelIndex < 0 ||
        configuration.inputChannelIndex >= static_cast<int>(input->inputChannelNames.size())) {
        return AudioResult::failure(AudioErrorCode::invalidConfiguration,
                                    "The selected input channel is unavailable.");
    }

    const auto outputStart = configuration.mode == RoutingMode::manualAggregate
                                 ? configuration.manualOutputChannelStart
                                 : 0;
    if (outputStart < 0 || outputStart + 1 >= static_cast<int>(output->outputChannelNames.size())) {
        return AudioResult::failure(AudioErrorCode::invalidConfiguration,
                                    "Two output channels are required for dual mono.");
    }

    if (configuration.sampleRate != requiredSampleRate ||
        !contains(input->sampleRates, requiredSampleRate) ||
        !contains(output->sampleRates, requiredSampleRate)) {
        return AudioResult::failure(AudioErrorCode::unsupportedSampleRate,
                                    "Input and output must both support 48 kHz.");
    }

    if (!contains(std::vector<int>{128, 256, 512}, configuration.bufferFrames) ||
        !contains(input->allowedBufferFrames, configuration.bufferFrames) ||
        !contains(output->allowedBufferFrames, configuration.bufferFrames)) {
        return AudioResult::failure(AudioErrorCode::unsupportedBufferSize,
                                    "The buffer must be a shared 128, 256, or 512 frames.");
    }

    return AudioResult::success();
}

AudioResult
DeviceService::validateManualAggregateEvidence(const ManualAggregateEvidence& evidence) {
    if (!evidence.aggregateFound) {
        return AudioResult::failure(AudioErrorCode::invalidConfiguration,
                                    "The selected manual aggregate could not be inspected.");
    }
    if (!evidence.blackHolePresent || !evidence.outputOwnsClock) {
        return AudioResult::failure(
            AudioErrorCode::invalidConfiguration,
            "The manual aggregate must contain the exact BlackHole 2ch device as its clock.");
    }
    if (!evidence.selectedInputIsPhysical || !evidence.inputDriftCompensated) {
        return AudioResult::failure(
            AudioErrorCode::invalidConfiguration,
            "The selected manual input must be a drift-compensated physical microphone channel.");
    }
    if (!evidence.outputChannelsOwnedByBlackHole) {
        return AudioResult::failure(
            AudioErrorCode::invalidConfiguration,
            "The selected manual output pair must belong to BlackHole 2ch.");
    }
    return AudioResult::success();
}

AudioResult
DeviceService::validateRoutingEvidence(RoutingMode mode, const AggregateEvidence& automaticEvidence,
                                       const ManualAggregateEvidence& manualAggregateEvidence) {
    if (mode == RoutingMode::manualAggregate) {
        return validateManualAggregateEvidence(manualAggregateEvidence);
    }

    if (!automaticEvidence.aggregateFound || !automaticEvidence.privateDevice ||
        !automaticEvidence.outputOwnsClock || !automaticEvidence.inputDriftCompensated ||
        !automaticEvidence.inputPresent || !automaticEvidence.outputPresent ||
        !automaticEvidence.subdevicesMatch) {
        std::ostringstream detail;
        detail << "The private aggregate contract failed: found="
               << automaticEvidence.aggregateFound << " private=" << automaticEvidence.privateDevice
               << " output-clock=" << automaticEvidence.outputOwnsClock
               << " input-drift=" << automaticEvidence.inputDriftCompensated
               << " input-present=" << automaticEvidence.inputPresent
               << " output-present=" << automaticEvidence.outputPresent
               << " subdevices-match=" << automaticEvidence.subdevicesMatch << '.';
        return AudioResult::failure(AudioErrorCode::aggregateDeviceCreationFailed, detail.str());
    }
    return AudioResult::success();
}

AudioResult DeviceService::configure(const AudioConfiguration& configuration) {
    close();
    invalidationError_.store(AudioErrorCode::none, std::memory_order_release);
    {
        const std::scoped_lock lock(controlMutex_);
        configuration_.reset();
        evidenceInputDeviceUID_.clear();
        evidenceOutputDeviceUID_.clear();
        expectedSubdeviceUIDs_.clear();
    }
    const auto devices = enumerateDevices();
    const auto defaultOutputUID = systemDefaultOutputDeviceUID().value_or(std::string{});
    if (configuration.outputTarget == AudioOutputTarget::systemPreview &&
        !defaultOutputListenerInstalled_) {
        return AudioResult::failure(
            AudioErrorCode::previewOutputUnavailable,
            "The macOS default-output change listener could not be installed.");
    }
    if (const auto validation = validateConfiguration(configuration, devices, defaultOutputUID);
        !validation.succeeded()) {
        return validation;
    }
    const auto* input = findByUID(devices, configuration.inputDeviceUID);
    const auto* output = findByUID(devices, configuration.outputDeviceUID);
    if (input == nullptr || output == nullptr || coreAudioType_ == nullptr) {
        return AudioResult::failure(AudioErrorCode::invalidConfiguration,
                                    "CoreAudio device resolution failed.");
    }

    if (input->backendInputName.empty() || output->backendOutputName.empty()) {
        return AudioResult::failure(AudioErrorCode::invalidConfiguration,
                                    "The CoreAudio UID-to-backend mapping could not be verified.");
    }

    auto evidenceInputUID = configuration.inputDeviceUID;
    auto expectedSubdevices = std::vector<std::string>{configuration.outputDeviceUID};
    if (configuration.inputDeviceUID != configuration.outputDeviceUID) {
        expectedSubdevices.push_back(configuration.inputDeviceUID);
    }
    if (configuration.mode == RoutingMode::manualAggregate) {
        const auto manualAggregate = inspectManualAggregate(configuration);
        if (const auto validation = validateManualAggregateEvidence(manualAggregate);
            !validation.succeeded()) {
            return validation;
        }
        evidenceInputUID = manualAggregate.selectedInputSubdeviceUID;
        expectedSubdevices = manualAggregate.orderedSubdeviceUIDs;
    }

    if (configuration.outputTarget == AudioOutputTarget::systemPreview &&
        systemDefaultOutputDeviceUID().value_or(std::string{}) != configuration.outputDeviceUID) {
        return AudioResult::failure(
            AudioErrorCode::previewOutputChanged,
            "The macOS default output changed immediately before preview configuration.");
    }

    auto device = std::unique_ptr<juce::AudioIODevice>(
        coreAudioType_->createDevice(output->backendOutputName, input->backendInputName));
    if (device == nullptr) {
        return AudioResult::failure(AudioErrorCode::aggregateDeviceCreationFailed,
                                    "CoreAudio could not create the selected device pair.");
    }

    juce::BigInteger inputChannels;
    inputChannels.setBit(configuration.inputChannelIndex);
    juce::BigInteger outputChannels;
    const auto outputStart = configuration.mode == RoutingMode::manualAggregate
                                 ? configuration.manualOutputChannelStart
                                 : 0;
    outputChannels.setRange(outputStart, 2, true);

    const auto error = device->open(inputChannels, outputChannels, configuration.sampleRate,
                                    configuration.bufferFrames);
    if (error.isNotEmpty()) {
        device->close();
        return AudioResult::failure(AudioErrorCode::aggregateDeviceCreationFailed,
                                    "CoreAudio could not open the selected route.");
    }

    if (std::abs(device->getCurrentSampleRate() - configuration.sampleRate) >= 0.5 ||
        device->getCurrentBufferSizeSamples() != configuration.bufferFrames) {
        device->close();
        return AudioResult::failure(AudioErrorCode::invalidConfiguration,
                                    "CoreAudio did not apply the requested format exactly.");
    }

    outputTarget_.store(configuration.outputTarget, std::memory_order_release);
    if (configuration.outputTarget == AudioOutputTarget::systemPreview &&
        (invalidationError() != AudioErrorCode::none ||
         systemDefaultOutputDeviceUID().value_or(std::string{}) != configuration.outputDeviceUID)) {
        device->close();
        outputTarget_.store(AudioOutputTarget::blackHole, std::memory_order_release);
        return AudioResult::failure(
            AudioErrorCode::previewOutputChanged,
            "The macOS default output changed while preview was being configured.");
    }

    {
        const std::scoped_lock lock(controlMutex_);
        activeDevice_ = std::move(device);
        configuration_ = configuration;
        evidenceInputDeviceUID_ = std::move(evidenceInputUID);
        evidenceOutputDeviceUID_ = configuration.outputDeviceUID;
        expectedSubdeviceUIDs_ = std::move(expectedSubdevices);
    }
    configurationValid_.store(true, std::memory_order_release);

    if (configuration.outputTarget == AudioOutputTarget::systemPreview &&
        invalidationError() != AudioErrorCode::none) {
        close();
        return AudioResult::failure(
            AudioErrorCode::previewOutputChanged,
            "The macOS default output changed while preview was being configured.");
    }

    const auto automaticEvidence = configuration.mode == RoutingMode::automaticPrivateAggregate
                                       ? activeAggregateEvidence()
                                       : AggregateEvidence{};
    const auto currentManualEvidence = configuration.mode == RoutingMode::manualAggregate
                                           ? inspectManualAggregate(configuration)
                                           : ManualAggregateEvidence{};
    if (const auto validation =
            validateRoutingEvidence(configuration.mode, automaticEvidence, currentManualEvidence);
        !validation.succeeded()) {
        close();
        return validation;
    }

    if (!installXrunListener()) {
        close();
        return AudioResult::failure(AudioErrorCode::invalidConfiguration,
                                    "CoreAudio xrun observation could not be installed.");
    }

    if (configuration.outputTarget == AudioOutputTarget::systemPreview &&
        (invalidationError() != AudioErrorCode::none ||
         systemDefaultOutputDeviceUID().value_or(std::string{}) != configuration.outputDeviceUID)) {
        close();
        return AudioResult::failure(
            AudioErrorCode::previewOutputChanged,
            "The macOS default output changed before preview configuration completed.");
    }

    return AudioResult::success();
}

AudioResult DeviceService::start(juce::AudioIODeviceCallback* callback) {
    const std::scoped_lock lock(controlMutex_);
    if (!isConfigurationValid() || activeDevice_ == nullptr || callback == nullptr) {
        const auto error = invalidationError();
        return AudioResult::failure(
            error == AudioErrorCode::none ? AudioErrorCode::engineStartFailed : error,
            "Audio is not configured for a fail-closed start.");
    }

    activeDevice_->start(callback);
    if (!activeDevice_->isPlaying()) {
        configurationValid_.store(false, std::memory_order_release);
        return AudioResult::failure(AudioErrorCode::engineStartFailed,
                                    "CoreAudio did not start the selected route.");
    }
    return AudioResult::success();
}

std::atomic<AudioCallbackState>& DeviceService::callbackCommitState() noexcept {
    return callbackCommitState_;
}

void DeviceService::revokeCallbackCommit() noexcept {
    auto expected = AudioCallbackState::active;
    (void)callbackCommitState_.compare_exchange_strong(expected, AudioCallbackState::cancelled,
                                                       std::memory_order_acq_rel);
}

void DeviceService::stop() noexcept {
    const std::scoped_lock lock(controlMutex_);
    if (activeDevice_ != nullptr) {
        activeDevice_->stop();
    }
}

void DeviceService::close() noexcept {
    configurationValid_.store(false, std::memory_order_release);
    revokeCallbackCommit();
    outputTarget_.store(AudioOutputTarget::blackHole, std::memory_order_release);
    const std::scoped_lock lock(controlMutex_);
    removeXrunListener();
    if (activeDevice_ != nullptr) {
        activeDevice_->stop();
        activeDevice_->close();
        activeDevice_.reset();
    }
}

bool DeviceService::isConfigurationValid() const noexcept {
    return configurationValid_.load(std::memory_order_acquire);
}

AudioErrorCode DeviceService::invalidationError() const noexcept {
    return invalidationError_.load(std::memory_order_acquire);
}

EngineDiagnostics DeviceService::diagnostics() const noexcept {
    const std::scoped_lock lock(controlMutex_);
    if (activeDevice_ == nullptr) {
        return {};
    }
    return {
        .sampleRate = activeDevice_->getCurrentSampleRate(),
        .bufferFrames = activeDevice_->getCurrentBufferSizeSamples(),
        .inputLatencySamples = activeDevice_->getInputLatencyInSamples(),
        .outputLatencySamples = activeDevice_->getOutputLatencyInSamples(),
        .xrunCount = xrunCount_.load(std::memory_order_relaxed),
    };
}

AggregateEvidence DeviceService::activeAggregateEvidence() const {
    std::string expectedInputUID;
    std::string expectedOutputUID;
    std::vector<std::string> expectedSubdevices;
    {
        const std::scoped_lock lock(controlMutex_);
        if (!configuration_.has_value()) {
            return {};
        }
        expectedInputUID = evidenceInputDeviceUID_;
        expectedOutputUID = evidenceOutputDeviceUID_;
        expectedSubdevices = expectedSubdeviceUIDs_;
    }

    const auto device = activePrivateAggregateDevice();
    if (!device.has_value()) {
        return {};
    }
    auto composition = cfProperty(*device, address(kAudioAggregateDevicePropertyComposition));
    if (!composition.has_value() || CFGetTypeID(*composition) != CFDictionaryGetTypeID()) {
        if (composition.has_value()) {
            CFRelease(*composition);
        }
        return {};
    }

    const auto evidence =
        evidenceFromComposition(static_cast<CFDictionaryRef>(*composition), expectedInputUID,
                                expectedOutputUID, expectedSubdevices);
    CFRelease(*composition);
    return evidence;
}

void DeviceService::invalidateFromCallback() noexcept {
    configurationValid_.store(false, std::memory_order_release);
}

AudioErrorCode
DeviceService::configuredEnvironmentError(const std::vector<AudioDeviceInfo>& devices) const {
    std::optional<AudioConfiguration> configuration;
    {
        const std::scoped_lock lock(controlMutex_);
        configuration = configuration_;
    }
    if (!configuration.has_value()) {
        return AudioErrorCode::none;
    }

    if (!configurationValid_.load(std::memory_order_acquire)) {
        const auto error = invalidationError();
        return error == AudioErrorCode::none ? AudioErrorCode::engineStartFailed : error;
    }
    const auto defaultOutputUID = systemDefaultOutputDeviceUID().value_or(std::string{});
    if (const auto validation = validateConfiguration(*configuration, devices, defaultOutputUID);
        !validation.succeeded()) {
        return validation.code;
    }

    const auto automaticEvidence = configuration->mode == RoutingMode::automaticPrivateAggregate
                                       ? activeAggregateEvidence()
                                       : AggregateEvidence{};
    const auto currentManualEvidence = configuration->mode == RoutingMode::manualAggregate
                                           ? inspectManualAggregate(*configuration)
                                           : ManualAggregateEvidence{};
    if (const auto validation =
            validateRoutingEvidence(configuration->mode, automaticEvidence, currentManualEvidence);
        !validation.succeeded()) {
        return validation.code;
    }

    const std::scoped_lock lock(controlMutex_);
    if (activeDevice_ == nullptr) {
        return AudioErrorCode::engineStartFailed;
    }
    if (std::abs(activeDevice_->getCurrentSampleRate() - configuration->sampleRate) >= 0.5) {
        return AudioErrorCode::unsupportedSampleRate;
    }
    if (activeDevice_->getCurrentBufferSizeSamples() != configuration->bufferFrames) {
        return AudioErrorCode::unsupportedBufferSize;
    }
    return AudioErrorCode::none;
}

void DeviceService::audioDeviceListChanged() {
    jassert(juce::MessageManager::getInstance()->isThisTheMessageThread());
    const auto devices = enumerateDevices();
    const auto error = configuredEnvironmentError(devices);
    if (error == AudioErrorCode::none) {
        (void)eventQueue_.push({.type = CoreEventType::devicesChanged});
        return;
    }

    invalidationError_.store(error, std::memory_order_release);
    configurationValid_.store(false, std::memory_order_release);
    revokeCallbackCommit();
    close();
    {
        const std::scoped_lock lock(controlMutex_);
        configuration_.reset();
        evidenceInputDeviceUID_.clear();
        evidenceOutputDeviceUID_.clear();
        expectedSubdeviceUIDs_.clear();
    }
    (void)eventQueue_.push({.type = CoreEventType::recoveryRequested, .error = error});
    (void)eventQueue_.push({.type = CoreEventType::devicesChanged});
}

ManualAggregateEvidence
DeviceService::inspectManualAggregate(const AudioConfiguration& configuration) const {
    return manualEvidence(configuration);
}

bool DeviceService::installXrunListener() noexcept {
    std::optional<AudioConfiguration> configuration;
    {
        const std::scoped_lock lock(controlMutex_);
        configuration = configuration_;
    }
    if (!configuration.has_value()) {
        return false;
    }

    const auto device = configuration->mode == RoutingMode::manualAggregate
                            ? audioDeviceForUID(configuration->inputDeviceUID)
                            : activePrivateAggregateDevice();
    if (!device.has_value()) {
        return false;
    }
    if (configuration->mode == RoutingMode::manualAggregate && !isAggregate(*device)) {
        return false;
    }
    auto property = address(kAudioDeviceProcessorOverload);
    xrunCount_.store(0, std::memory_order_relaxed);
    if (AudioObjectAddPropertyListener(*device, &property, &DeviceService::xrunPropertyChanged,
                                       this) != noErr) {
        return false;
    }
    const std::scoped_lock lock(controlMutex_);
    xrunDeviceID_ = *device;
    return true;
}

void DeviceService::removeXrunListener() noexcept {
    if (xrunDeviceID_ == kAudioObjectUnknown) {
        return;
    }
    auto property = address(kAudioDeviceProcessorOverload);
    (void)AudioObjectRemovePropertyListener(xrunDeviceID_, &property,
                                            &DeviceService::xrunPropertyChanged, this);
    xrunDeviceID_ = kAudioObjectUnknown;
}

OSStatus DeviceService::xrunPropertyChanged(AudioObjectID object, UInt32 addressCount,
                                            const AudioObjectPropertyAddress* addresses,
                                            void* clientData) noexcept {
    juce::ignoreUnused(object, addressCount, addresses);
    if (auto* service = static_cast<DeviceService*>(clientData); service != nullptr) {
        service->xrunCount_.fetch_add(1, std::memory_order_relaxed);
    }
    return noErr;
}

OSStatus DeviceService::defaultOutputPropertyChanged(AudioObjectID object, UInt32 addressCount,
                                                     const AudioObjectPropertyAddress* addresses,
                                                     void* clientData) noexcept {
    juce::ignoreUnused(object, addressCount, addresses);
    auto* service = static_cast<DeviceService*>(clientData);
    if (service == nullptr) {
        return noErr;
    }

    if (service->outputTarget_.load(std::memory_order_acquire) ==
        AudioOutputTarget::systemPreview) {
        service->invalidationError_.store(AudioErrorCode::previewOutputChanged,
                                          std::memory_order_release);
        service->configurationValid_.store(false, std::memory_order_release);
        service->revokeCallbackCommit();
    }
    (void)service->eventQueue_.push({.type = CoreEventType::devicesChanged});
    return noErr;
}

static_assert(std::atomic<AudioErrorCode>::is_always_lock_free);
static_assert(std::atomic<AudioOutputTarget>::is_always_lock_free);
static_assert(std::atomic<AudioCallbackState>::is_always_lock_free);

} // namespace shitate
