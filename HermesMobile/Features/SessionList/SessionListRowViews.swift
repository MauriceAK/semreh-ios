import SwiftUI
import UIKit
import Combine

struct SessionListRowsSection: View {
    let viewModel: SessionListViewModel
    var server: URL? = nil
    var latestMessagePreviews: [CachedSessionPreviewIdentity: CachedSessionPreview] = [:]

    let sessions: [SessionSummary]
    let emptyTitle: String
    let emptyDescription: String?
    let isSearchActive: Bool
    let showsMessageCount: Bool
    let showsWorkspace: Bool
    let selectedSessionID: String?
    let actions: SessionListRowActions
    var suppressEmptyState = false
    var useMessagesStyle = false
    var showsSectionHeader = true

    var body: some View {
        if showsSectionHeader {
            sessionsHeaderRow
                .padding(.top, isSearchActive ? 16 : 28)
                .sessionsScreenListRow()
        }

        if viewModel.isLoading && viewModel.sessions.isEmpty {
            sessionLoadingSkeletonRows
        } else if let errorMessage = viewModel.errorMessage, viewModel.sessions.isEmpty {
            sessionsErrorRow(message: errorMessage)
                .sessionsScreenListRow()
        } else if sessions.isEmpty && !suppressEmptyState {
            SessionListStatusRow(
                title: emptyTitle,
                description: emptyDescription,
                systemImage: "bubble.left"
            )
                .padding(.horizontal, 24)
                .sessionsScreenListRow()
        } else {
            ForEach(sessions) { session in
                let preview = latestPreview(for: session)
                SessionInteractiveRow(
                    viewModel: viewModel,
                    session: session,
                    server: server,
                    showsMessageCount: showsMessageCount,
                    showsWorkspace: showsWorkspace,
                    selectedSessionID: selectedSessionID,
                    actions: actions,
                    useMessagesStyle: useMessagesStyle,
                    latestMessagePreview: preview?.text,
                    latestMessageTimestamp: preview?.messageTimestamp
                )
            }
        }
    }

    private func latestPreview(for session: SessionSummary) -> CachedSessionPreview? {
        guard let sessionID = session.sessionId else { return nil }
        let activeProfile = normalizedProfile(viewModel.activeProfileName) ?? "default"
        let rowProfile = normalizedProfile(session.profile) ?? activeProfile
        return latestMessagePreviews[
            CachedSessionPreviewIdentity(profile: rowProfile, sessionID: sessionID)
        ]
    }

    private func normalizedProfile(_ rawProfile: String?) -> String? {
        guard let profile = rawProfile?.trimmingCharacters(in: .whitespacesAndNewlines),
              !profile.isEmpty else { return nil }
        return profile
    }

    private var sessionsHeaderRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if !isSearchActive {
                    Text("Sessions")
                        .font(.title3.bold())
                        .foregroundStyle(.primary)
                }

                Spacer()

                if viewModel.isSearchingRemoteSessions {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Searching sessions")
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }

    private var sessionLoadingSkeletonRows: some View {
        ForEach(Array(SessionRowSkeletonConfiguration.loadingRows.enumerated()), id: \.element.id) { index, row in
            SessionRowSkeletonView(
                configuration: row,
                showsMessageCount: showsMessageCount,
                showsWorkspace: showsWorkspace
            )
            .sessionsScreenListRow(insets: EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Loading sessions")
            .accessibilityHidden(index > 0)
        }
        .allowsHitTesting(false)
    }

    private func sessionsErrorRow(message errorMessage: String) -> some View {
        let content = sessionsErrorContent(fallbackMessage: errorMessage)

        return VStack(alignment: .leading, spacing: 10) {
            SessionListStatusRow(
                title: content.title,
                description: content.description,
                systemImage: "exclamationmark.triangle",
                descriptionLineLimit: 3
            )

            Button("Retry", action: actions.retryLoad)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .buttonStyle(.plain)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityLabel("Retry loading sessions")
                .accessibilityHint("Attempts to reconnect to the server and reload sessions.")
        }
        .padding(.horizontal, 24)
    }

    private func sessionsErrorContent(fallbackMessage: String) -> (title: String, description: String) {
        if let sessionLoadError = viewModel.sessionLoadError,
           CacheFallbackPolicy.shouldUseCache(for: sessionLoadError) {
            return (
                String(localized: "Cannot reach server"),
                String(localized: "Check that your Mac is awake and cloudflared is running.")
            )
        }

        return (String(localized: "Could not load sessions"), fallbackMessage)
    }

}

struct SessionInteractiveRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let viewModel: SessionListViewModel
    let session: SessionSummary
    var server: URL? = nil
    let showsMessageCount: Bool
    let showsWorkspace: Bool
    let selectedSessionID: String?
    let actions: SessionListRowActions
    var useMessagesStyle = false
    var latestMessagePreview: String? = nil
    var latestMessageTimestamp: Double? = nil

