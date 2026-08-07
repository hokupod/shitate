// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "PluginScanProtocol.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <juce_core/juce_core.h>
#include <limits>
#include <set>
#include <utility>

namespace shitate::plugins {
namespace {

constexpr std::size_t maximumPathLength = 4096;
constexpr std::size_t maximumTextLength = 512;
constexpr std::size_t maximumPlugins = 128;

[[nodiscard]] juce::String utf8(const std::string& value) {
    return juce::String::fromUTF8(value.data(), static_cast<int>(value.size()));
}

[[nodiscard]] juce::DynamicObject* asObject(const juce::var& value) {
    return value.getDynamicObject();
}

[[nodiscard]] const juce::Array<juce::var>* asArray(const juce::var& value) {
    return value.getArray();
}

[[nodiscard]] bool hasExactly(const juce::DynamicObject& object,
                              const std::set<std::string>& allowed) {
    const auto& properties = object.getProperties();
    if (static_cast<std::size_t>(properties.size()) != allowed.size()) {
        return false;
    }

    for (int index = 0; index < properties.size(); ++index) {
        if (!allowed.contains(properties.getName(index).toString().toStdString())) {
            return false;
        }
    }
    return true;
}

[[nodiscard]] bool hasRequired(const juce::DynamicObject& object,
                               const std::set<std::string>& required) {
    for (const auto& name : required) {
        if (!object.hasProperty(juce::Identifier(name))) {
            return false;
        }
    }
    return true;
}

[[nodiscard]] bool readString(const juce::DynamicObject& object, const char* name,
                              std::string& output, std::size_t maximumLength = maximumTextLength,
                              bool allowEmpty = false) {
    const auto value = object.getProperty(name);
    if (!value.isString()) {
        return false;
    }

    output = value.toString().toStdString();
    return output.size() <= maximumLength && (allowEmpty || !output.empty()) &&
           output.find('\0') == std::string::npos;
}

[[nodiscard]] bool readInteger(const juce::DynamicObject& object, const char* name,
                               std::int64_t minimum, std::int64_t maximum, std::int64_t& output) {
    const auto value = object.getProperty(name);
    if (!value.isInt() && !value.isInt64()) {
        return false;
    }

    output = static_cast<std::int64_t>(value);
    return output >= minimum && output <= maximum;
}

[[nodiscard]] bool readBool(const juce::DynamicObject& object, const char* name, bool& output) {
    const auto value = object.getProperty(name);
    if (!value.isBool()) {
        return false;
    }
    output = static_cast<bool>(value);
    return true;
}

[[nodiscard]] bool readArchitectureArray(const juce::var& value, std::vector<std::string>& output) {
    const auto* array = asArray(value);
    if (array == nullptr || array->isEmpty() || array->size() > 8) {
        return false;
    }

    std::set<std::string> unique;
    for (const auto& item : *array) {
        if (!item.isString()) {
            return false;
        }
        const auto architecture = item.toString().toStdString();
        if ((architecture != "arm64" && architecture != "x86_64") ||
            !unique.insert(architecture).second) {
            return false;
        }
        output.push_back(architecture);
    }
    return true;
}

[[nodiscard]] juce::var makeStringArray(const std::vector<std::string>& values) {
    juce::Array<juce::var> result;
    for (const auto& value : values) {
        result.add(juce::String::fromUTF8(value.c_str()));
    }
    return result;
}

[[nodiscard]] bool parseRoot(std::string_view json, std::size_t maximumBytes, juce::var& root,
                             std::string& errorCode) {
    if (json.empty() || json.size() > maximumBytes) {
        errorCode = "sizeOutOfRange";
        return false;
    }

    const juce::String text = juce::String::fromUTF8(json.data(), static_cast<int>(json.size()));
    const auto parseResult = juce::JSON::parse(text, root);
    if (parseResult.failed() || !root.isObject()) {
        errorCode = "invalidJSON";
        return false;
    }
    return true;
}

[[nodiscard]] bool validatePlugin(const ScannedPlugin& plugin) {
    return isHex(plugin.classUID, 32, 32) && !plugin.name.empty() &&
           plugin.name.size() <= maximumTextLength &&
           plugin.manufacturer.size() <= maximumTextLength &&
           plugin.version.size() <= maximumTextLength &&
           plugin.category.size() <= maximumTextLength && plugin.inputChannels >= 0 &&
           plugin.inputChannels <= 64 && plugin.outputChannels >= 0 &&
           plugin.outputChannels <= 64 && plugin.latencySamples >= 0 &&
           plugin.latencySamples <= 10'000'000 &&
           (!plugin.reason.has_value() ||
            (!plugin.reason->empty() && plugin.reason->size() <= maximumTextLength));
}

} // namespace

std::string signatureKindName(SignatureKind kind) {
    switch (kind) {
    case SignatureKind::apple:
        return "apple";
    case SignatureKind::developerID:
        return "developerID";
    case SignatureKind::adHoc:
        return "adHoc";
    case SignatureKind::unsignedCode:
        return "unsigned";
    case SignatureKind::invalid:
        return "invalid";
    }
    return "invalid";
}

bool parseSignatureKind(std::string_view value, SignatureKind& kind) {
    if (value == "apple") {
        kind = SignatureKind::apple;
    } else if (value == "developerID") {
        kind = SignatureKind::developerID;
    } else if (value == "adHoc") {
        kind = SignatureKind::adHoc;
    } else if (value == "unsigned") {
        kind = SignatureKind::unsignedCode;
    } else if (value == "invalid") {
        kind = SignatureKind::invalid;
    } else {
        return false;
    }
    return true;
}

std::string compatibilityName(PluginCompatibility compatibility) {
    switch (compatibility) {
    case PluginCompatibility::compatible:
        return "compatible";
    case PluginCompatibility::incompatible:
        return "incompatible";
    case PluginCompatibility::blocked:
        return "blocked";
    }
    return "incompatible";
}

bool isCanonicalUUID(std::string_view value) {
    if (value.size() != 36) {
        return false;
    }

    for (std::size_t index = 0; index < value.size(); ++index) {
        if (index == 8 || index == 13 || index == 18 || index == 23) {
            if (value[index] != '-') {
                return false;
            }
            continue;
        }
        if (!std::isxdigit(static_cast<unsigned char>(value[index]))) {
            return false;
        }
    }
    return true;
}

bool isHex(std::string_view value, std::size_t minimumLength, std::size_t maximumLength) {
    if (value.size() < minimumLength || value.size() > maximumLength || value.size() % 2 != 0) {
        return false;
    }
    for (const auto character : value) {
        if (!std::isxdigit(static_cast<unsigned char>(character))) {
            return false;
        }
    }
    return true;
}

bool parseScanRequest(std::string_view json, ScanRequest& request, std::string& errorCode) {
    juce::var root;
    if (!parseRoot(json, maximumRequestBytes, root, errorCode)) {
        return false;
    }
    const auto* object = asObject(root);
    const std::set<std::string> fields{
        "protocolVersion", "requestID",          "pluginBundlePath", "expectedCodeDirectoryHash",
        "sampleRate",      "maximumBlockFrames", "requiredLayout"};
    if (object == nullptr || !hasExactly(*object, fields)) {
        errorCode = "invalidRequestFields";
        return false;
    }

    std::int64_t protocol = 0;
    std::int64_t blockFrames = 0;
    if (!readInteger(*object, "protocolVersion", scannerProtocolVersion, scannerProtocolVersion,
                     protocol) ||
        !readString(*object, "requestID", request.requestID, 36) ||
        !isCanonicalUUID(request.requestID) ||
        !readString(*object, "pluginBundlePath", request.pluginBundlePath, maximumPathLength) ||
        request.pluginBundlePath.front() != '/' ||
        !readString(*object, "expectedCodeDirectoryHash", request.expectedCodeDirectoryHash, 128) ||
        !isHex(request.expectedCodeDirectoryHash, 40, 128) ||
        !readInteger(*object, "maximumBlockFrames", scannerMaximumBlockFrames,
                     scannerMaximumBlockFrames, blockFrames)) {
        errorCode = "invalidRequestValue";
        return false;
    }

    const auto sampleRateValue = object->getProperty("sampleRate");
    if ((!sampleRateValue.isInt() && !sampleRateValue.isInt64() && !sampleRateValue.isDouble()) ||
        !std::isfinite(static_cast<double>(sampleRateValue)) ||
        static_cast<double>(sampleRateValue) != scannerSampleRate) {
        errorCode = "invalidSampleRate";
        return false;
    }

    const auto* layout = asObject(object->getProperty("requiredLayout"));
    const std::set<std::string> layoutFields{"inputChannels", "outputChannels"};
    std::int64_t inputs = 0;
    std::int64_t outputs = 0;
    if (layout == nullptr || !hasExactly(*layout, layoutFields) ||
        !readInteger(*layout, "inputChannels", requiredInputChannels, requiredInputChannels,
                     inputs) ||
        !readInteger(*layout, "outputChannels", requiredOutputChannels, requiredOutputChannels,
                     outputs)) {
        errorCode = "invalidRequiredLayout";
        return false;
    }

    request.protocolVersion = static_cast<int>(protocol);
    request.sampleRate = scannerSampleRate;
    request.maximumBlockFrames = static_cast<int>(blockFrames);
    request.requiredLayout = {static_cast<int>(inputs), static_cast<int>(outputs)};
    errorCode.clear();
    return true;
}

std::string serializeScanRequest(const ScanRequest& request) {
    auto* layout = new juce::DynamicObject();
    layout->setProperty("inputChannels", request.requiredLayout.inputChannels);
    layout->setProperty("outputChannels", request.requiredLayout.outputChannels);

    auto* root = new juce::DynamicObject();
    root->setProperty("protocolVersion", request.protocolVersion);
    root->setProperty("requestID", utf8(request.requestID));
    root->setProperty("pluginBundlePath", utf8(request.pluginBundlePath));
    root->setProperty("expectedCodeDirectoryHash", utf8(request.expectedCodeDirectoryHash));
    root->setProperty("sampleRate", request.sampleRate);
    root->setProperty("maximumBlockFrames", request.maximumBlockFrames);
    root->setProperty("requiredLayout", juce::var(layout));
    return juce::JSON::toString(juce::var(root), true).toStdString();
}

bool parseScanResult(std::string_view json, ScanResult& result, std::string& errorCode) {
    juce::var root;
    if (!parseRoot(json, maximumResultBytes, root, errorCode)) {
        return false;
    }
    const auto* object = asObject(root);
    const std::set<std::string> required{"protocolVersion", "requestID", "status",
                                         "bundle",          "plugins",   "durationMilliseconds"};
    if (object == nullptr || !hasRequired(*object, required)) {
        errorCode = "missingResultField";
        return false;
    }

    std::int64_t protocol = 0;
    std::int64_t duration = 0;
    if (!readInteger(*object, "protocolVersion", scannerProtocolVersion, scannerProtocolVersion,
                     protocol) ||
        !readString(*object, "requestID", result.requestID, 36) ||
        !isCanonicalUUID(result.requestID) || !readString(*object, "status", result.status, 32) ||
        (result.status != "compatible" && result.status != "incompatible") ||
        !readInteger(*object, "durationMilliseconds", 0, 120'000, duration)) {
        errorCode = "invalidResultValue";
        return false;
    }

    const auto* bundle = asObject(object->getProperty("bundle"));
    const std::set<std::string> bundleRequired{
        "path",          "codeDirectoryHash", "teamIdentifier", "signatureKind",
        "architectures", "modificationTime",  "bundleVersion"};
    std::string signatureKind;
    std::int64_t modificationTime = 0;
    if (bundle == nullptr || !hasRequired(*bundle, bundleRequired) ||
        !readString(*bundle, "path", result.bundle.path, maximumPathLength) ||
        result.bundle.path.front() != '/' ||
        !readString(*bundle, "codeDirectoryHash", result.bundle.codeDirectoryHash, 128) ||
        !isHex(result.bundle.codeDirectoryHash, 40, 128) ||
        !readString(*bundle, "teamIdentifier", result.bundle.teamIdentifier, maximumTextLength,
                    true) ||
        !readString(*bundle, "signatureKind", signatureKind, 32) ||
        !parseSignatureKind(signatureKind, result.bundle.signatureKind) ||
        result.bundle.signatureKind == SignatureKind::unsignedCode ||
        result.bundle.signatureKind == SignatureKind::invalid ||
        !readArchitectureArray(bundle->getProperty("architectures"), result.bundle.architectures) ||
        !readInteger(*bundle, "modificationTime", 0, std::numeric_limits<std::int64_t>::max(),
                     modificationTime) ||
        !readString(*bundle, "bundleVersion", result.bundle.bundleVersion, maximumTextLength,
                    true)) {
        errorCode = "invalidBundleResult";
        return false;
    }

    const auto* plugins = asArray(object->getProperty("plugins"));
    if (plugins == nullptr || plugins->size() > static_cast<int>(maximumPlugins)) {
        errorCode = "invalidPluginArray";
        return false;
    }

    result.plugins.clear();
    for (const auto& item : *plugins) {
        const auto* pluginObject = asObject(item);
        const std::set<std::string> pluginRequired{
            "classUID",  "name",          "manufacturer",   "version",
            "category",  "inputChannels", "outputChannels", "latencySamples",
            "hasEditor", "compatible",    "reason"};
        ScannedPlugin plugin;
        std::int64_t inputs = 0;
        std::int64_t outputs = 0;
        std::int64_t latency = 0;
        if (pluginObject == nullptr || !hasRequired(*pluginObject, pluginRequired) ||
            !readString(*pluginObject, "classUID", plugin.classUID, 64) ||
            !readString(*pluginObject, "name", plugin.name) ||
            !readString(*pluginObject, "manufacturer", plugin.manufacturer, maximumTextLength,
                        true) ||
            !readString(*pluginObject, "version", plugin.version, maximumTextLength, true) ||
            !readString(*pluginObject, "category", plugin.category, maximumTextLength, true) ||
            !readInteger(*pluginObject, "inputChannels", 0, 64, inputs) ||
            !readInteger(*pluginObject, "outputChannels", 0, 64, outputs) ||
            !readInteger(*pluginObject, "latencySamples", 0, 10'000'000, latency) ||
            !readBool(*pluginObject, "hasEditor", plugin.hasEditor) ||
            !readBool(*pluginObject, "compatible", plugin.compatible)) {
            errorCode = "invalidPluginResult";
            return false;
        }

        const auto reason = pluginObject->getProperty("reason");
        if (!reason.isVoid()) {
            if (!reason.isString() || reason.toString().isEmpty() ||
                reason.toString().getNumBytesAsUTF8() > maximumTextLength) {
                errorCode = "invalidPluginReason";
                return false;
            }
            plugin.reason = reason.toString().toStdString();
        }
        plugin.inputChannels = static_cast<int>(inputs);
        plugin.outputChannels = static_cast<int>(outputs);
        plugin.latencySamples = static_cast<int>(latency);
        if (!validatePlugin(plugin) || (plugin.compatible && plugin.reason.has_value()) ||
            (!plugin.compatible && !plugin.reason.has_value())) {
            errorCode = "inconsistentPluginResult";
            return false;
        }
        result.plugins.push_back(std::move(plugin));
    }

    const auto anyCompatible = std::any_of(result.plugins.begin(), result.plugins.end(),
                                           [](const auto& plugin) { return plugin.compatible; });
    if ((result.status == "compatible") != anyCompatible) {
        errorCode = "inconsistentResultStatus";
        return false;
    }

    result.protocolVersion = static_cast<int>(protocol);
    result.bundle.modificationTime = modificationTime;
    result.durationMilliseconds = duration;
    errorCode.clear();
    return true;
}

std::string serializeScanResult(const ScanResult& result) {
    auto* bundle = new juce::DynamicObject();
    bundle->setProperty("path", utf8(result.bundle.path));
    bundle->setProperty("codeDirectoryHash", utf8(result.bundle.codeDirectoryHash));
    bundle->setProperty("teamIdentifier", utf8(result.bundle.teamIdentifier));
    bundle->setProperty("signatureKind", utf8(signatureKindName(result.bundle.signatureKind)));
    bundle->setProperty("architectures", makeStringArray(result.bundle.architectures));
    bundle->setProperty("modificationTime", result.bundle.modificationTime);
    bundle->setProperty("bundleVersion", utf8(result.bundle.bundleVersion));

    juce::Array<juce::var> plugins;
    for (const auto& plugin : result.plugins) {
        auto* value = new juce::DynamicObject();
        value->setProperty("classUID", utf8(plugin.classUID));
        value->setProperty("name", utf8(plugin.name));
        value->setProperty("manufacturer", utf8(plugin.manufacturer));
        value->setProperty("version", utf8(plugin.version));
        value->setProperty("category", utf8(plugin.category));
        value->setProperty("inputChannels", plugin.inputChannels);
        value->setProperty("outputChannels", plugin.outputChannels);
        value->setProperty("latencySamples", plugin.latencySamples);
        value->setProperty("hasEditor", plugin.hasEditor);
        value->setProperty("compatible", plugin.compatible);
        if (plugin.reason.has_value()) {
            value->setProperty("reason", utf8(*plugin.reason));
        } else {
            value->setProperty("reason", juce::var());
        }
        plugins.add(juce::var(value));
    }

    auto* root = new juce::DynamicObject();
    root->setProperty("protocolVersion", result.protocolVersion);
    root->setProperty("requestID", utf8(result.requestID));
    root->setProperty("status", utf8(result.status));
    root->setProperty("bundle", juce::var(bundle));
    root->setProperty("plugins", plugins);
    root->setProperty("durationMilliseconds", result.durationMilliseconds);
    return juce::JSON::toString(juce::var(root), true).toStdString();
}

} // namespace shitate::plugins
