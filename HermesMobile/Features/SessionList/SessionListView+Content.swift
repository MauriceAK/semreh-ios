import SwiftUI
import SwiftData

extension SessionListView {

    var content: some View {
        let sessionGroups = scheduledSessionGroups
        let pinnedSessions = shellPinnedSessions

        return List {
            if usesShellChrome {
                sessionFilters
                    .sessionsScreenListRow()
            } else {
                header
                    .sessionsTopChromeListRow()
            }

            if viewModel.isViewingCachedData {
                if usesShellChrome {
                    shellOfflineStatus
                        .sessionsScreenListRow()
                } else {
                    OfflineCacheBanner()
                        .padding(.top, 16)
                        .sessionsScreenListRow()
                }
            }

            if let utilityRowsVisibility = SessionListUtilityRowsVisibilityPolicy.visibleSections(
                usesShellChrome: usesShellChrome,
                projectsEnabled: projectsEnabled && AppShellOrganizerPolicy.showsProjects(
                    isShell: usesShellChrome,
                    hasProjects: !viewModel.projects.isEmpty,
                    hasSelection: selectedProjectID != nil
                ),
                isSearchingSessions: isSearchingSessions,
                userVisibility: sidebarSectionVisibility
            ) {
                SessionSidebarUtilityRows(
                    viewModel: viewModel,
                    topPadding: 10,
                    automatedVisibility: automatedSessionVisibility,
                    sectionVisibility: utilityRowsVisibility,
                    profilesAreExpanded: $profilesAreExpanded,
                    projectsAreExpanded: $projectsAreExpanded,
                    selectedProjectID: $selectedProjectID,
                    projectPendingDeletion: $projectPendingDeletion,
                    projectPendingRename: $projectPendingRename,
                    openDestination: { destination in
                        navigationState.select(destination)
                    },
                    switchActiveProfile: { profile in
                        Task { await switchActiveProfile(profile) }
                    },
                    presentProjectCreation: {
                        isPresentingProjectCreation = true
                    }
                )
            }

            if !pinnedSessions.isEmpty {
                PinnedSessionStrip(
                    viewModel: viewModel,
                    sessions: pinnedSessions,
                    server: server,
                    actions: sessionRowActions
                )
                .sessionsScreenListRow(
                    insets: EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0)
                )
            }

            if !usesShellChrome, sessionGroups.showsDisclosure(isSearchActive: isSearchingSessions) {
                ScheduledSessionsDisclosure(
                    viewModel: viewModel,
                    sessions: sessionGroups.scheduled,
                    totalCount: sessionGroups.totalScheduledCount,
                    isSearchActive: isSearchingSessions,
                    showsMessageCount: showsSessionMessageCount,
                    showsWorkspace: showsSessionWorkspace,
                    selectedSessionID: horizontalSizeClass == .regular
                        ? navigationState.selectedSessionID
                        : nil,
                    userIsExpanded: $scheduledSessionsAreExpanded,
                    actions: sessionRowActions,
                    viewAll: { navigationState.select(.scheduled) }
                )
            }

            SessionListRowsSection(
                viewModel: viewModel,
                server: server,
                latestMessagePreviews: viewModel.cachedSessionPreviews,
                sessions: usesShellChrome ? shellHistorySessions : sessionGroups.ordinary,
                emptyTitle: emptySessionsTitle,
                emptyDescription: emptySessionsDescription,
                isSearchActive: isSearchingSessions,
                showsMessageCount: showsSessionMessageCount,
                showsWorkspace: showsSessionWorkspace,
                selectedSessionID: horizontalSizeClass == .regular
                    ? navigationState.selectedSessionID
                    : nil,
                actions: sessionRowActions,
                suppressEmptyState: usesShellChrome
                    ? !pinnedSessions.isEmpty
                    : !sessionGroups.scheduled.isEmpty,
                useMessagesStyle: usesShellChrome,
                showsSectionHeader: !usesShellChrome
            )

            if showsArchivedEntry {
                archivedEntryRow
                    .sessionsScreenListRow()
            }

            if !usesShellChrome {
                Color.clear
                    .frame(height: 104)
                    .sessionsScreenListRow()
                    .accessibilityHidden(true)
            }
        }
        .listStyle(.plain)
        // Let rows hug their content instead of the 44pt default minimum, so the
        // single-line utility/disclosure rows aren't padded out and stay aligned
        // with the tightly-packed navigation rows.
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .scrollPosition(id: $sidebarScrollPosition)
        .background { SemrehBackdrop().ignoresSafeArea() }
        .scrollDismissesKeyboard(.interactively)
        // Disclosure subrows are real List rows; drive their fold from the List
        // so insert/remove animates. Value-based so it works with @AppStorage.
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: profilesAreExpanded)
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: projectsAreExpanded)
        .animation(SessionListMotion.disclosureAnimation(reduceMotion: reduceMotion), value: scheduledSessionsAreExpanded)
    }

    var header: some View {
        searchChrome
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(SemrehVisualTheme.energyGradient(for: palette))
                .frame(height: 2)
                .padding(.horizontal, 24)
                .offset(y: 11)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion), value: searchChromeIsExpanded)
        .animation(SessionListMotion.searchFocusAnimation(reduceMotion: reduceMotion), value: showsSearchClearButton)
        .onChange(of: searchFieldIsFocused) { _, newValue in
            handleSearchFieldFocusChange(newValue)
        }
    }

    private var shellOfflineStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 13, weight: .semibold))
            Text("Offline · cached sessions")
                .font(.caption.weight(.semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Offline, viewing cached sessions")
    }

}