    private var actionCapabilities: SessionRowActionPolicy.Capabilities {
        SessionRowActionPolicy.Capabilities(
            isSearchOnlySession: viewModel.isSearchOnlySession(session),
            isViewingCachedData: viewModel.isViewingCachedData
        )
    }

    var body: some View {
        Button {
            actions.open(session)
        } label: {
            if useMessagesStyle {
                MessagesSessionRowView(
                    session: session,
                    isViewingCachedData: viewModel.isViewingCachedData,
                    server: server,
                    latestMessagePreview: latestMessagePreview,
                    latestMessageTimestamp: latestMessageTimestamp
                )
            } else {
                SessionRowView(
                    session: session,
                    showsMessageCount: showsMessageCount,
                    showsWorkspace: showsWorkspace,
                    isViewingCachedData: viewModel.isViewingCachedData
                )
            }
        }
        .buttonStyle(.plain)
        .id(session.id)
        .background(
            session.sessionId == selectedSessionID
                ? Color.accentColor.opacity(0.12)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .transition(SessionListMotion.sessionRowTransition(reduceMotion: reduceMotion))
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            sessionLeadingSwipeActions(for: session)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            sessionTrailingSwipeActions(for: session)
        }
        .contextMenu {
            SessionRowContextMenu(
                session: session,
                projects: viewModel.projects,
                isViewingCachedData: viewModel.isViewingCachedData,
                isRenamingSession: viewModel.isRenamingSession,
                isCreatingProject: viewModel.isCreatingProject,
                isMovingSession: viewModel.isMovingSession,
                isLoadingProjects: viewModel.isLoadingProjects,
                isMutating: viewModel.isMutating(session),
                capabilities: actionCapabilities,
                actions: actions
            )
        }
        .sessionsScreenListRow(
            insets: useMessagesStyle
                ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
                : EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        )
    }

    @ViewBuilder
    private func sessionLeadingSwipeActions(for session: SessionSummary) -> some View {
        if SessionRowActionPolicy.offersMetadataActions(
            for: session,
            capabilities: actionCapabilities
        ) {
            Button {
                actions.togglePinned(session)
            } label: {
                Label(session.pinned == true ? "Unpin" : "Pin", systemImage: "pin")
            }
            .disabled(viewModel.isMutating(session))
            .tint(.accentColor)
        }
    }

    @ViewBuilder
    private func sessionTrailingSwipeActions(for session: SessionSummary) -> some View {
        if SessionRowActionPolicy.offersMetadataActions(
            for: session,
            capabilities: actionCapabilities
        ) {
            Button {
                actions.archive(session)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(viewModel.isMutating(session))
            .tint(.orange)
        }

        if SessionRowActionPolicy.offersCollectionActions(
            for: session,
            capabilities: actionCapabilities
        ) {
            Button {
                actions.delete(session)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(viewModel.isMutating(session))
            .tint(.red)
        }
    }
}

struct SessionListFloatingChatButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed

        configuration.label
            .scaleEffect(reduceMotion ? 1 : (isPressed ? 0.975 : 1))
            .opacity(isPressed ? 0.96 : 1)
            .shadow(
                color: .black.opacity(isPressed ? 0.10 : 0.18),
                radius: isPressed ? 8 : 18,
                y: isPressed ? 3 : 8
            )
            .animation(SessionListMotion.pressAnimation(reduceMotion: reduceMotion), value: isPressed)
    }
}
