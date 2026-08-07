// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import SwiftUI
import UniformTypeIdentifiers

struct PluginsView: View {
    @Environment(AppModel.self) private var model
    @State private var isFolderImporterPresented = false
    @State private var pendingAdHocApproval: PluginCatalogEntry?

    var body: some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Plug-ins")
                    .font(.largeTitle)
                    .fontWeight(.semibold)
                Text("Browse validated arm64 VST3 Audio Effects.")
                    .foregroundStyle(.secondary)
            }
            scanStatus
            filterBar
            pluginTable
            folderSection
        }
        .padding(24)
        .navigationTitle("Plug-ins")
        .fileImporter(
            isPresented: $isFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                model.addPluginFolder(url)
            }
        }
        .alert(
            "Approve \(pendingAdHocApproval?.name ?? "Ad-hoc Plug-in")?",
            isPresented: Binding(
                get: { pendingAdHocApproval != nil },
                set: { if !$0 { pendingAdHocApproval = nil } }
            ),
            presenting: pendingAdHocApproval
        ) { entry in
            Button("Cancel", role: .cancel) {}
            Button("Approve & Add") {
                model.approveAdHocPluginAndAdd(entry)
            }
        } message: { _ in
            Text(
                "This plug-in isn't signed by an identified developer. Shi-tate will approve only its currently scanned fingerprint; any code change requires approval again."
            )
        }
    }

    @ViewBuilder
    private var scanStatus: some View {
        if let error = model.pluginCatalogError {
            InlineNotice(
                title: "Scan issue",
                message: error,
                kind: .warning
            )
        } else if isScanning {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(scanStatusText)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var filterBar: some View {
        HStack {
            TextField("Search plug-ins", text: Bindable(model).pluginSearchText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 220)
                .accessibilityLabel("Search plug-ins")
            Picker("Compatibility", selection: Bindable(model).pluginCompatibilityFilter) {
                ForEach(PluginCompatibilityFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .frame(width: 180)
            Picker("Manufacturer", selection: Bindable(model).pluginManufacturerFilter) {
                ForEach(model.pluginManufacturers, id: \.self) { manufacturer in
                    Text(manufacturer).tag(manufacturer)
                }
            }
            .frame(width: 220)
            Spacer()
            Button {
                model.rescanPlugins()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .disabled(isScanning)
        }
    }

    @ViewBuilder
    private var pluginTable: some View {
        if model.filteredPlugins.isEmpty {
            EmptyProductState(
                title: "No Matching Plug-ins",
                message: "Rescan or change the compatibility and manufacturer filters.",
                symbol: "puzzlepiece.extension"
            )
        } else {
            Table(model.filteredPlugins) {
                TableColumn("Name") { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .fontWeight(.medium)
                        Text(entry.version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 180, ideal: 240)
                TableColumn("Manufacturer", value: \.manufacturer)
                    .width(min: 120, ideal: 170)
                TableColumn("Status") { entry in
                    Label(
                        compatibilityTitle(entry.compatibility),
                        systemImage: compatibilitySymbol(entry.compatibility)
                    )
                }
                .width(min: 110, ideal: 130)
                TableColumn("Signature") { entry in
                    Text(signatureTitle(entry.signatureKind))
                }
                .width(min: 90, ideal: 110)
                TableColumn("Action") { entry in
                    HStack {
                        switch primaryAction(for: entry) {
                        case .add:
                            Button("Add") {
                                model.requestAddPlugin(entry)
                            }
                            .disabled(!model.canAddPlugin)
                        case .approve:
                            Button("Approve & Add…") {
                                pendingAdHocApproval = entry
                            }
                            .disabled(!model.canAddPlugin)
                        case .reviewSettings:
                            SettingsLink {
                                Text("Settings…")
                            }
                            .help("Enable explicit ad-hoc approval in Plug-ins settings.")
                        case .none:
                            EmptyView()
                        }
                        Button("Rescan") {
                            model.rescanPlugin(entry)
                        }
                    }
                }
                .width(min: 150, ideal: 220)
            }
            .frame(minHeight: 280)
            .accessibilityLabel("Detected VST3 plug-ins")
        }
    }

    private var folderSection: some View {
        DisclosureGroup("Additional Scan Folders") {
            VStack(alignment: .leading, spacing: 8) {
                if model.additionalPluginFolders.isEmpty {
                    Text("Only the standard user and system VST3 folders are scanned.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.additionalPluginFolders, id: \.self) { path in
                        HStack {
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                model.removePluginFolder(path)
                            }
                        }
                    }
                }
                Button("Add Folder…") {
                    isFolderImporterPresented = true
                }
            }
            .padding(.top, 8)
        }
    }

    private var isScanning: Bool {
        switch model.pluginCatalog.scanProgress {
        case .validating, .scanning:
            true
        default:
            false
        }
    }

    private func primaryAction(for entry: PluginCatalogEntry) -> PluginCatalogPrimaryAction {
        PluginCatalogActionPolicy.primaryAction(
            for: entry,
            allowAdHocSignedPlugins: model.settings.pluginPolicy.allowAdHocSignedPlugins,
            approvedAdHocFingerprints: model.approvedAdHocFingerprints
        )
    }

    private var scanStatusText: String {
        switch model.pluginCatalog.scanProgress {
        case .validating:
            "Validating plug-in identity and signature…"
        case .scanning:
            "Scanning VST3 in the isolated helper…"
        case .complete:
            "Scan complete"
        case .failed:
            "Scan failed safely"
        case .idle:
            "Idle"
        @unknown default:
            "Unknown scan state"
        }
    }

    private func compatibilityTitle(_ value: PluginCatalogCompatibility) -> String {
        switch value {
        case .compatible: "Compatible"
        case .incompatible: "Incompatible"
        case .blocked: "Blocked"
        }
    }

    private func compatibilitySymbol(_ value: PluginCatalogCompatibility) -> String {
        switch value {
        case .compatible: "checkmark.circle"
        case .incompatible: "minus.circle"
        case .blocked: "xmark.shield"
        }
    }

    private func signatureTitle(_ value: PluginCatalogSignatureKind) -> String {
        switch value {
        case .apple: "Apple"
        case .developerID: "Developer ID"
        case .adHoc: "Ad hoc"
        }
    }
}
