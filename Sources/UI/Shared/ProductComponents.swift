// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Hokuto Takemiya

import SwiftUI

struct ProductPage<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.largeTitle)
                        .fontWeight(.semibold)
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
                content
            }
            .frame(maxWidth: 920, alignment: .leading)
            .padding(24)
        }
        .navigationTitle(title)
    }
}

struct StateSummaryView: View {
    let presentation: ApplicationStatePresentation
    let error: String?

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: presentation.symbol)
                    .font(.title2)
                    .frame(width: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(presentation.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(presentation.detail)
                        .foregroundStyle(.secondary)
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    if let nextAction = presentation.nextAction {
                        Text(nextAction)
                            .fontWeight(.medium)
                            .padding(.top, 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                [presentation.title, presentation.detail, error, presentation.nextAction]
                    .compactMap { $0 }
                    .joined(separator: ". ")
            )
        }
    }
}

struct InlineNotice: View {
    enum Kind {
        case information
        case warning
        case error

        var symbol: String {
            switch self {
            case .information: "info.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.octagon"
            }
        }
    }

    let title: String
    let message: String
    var kind: Kind = .information

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.semibold)
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

struct AudioMeterRow: View {
    let title: String
    let peakDB: Float
    let rmsDB: Float
    let clipping: Bool

    var body: some View {
        GridRow {
            Text(title)
                .frame(width: 52, alignment: .leading)
            ProgressView(value: normalizedPeak)
                .tint(clipping ? .red : .accentColor)
                .accessibilityLabel("\(title) peak level")
                .accessibilityValue(
                    "\(peakDB.formatted(.number.precision(.fractionLength(1)))) decibels"
                )
            Text("\(rmsDB.formatted(.number.precision(.fractionLength(1)))) dB RMS")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Label(
                clipping ? "Clipping" : "No clipping",
                systemImage: clipping ? "exclamationmark.triangle.fill" : "checkmark.circle"
            )
            .foregroundStyle(clipping ? .red : .secondary)
        }
    }

    private var normalizedPeak: Double {
        min(max(Double(peakDB + 96) / 96, 0), 1)
    }
}

struct EmptyProductState: View {
    let title: String
    let message: String
    let symbol: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: symbol,
            description: Text(message)
        )
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}
