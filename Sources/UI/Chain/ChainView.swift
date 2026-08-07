// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import SwiftUI

struct ChainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chain")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text("A fixed-order stereo chain with up to eight VST3 plug-ins.")
                    .foregroundStyle(.secondary)
            }
            workflowNotice
            chainContent
            actionBar
        }
        .padding(24)
        .navigationTitle("Chain")
    }

    @ViewBuilder
    private var workflowNotice: some View {
        switch model.sessionWorkflow {
        case .notLoaded:
            InlineNotice(
                title: "No saved session",
                message: "Complete setup to save a zero-plug-in passthrough or add a plug-in.",
                kind: .information
            )
        case .restoreSkipped:
            InlineNotice(
                title: "Saved session not restored",
                message:
                    "Restore Last Session is off. Routing can use an empty passthrough, but the saved chain will not be changed.",
                kind: .information
            )
        case .restoring:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Restoring and revalidating the saved chain…")
            }
            .accessibilityElement(children: .combine)
        case .saving:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving plug-in state atomically…")
            }
            .accessibilityElement(children: .combine)
        case .complete:
            EmptyView()
        case .incomplete(let reason):
            VStack(alignment: .leading, spacing: 10) {
                InlineNotice(
                    title: "Saved chain is incomplete",
                    message: "\(reason) Routing remains stopped until you choose an action.",
                    kind: .warning
                )
                HStack {
                    Button("Retry") {
                        model.retrySessionRestore()
                    }
                    Button("Rescan Plug-ins") {
                        model.rescanAndRetrySessionRestore()
                    }
                    Button("Remove Unavailable") {
                        model.removeUnavailablePluginsFromSession()
                    }
                    Button("Start Without Unavailable") {
                        model.startWithoutUnavailablePlugins()
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .disabled(!model.canRecoverSession)
            }
        }
    }

    @ViewBuilder
    private var chainContent: some View {
        if model.pluginSlots.isEmpty {
            EmptyProductState(
                title: "No Plug-ins",
                message:
                    "Passthrough is valid. Add a compatible VST3 only when processing is needed.",
                symbol: "point.3.connected.trianglepath.dotted"
            )
        } else {
            List {
                ForEach(Array(model.pluginSlots.enumerated()), id: \.element.id) { index, slot in
                    PluginSlotRow(index: index, slot: slot)
                        .environment(model)
                }
                .onMove(perform: moveSlots)
                .moveDisabled(!model.canEditPluginChain)
            }
            .listStyle(.inset)
            .frame(minHeight: 300)
            .accessibilityLabel("VST3 chain")
        }
    }

    private var actionBar: some View {
        HStack {
            Menu {
                let compatible = model.pluginCatalog.document.entries.filter {
                    PluginCatalogActionPolicy.primaryAction(
                        for: $0,
                        allowAdHocSignedPlugins:
                            model.settings.pluginPolicy.allowAdHocSignedPlugins,
                        approvedAdHocFingerprints: model.approvedAdHocFingerprints
                    ) == .add
                }
                if compatible.isEmpty {
                    Text("No compatible VST3 found")
                } else {
                    ForEach(compatible, id: \.fingerprint) { entry in
                        Button(entry.name) {
                            model.requestAddPlugin(entry)
                        }
                    }
                }
            } label: {
                Label("Add Plug-in", systemImage: "plus")
            }
            .disabled(!model.canAddPlugin)
            .help("Add a validated VST3 Audio Effect")

            Button {
                model.requestSaveSession()
            } label: {
                Label("Save Session", systemImage: "square.and.arrow.down")
            }
            .disabled(!model.canEditPluginChain)
            Spacer()
            Text("\(model.pluginSlots.count) of \(SessionDocument.maximumSlots) slots")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func moveSlots(from source: IndexSet, to destination: Int) {
        guard let sourceIndex = source.first,
            model.pluginSlots.indices.contains(sourceIndex)
        else {
            return
        }
        let target = sourceIndex < destination ? destination - 1 : destination
        guard model.pluginSlots.indices.contains(target) else {
            return
        }
        model.requestMovePlugin(model.pluginSlots[sourceIndex].id, to: target)
    }
}

private struct PluginSlotRow: View {
    @Environment(AppModel.self) private var model

    let index: Int
    let slot: PluginSlotPresentation

    var body: some View {
        HStack(spacing: 14) {
            Text("\(index + 1)")
                .font(.headline)
                .monospacedDigit()
                .frame(width: 24)
                .accessibilityLabel("Slot \(index + 1)")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(slot.name)
                        .fontWeight(.semibold)
                    if slot.isFaulted {
                        Label("Faulted", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Text("\(slot.manufacturer) · \(slot.version) · \(slot.latencySamples) samples")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
                "Bypass",
                isOn: Binding(
                    get: { slot.isBypassed },
                    set: { model.setPluginBypassed(slot.id, bypassed: $0) }
                )
            )
            .toggleStyle(.switch)
            .disabled(slot.isFaulted || !model.canEditPluginChain)
            Button("Edit") {
                model.openPluginEditor(slot.id)
            }
            .disabled(!slot.hasEditor || slot.isFaulted || !model.canEditPluginChain)
            Menu {
                Button("Move Up") {
                    model.requestMovePlugin(slot.id, to: index - 1)
                }
                .disabled(index == 0)
                Button("Move Down") {
                    model.requestMovePlugin(slot.id, to: index + 1)
                }
                .disabled(index + 1 >= model.pluginSlots.count)
                Divider()
                Button("Remove", role: .destructive) {
                    model.requestRemovePlugin(slot.id)
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .disabled(!model.canEditPluginChain)
            .help("More actions for \(slot.name)")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}
