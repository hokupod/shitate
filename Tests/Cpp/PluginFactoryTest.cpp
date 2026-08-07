// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

#include "Plugins/PluginFactory.h"

#include "PluginRuntimeTestSupport.h"

#include <juce_core/juce_core.h>

namespace {

using namespace shitate;
using namespace shitate::plugins;

[[nodiscard]] SignatureInfo signatureFor(const CatalogEntry& entry) {
    SignatureInfo signature;
    signature.kind = entry.signatureKind;
    signature.canonicalPath = entry.bundlePath;
    signature.signingIdentifier = "dev.hokupod.runtime-test";
    signature.teamIdentifier = entry.teamIdentifier;
    signature.codeDirectoryHash = entry.codeDirectoryHash;
    signature.architectures = entry.architectures;
    signature.bundleVersion = entry.version;
    signature.modificationTime = entry.bundleModificationTime;
    return signature;
}

class FakeSignatureInspector final : public SignatureInspector {
  public:
    explicit FakeSignatureInspector(std::vector<SignatureInfo> values)
        : values_(std::move(values)) {}

    [[nodiscard]] SignatureInfo inspect(const std::string&) const noexcept override {
        if (values_.empty()) {
            return {};
        }
        const auto selected = std::min(index_, values_.size() - 1);
        ++index_;
        return values_[selected];
    }

  private:
    std::vector<SignatureInfo> values_;
    mutable std::size_t index_{0};
};

class FakeInstanceCreator final : public PluginInstanceCreator {
  public:
    explicit FakeInstanceCreator(shitate::test::TestProcessorOptions options = {},
                                 bool fail = false)
        : options_(std::move(options)), fail_(fail) {}

    [[nodiscard]] PluginInstanceResult create(const CatalogEntry&) override {
        ++createCalls;
        if (fail_) {
            return {PluginRuntimeResult::failure(PluginRuntimeError::instanceCreationFailed,
                                                 "intentional creation failure"),
                    nullptr};
        }
        return {PluginRuntimeResult::success(),
                std::make_unique<shitate::test::TestRuntimeProcessor>(options_)};
    }

    int createCalls{0};

  private:
    shitate::test::TestProcessorOptions options_;
    bool fail_{false};
};

class FakeLoadJournal final : public PluginLoadJournal {
  public:
    [[nodiscard]] PluginRuntimeResult begin(const PluginLoadJournalEntry& entry) override {
        ++beginCalls;
        lastEntry = entry;
        return beginResult;
    }

    [[nodiscard]] PluginRuntimeResult fail(const PluginLoadJournalEntry& entry,
                                           PluginRuntimeError cause) override {
        ++failCalls;
        lastEntry = entry;
        lastFailure = cause;
        return failResult;
    }

    [[nodiscard]] PluginRuntimeResult clear() override {
        ++clearCalls;
        return clearResult;
    }

    int beginCalls{0};
    int failCalls{0};
    int clearCalls{0};
    PluginLoadJournalEntry lastEntry;
    PluginRuntimeError lastFailure{PluginRuntimeError::none};
    PluginRuntimeResult beginResult;
    PluginRuntimeResult failResult;
    PluginRuntimeResult clearResult;
};

class PluginFactoryTest final : public juce::UnitTest {
  public:
    PluginFactoryTest() : UnitTest("PluginFactory", "Shitate") {}

