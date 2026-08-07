// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            List(selection: $model.selectedSection) {
                ForEach(ProductSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                        .accessibilityLabel(section.title)
                }
            }
            .navigationTitle("Shi-tate")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 260)
        } detail: {
            selectedView
        }
        .frame(minWidth: 1180, minHeight: 600)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.isRoutingActive ? model.stopRouting() : model.startRouting()
                } label: {
                    Label(
                        model.isRoutingActive ? "Stop Routing" : "Start Routing",
                        systemImage: model.isRoutingActive ? "stop.fill" : "play.fill"
                    )
                }
                .disabled(routingButtonDisabled)
                .help(model.isRoutingActive ? "Stop audio routing" : "Start audio routing")

                Button {
                    model.toggleMute()
                } label: {
                    Label(
                        model.isMuted ? "Unmute" : "Mute",
                        systemImage: model.isMuted ? "mic" : "mic.slash"
                    )
                }
                .disabled(model.state != .running && model.state != .muted)
                .help("Toggle master mute (Control-Shift-M)")
            }
        }
        .confirmationDialog(
            "Pause Audio?",
            isPresented: pendingOperationBinding,
            titleVisibility: .visible
        ) {
            Button("Pause and Continue") {
                model.confirmPendingAudioOperation()
            }
            Button("Cancel", role: .cancel) {
                model.cancelPendingAudioOperation()
            }
        } message: {
            Text(
                model.pendingAudioOperation?.interruptionMessage
                    ?? "Audio remains unchanged."
            )
        }
        .sheet(isPresented: $model.isOnboardingPresented) {
            OnboardingView()
                .environment(model)
        }
    }

    @ViewBuilder
    private var selectedView: some View {
        if model.safeModeReason != nil,
            model.selectedSection != .diagnostics,
            model.selectedSection != .about
        {
            SafeModeView()
        } else {
            switch model.selectedSection {
            case .dashboard:
                DashboardView()
            case .chain:
                ChainView()
            case .plugins:
                PluginsView()
            case .diagnostics:
                DiagnosticsView()
            case .about:
                AboutView()
            }
        }
    }

    private var routingButtonDisabled: Bool {
        switch model.state {
        case .starting, .stopping:
            true
        default:
            !model.isRoutingActive && !model.canStartRouting
        }
    }

    private var pendingOperationBinding: Binding<Bool> {
        Binding(
            get: { model.pendingAudioOperation != nil },
            set: { isPresented in
                if !isPresented {
                    model.cancelPendingAudioOperation()
                }
            }
        )
    }
}
