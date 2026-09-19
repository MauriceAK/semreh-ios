import SwiftUI
import UIKit
import Combine

struct SessionRowSkeletonView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var verticalPadding: CGFloat = 8

    let configuration: SessionRowSkeletonConfiguration
    let showsMessageCount: Bool
    let showsWorkspace: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: rowContentSpacing) {
            titleArea

            if let metadataLabel {
                Text(verbatim: metadataLabel)
                    .font(AppFont.caption())
                    .foregroundStyle(.secondary)
                    .lineLimit(metadataLineLimit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, verticalPadding)
        .frame(minHeight: metadataLabel == nil ? 46 : 54)
        .redacted(reason: .placeholder)
    }

    @ViewBuilder
    private var titleArea: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 3) {
                titleText
                relativeDateText
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                titleText

                Spacer(minLength: 8)

                relativeDateText
            }
        }
    }

    private var titleText: some View {
        Text(verbatim: configuration.title)
            .font(AppFont.headline(weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var relativeDateText: some View {
        Text(verbatim: configuration.relativeDate)
            .font(AppFont.caption())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var rowContentSpacing: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 6 : 4
    }

    private var metadataLineLimit: Int {
        dynamicTypeSize.isAccessibilitySize ? 3 : 1
    }

    private var metadataLabel: String? {
        let parts = [
            showsMessageCount ? configuration.messageCount : nil,
            showsWorkspace ? configuration.workspace : nil
        ].compactMap(\.self)

        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

struct SessionRowSkeletonConfiguration: Identifiable {
    let id: String
    let title: String
    let messageCount: String
    let workspace: String
    let relativeDate: String

    static let loadingRows: [SessionRowSkeletonConfiguration] = [
        SessionRowSkeletonConfiguration(
            id: "recent-build",
            title: "Review latest mobile build notes",
            messageCount: "12 messages",
            workspace: "hermes-mobile",
            relativeDate: "5m"
        ),
        SessionRowSkeletonConfiguration(
            id: "polish-pass",
            title: "Plan the next polish pass",
            messageCount: "8 messages",
            workspace: "design",
            relativeDate: "1h"
        ),
        SessionRowSkeletonConfiguration(
            id: "streaming-check",
            title: "Streaming behavior investigation",
            messageCount: "24 messages",
            workspace: "webui",
            relativeDate: "3h"
        ),
        SessionRowSkeletonConfiguration(
            id: "testflight",
            title: "TestFlight validation checklist",
            messageCount: "6 messages",
            workspace: "release",
            relativeDate: "1d"
        ),
        SessionRowSkeletonConfiguration(
            id: "followup",
            title: "Follow-up implementation details",
            messageCount: "17 messages",
            workspace: "notes",
            relativeDate: "2d"
        )
    ]
}

struct OfflineCacheBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .imageScale(.small)
                .accessibilityHidden(true)

            Text("Offline - viewing cached version")
                .font(.subheadline)
                .fontWeight(.semibold)

            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }
}
