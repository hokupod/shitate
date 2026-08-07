// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import SwiftUI

struct AboutView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ProductPage(
            title: "Shi-tate / 仕立て",
            subtitle: "A native macOS VST3 microphone processor."
        ) {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Shi-tate \(model.bridge.displayVersion)", systemImage: "waveform.circle")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Copyright © 2026 Hokuto Takemiya")
                    Text(
                        "Licensed under AGPL-3.0-only. You may redistribute and modify Shi-tate under the terms of that license."
                    )
                    Text("Shi-tate is provided without warranty, to the extent permitted by law.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            GroupBox("Source and Notices") {
                VStack(alignment: .leading, spacing: 10) {
                    Link("Source Code", destination: sourceURL)
                    Link(
                        "Full AGPL-3.0 License",
                        destination: sourceURL.appending(path: "blob/main/LICENSE"))
                    Link(
                        "Third-Party Notices",
                        destination: sourceURL.appending(path: "blob/main/THIRD_PARTY_NOTICES.md"))
                    Text(
                        "Shi-tate includes JUCE 9.0.0 under AGPLv3 terms and does not bundle BlackHole or third-party VST3 plug-ins."
                    )
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    private var sourceURL: URL {
        guard let url = URL(string: "https://github.com/hokupod/shitate") else {
            preconditionFailure("The source URL must be valid.")
        }
        return url
    }
}
