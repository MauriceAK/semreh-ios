import SwiftUI
import SwiftData

extension SessionListView {

    var newSessionButton: some View {
        HapticButton(feedbackStyle: .medium) {
            openNewChat()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                    .font(.title3.weight(.semibold))

                Text("Chat")
                    .font(.headline.weight(.semibold))
            }
            .foregroundStyle(newSessionButtonForegroundColor)
            .padding(.horizontal, 22)
            .frame(height: 58)
            // Lock the hit region to the visible capsule so taps in the padding,
            // rounded ends, and icon↔text gap start a new chat instead of falling
            // through to the session row behind the FAB (issue #242).
            .contentShape(Capsule())
            .background {
                if let fill = newSessionButtonSolidThemeFill {
                    Capsule().fill(fill)
                }
            }
            .sessionsChromeGlass(
                isInteractive: true,
                tint: newSessionButtonGlassTint,
                fallbackMaterial: .regularMaterial,
                in: Capsule()
            )
        }
        .buttonStyle(SessionListFloatingChatButtonStyle())
        .disabled(
            viewModel.isViewingCachedData
                || viewModel.isCreatingSession
                || navigationState.isCreatingNewChat
        )
        .opacity(viewModel.isViewingCachedData ? 0.45 : 1)
        .accessibilityLabel("New Session")
    }

    var visibleSessions: [SessionSummary] {
        viewModel.visibleSessions(
            searchText: searchText,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedSessionVisibility
        )
    }

    var scheduledSessionGroups: ScheduledSessionGroups {
        let groups = viewModel.scheduledSessionGroups(
            searchText: searchText,
            selectedProjectID: selectedProjectID,
            automatedVisibility: automatedSessionVisibility
        )
        guard usesShellChrome else { return groups }
        let ordinary = groups.ordinary.filter(matchesShellFilters)
        let scheduled = groups.scheduled.filter(matchesShellFilters)
        return ScheduledSessionGroups(
            ordinary: ordinary,
            scheduled: scheduled,
            totalScheduledCount: selectedBot == nil
                && !pinnedOnly
                && !scheduledHistoryOnly
                && selectedProjectID == nil
                ? groups.totalScheduledCount
                : scheduled.count
        )
    }

    var shellHistorySessions: [SessionSummary] {
        // The shell is a history list. Scheduled rows stay in the same
        // recency-sorted collection, and the explicit scheduled-history filter
        // selects cron-origin rows without implying an active job.
        let sessions = visibleSessions.filter(matchesShellFilters)
        guard shouldShowPinnedSessionStrip else { return sessions }

        return PinnedSessionStripPolicy.ordinarySessions(
            from: sessions,
            excluding: shellPinnedSessions
        )
    }

    var shellPinnedSessions: [SessionSummary] {
        guard PinnedSessionStripPolicy.shouldShow(
            usesShellChrome: usesShellChrome,
            isSearchActive: isSearchingSessions,
            hasActiveFilters: hasActiveSessionFilters,
            searchText: normalizedSearchText
        ) else {
            return []
        }

        return PinnedSessionStripPolicy.pinnedSessions(
            from: visibleSessions.filter(matchesShellFilters)
        )
    }

    private var shouldShowPinnedSessionStrip: Bool {
        !shellPinnedSessions.isEmpty
    }

    private func matchesShellFilters(_ session: SessionSummary) -> Bool {
        SessionShellFilter.matches(
            session,
            bot: selectedBot,
            pinnedOnly: pinnedOnly,
            scheduledHistoryOnly: scheduledHistoryOnly,
            projectID: selectedProjectID
        )
    }

    var availableBotNames: [String] {
        var names = Set<String>(
            viewModel.sessions.compactMap { profile in
                guard let profile = profile.profile?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !profile.isEmpty else { return nil }
                return profile
            }
        )
        if let selectedBot, !selectedBot.isEmpty {
            names.insert(selectedBot)
        }
        return names.sorted()
    }

    private var selectedProjectName: String? {
        guard let selectedProjectID else { return nil }
        return viewModel.projects.first(where: { $0.projectId == selectedProjectID })?.name
            .flatMap { name in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            ?? String(localized: "Project")
    }

    private var hasActiveSessionFilters: Bool {
        selectedBot != nil || pinnedOnly || scheduledHistoryOnly || selectedProjectID != nil
    }

    private var activeSessionFilterSummary: String? {
        var parts: [String] = []
        if let selectedBot {
            parts.append(selectedBot)
        }
        if pinnedOnly {
            parts.append(String(localized: "Pinned"))
        }
        if scheduledHistoryOnly {
            parts.append(String(localized: "Scheduled history"))
        }
        if let selectedProjectName {
            parts.append(selectedProjectName)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func clearSessionFilters() {
        selectedBot = nil
        pinnedOnly = false
        scheduledHistoryOnly = false
        selectedProjectID = nil
    }

    var sessionFilters: some View {
        HStack(spacing: 8) {
            Button { isPresentingSessionFilters = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: hasActiveSessionFilters
                        ? "line.3.horizontal.decrease.circle.fill"
                        : "line.3.horizontal.decrease.circle")
                    Text("Filters")
                    if let activeSessionFilterSummary {
                        Text(activeSessionFilterSummary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Session filters")
            .accessibilityValue(activeSessionFilterSummary ?? "None")
            .accessibilityHint("Filters sessions by bot, pinned state, scheduled history, or project.")

            if hasActiveSessionFilters {
                Button("Clear", action: clearSessionFilters)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                    .accessibilityHint("Clears all session filters.")
            }
            Spacer(minLength: 0)
        }
        .font(AppFont.subheadline(weight: .medium))
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
    }

    /// Bottom-of-list entry to the Archived screen (issue #17). Hidden while
    /// searching, offline (cached data cannot fetch archived rows), and when the
    /// server reports zero archived sessions or omits `archived_count` (older
    /// server) — so the list is unchanged for users with nothing archived.
    var showsArchivedEntry: Bool {
        guard !isSearchingSessions, !viewModel.isViewingCachedData else { return false }
        return (viewModel.archivedCount ?? 0) > 0
    }

    var archivedEntryRow: some View {
        HapticButton {
            navigationState.select(.archived)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "archivebox")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)

                Text("Archived Sessions")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let archivedCount = viewModel.archivedCount {
                    Text("\(archivedCount)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.thinMaterial, in: Capsule())
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 12)
        .accessibilityHint("Shows archived sessions.")
    }

    var emptySessionsTitle: String {
        if hasActiveSessionFilter {
            return String(localized: "No matching sessions")
        }

        return String(localized: "No sessions yet")
    }

    var hasActiveSessionFilter: Bool {
        hasActiveSessionFilters || !normalizedSearchText.isEmpty
    }

    var showsSearchClearButton: Bool {
        searchChromeIsExpanded && !searchText.isEmpty
    }

    private var settingsInitials: String {
        SessionIdentitySettings.displayInitials(
            displayName: identityDisplayName,
            storedInitials: identityInitials,
            fallbackFullName: NSFullUserName()
        )
    }

    var selectedHeaderLogoColor: Color {
        SemrehVisualTheme.brandActionColor(for: palette, accent: accent)
    }

    var newSessionButtonUsesThemeColor: Bool {
        PrimaryActionTintSettings.usesThemeColor(
            isEnabled: tintsPrimaryActions,
            controlIsEnabled: !viewModel.isViewingCachedData
        )
    }

    private var newSessionButtonForegroundColor: Color {
        if newSessionButtonUsesThemeColor {
            return SemrehVisualTheme.energyForeground(for: palette, accent: accent)
        }

        return colorScheme == .dark ? .black : .white
    }

    private var initialsAvatarForegroundColor: Color {
        SemrehVisualTheme.energyForeground(for: palette, accent: accent)
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var remoteSearchTaskID: SessionSearchTaskID {
        SessionSearchTaskID(query: normalizedSearchText, isViewingCachedData: viewModel.isViewingCachedData)
    }

    var activeSessionMonitorTaskID: ActiveSessionMonitorTaskID {
        let liveOwnerSessionIDs = OpenChatSessionStore.shared.liveSessionIDs(for: server)
        let activeSessions = visibleSessions.filter {
            SessionRowView.isActiveStreaming($0, liveOwnerSessionIDs: liveOwnerSessionIDs)
        }
        return ActiveSessionMonitorTaskID(
            hasActiveRows: !activeSessions.isEmpty || !liveOwnerSessionIDs.isEmpty,
            isViewingCachedData: viewModel.isViewingCachedData
        )
    }

    var sessionRowActions: SessionListRowActions {
        SessionListRowActions(
            retryLoad: {
                Task { await refreshSessionsAndActiveProfile() }
            },
            open: { session in
                selectSession(session)
            },
            togglePinned: { session in
                Task { await togglePinned(session) }
            },
            archive: { session in
                Task { await archive(session) }
            },
            delete: { session in
                sessionPendingDeletion = session
            },
            rename: { session in
                sessionPendingRename = session
            },
            duplicate: { session in
                Task { await duplicate(session) }
            },
            move: { session, projectID in
                Task { await move(session, to: projectID) }
            },
            createProject: { session in
                sessionPendingProjectCreation = session
            },
            refreshProjects: {
                guard projectsEnabled else { return }
                Task { await viewModel.loadProjects() }
            },
            export: { session, format in
                Task { await export(session, format: format) }
            },
            projectsEnabled: projectsEnabled
        )
    }

}