    void runTest() override {
        beginTest("invalid catalog identity fails before journaling or loading");
        auto entry = shitate::test::catalogEntry("/tmp/RuntimeFactory.vst3");
        auto invalid = entry;
        invalid.classUID = "short";
        auto invalidInspector = std::make_shared<FakeSignatureInspector>(
            std::vector<SignatureInfo>{signatureFor(entry)});
        auto invalidCreator = std::make_shared<FakeInstanceCreator>();
        auto invalidJournal = std::make_shared<FakeLoadJournal>();
        RealtimeEventQueue invalidQueue;
        PluginFactory invalidFactory(invalidQueue, invalidInspector, invalidCreator,
                                     invalidJournal);
        const auto invalidResult = invalidFactory.create(invalid, shitate::test::slotID(1));
        expect(invalidResult.result.error == PluginRuntimeError::invalidDescriptor);
        expectEquals(invalidJournal->beginCalls, 0);
        expectEquals(invalidCreator->createCalls, 0);

        beginTest("changed signature identity fails closed before loading");
        auto changedIdentity = signatureFor(entry);
        changedIdentity.codeDirectoryHash.back() = '8';
        auto changedInspector =
            std::make_shared<FakeSignatureInspector>(std::vector<SignatureInfo>{changedIdentity});
        auto changedCreator = std::make_shared<FakeInstanceCreator>();
        auto changedJournal = std::make_shared<FakeLoadJournal>();
        RealtimeEventQueue changedQueue;
        PluginFactory changedFactory(changedQueue, changedInspector, changedCreator,
                                     changedJournal);
        const auto changed = changedFactory.create(entry, shitate::test::slotID(2));
        expect(changed.result.error == PluginRuntimeError::identityChanged);
        expectEquals(changedJournal->beginCalls, 0);
        expectEquals(changedCreator->createCalls, 0);

        beginTest("journal begin failure prevents instance creation");
        auto journalInspector = std::make_shared<FakeSignatureInspector>(
            std::vector<SignatureInfo>{signatureFor(entry)});
        auto journalCreator = std::make_shared<FakeInstanceCreator>();
        auto failedJournal = std::make_shared<FakeLoadJournal>();
        failedJournal->beginResult = PluginRuntimeResult::failure(
            PluginRuntimeError::journalWriteFailed, "intentional journal failure");
        RealtimeEventQueue journalQueue;
        PluginFactory journalFactory(journalQueue, journalInspector, journalCreator, failedJournal);
        const auto journalFailure = journalFactory.create(entry, shitate::test::slotID(3));
        expect(journalFailure.result.error == PluginRuntimeError::journalWriteFailed);
        expectEquals(journalCreator->createCalls, 0);

        beginTest("graceful factory failures publish a terminal journal record");
        expectFailureAfterJournal(entry, {.failCreation = true},
                                  PluginRuntimeError::instanceCreationFailed);
        expectFailureAfterJournal(entry, {.supportsStereo = false},
                                  PluginRuntimeError::unsupportedLayout);
        expectFailureAfterJournal(entry, {.throwDuringPrepare = true},
                                  PluginRuntimeError::prepareFailed);
        expectFailureAfterJournal(entry, {.changePostflight = true},
                                  PluginRuntimeError::identityChanged);

        beginTest("successful state restore prepares exact format then clears the journal");
        auto successInspector = std::make_shared<FakeSignatureInspector>(
            std::vector<SignatureInfo>{signatureFor(entry), signatureFor(entry)});
        auto probe = std::make_shared<shitate::test::ProcessorProbe>();
        auto successCreator = std::make_shared<FakeInstanceCreator>(
            shitate::test::TestProcessorOptions{.probe = probe});
        auto successJournal = std::make_shared<FakeLoadJournal>();
        RealtimeEventQueue successQueue;
        PluginFactory successFactory(successQueue, successInspector, successCreator,
                                     successJournal);
        const std::array<float, 2> state{0.25F, 0.125F};
        auto success =
            successFactory.create(entry, shitate::test::slotID(7), state.data(), sizeof(state));
        expect(success.result.succeeded());
        expect(success.slot != nullptr);
        expectEquals(successJournal->beginCalls, 1);
        expectEquals(successJournal->clearCalls, 1);
        expect(successJournal->lastEntry.slotID == shitate::test::slotID(7));
        expectEquals(probe->prepareCalls, 1);
        expectEquals(probe->maximumFrames, shitate::maximumPluginFrames);
        juce::AudioBuffer<float> buffer(2, 16);
        juce::MidiBuffer midi;
        shitate::test::fill(buffer, 1.0F, 16);
        success.slot->process(buffer, midi, 16);
        expectWithinAbsoluteError(buffer.getSample(0, 0), 0.375F, 0.0001F);

        beginTest("journal clear failure does not expose a loaded slot");
        auto clearInspector = std::make_shared<FakeSignatureInspector>(
            std::vector<SignatureInfo>{signatureFor(entry), signatureFor(entry)});
        auto clearCreator = std::make_shared<FakeInstanceCreator>();
        auto clearJournal = std::make_shared<FakeLoadJournal>();
        clearJournal->clearResult = PluginRuntimeResult::failure(
            PluginRuntimeError::journalWriteFailed, "intentional clear failure");
        RealtimeEventQueue clearQueue;
        PluginFactory clearFactory(clearQueue, clearInspector, clearCreator, clearJournal);
        const auto clearFailure = clearFactory.create(entry, shitate::test::slotID(8));
        expect(clearFailure.result.error == PluginRuntimeError::journalWriteFailed);
        expect(clearFailure.slot == nullptr);
        expectEquals(clearJournal->beginCalls, 1);
        expectEquals(clearJournal->clearCalls, 1);
    }

  private:
    struct FailureOptions final {
        bool failCreation{false};
        bool supportsStereo{true};
        bool throwDuringPrepare{false};
        bool changePostflight{false};
    };

    void expectFailureAfterJournal(const CatalogEntry& entry, FailureOptions options,
                                   PluginRuntimeError expectedError) {
        auto before = signatureFor(entry);
        auto after = before;
        if (options.changePostflight) {
            after.modificationTime += 1;
        }
        auto inspector =
            std::make_shared<FakeSignatureInspector>(std::vector<SignatureInfo>{before, after});
        auto creator = std::make_shared<FakeInstanceCreator>(
            shitate::test::TestProcessorOptions{
                .throwDuringPrepare = options.throwDuringPrepare,
                .supportsStereo = options.supportsStereo,
            },
            options.failCreation);
        auto journal = std::make_shared<FakeLoadJournal>();
        RealtimeEventQueue queue;
        PluginFactory factory(queue, inspector, creator, journal);
        const auto result = factory.create(entry, shitate::test::slotID(6));
        expect(result.result.error == expectedError);
        expect(result.slot == nullptr);
        expectEquals(journal->beginCalls, 1);
        expectEquals(journal->failCalls, 1);
        expect(journal->lastFailure == expectedError);
        expectEquals(journal->clearCalls, 0);
    }
};

PluginFactoryTest pluginFactoryTest;

} // namespace
