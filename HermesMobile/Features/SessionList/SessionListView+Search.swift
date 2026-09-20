import SwiftUI
import SwiftData

extension SessionListView {

    var searchChrome: some View {
        HStack(spacing: searchChromeIsExpanded ? 8 : 4) {
            HapticButton {
                if searchChromeIsExpanded {
                    searchFieldIsFocused = true
                } else {
                    openSearch()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(searchChromeIsExpanded ? .secondary : .primary)
                    .frame(width: Self.searchChromeIconVisualSize, height: Self.searchChromeIconVisualSize)
                    .frame(width: Self.searchChromeIconHitTarget, height: Self.searchChromeIconHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(searchChromeIsExpanded ? "Focus session search" : "Search sessions")
            .accessibilityHint("Shows the session search field.")
            .accessibilityHidden(searchChromeIsExpanded)

            searchTextField

            if showsSearchClearButton {
                searchClearButton
                    .transition(.scale.combined(with: .opacity))
            }

            searchTrailingButton
        }
        .padding(.vertical, 2)
        .frame(maxWidth: searchChromeIsExpanded ? .infinity : nil, alignment: .trailing)
        .sessionsChromeGlass(
            isInteractive: true,
            in: Capsule()
        )
        .clipShape(Capsule())
        .contentShape(Capsule())
    }

    var shellSearchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)

            if searchChromeIsExpanded {
                TextField("Search sessions", text: $searchText)
                    .font(AppFont.body())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($searchFieldIsFocused)
                    .submitLabel(.done)
                    .lineLimit(1)
                    .accessibilityLabel("Search sessions")
            } else {
                Text("Search")
                    .font(AppFont.body())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 0)

            if searchChromeIsExpanded {
                Button {
                    closeSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close search")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 44)
        .adaptiveGlass(
            .regular,
            isInteractive: true,
            fallbackMaterial: .ultraThinMaterial,
            in: Capsule()
        )
        .contentShape(Capsule())
        .onTapGesture {
            guard !searchChromeIsExpanded else { return }
            openSearch()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(searchChromeIsExpanded ? "Session search" : "Search sessions")
    }

    var searchTextField: some View {
        TextField("Search sessions", text: $searchText)
            .font(AppFont.subheadline())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($searchFieldIsFocused)
            .submitLabel(.done)
            .lineLimit(1)
            .layoutPriority(1)
            .frame(maxWidth: searchChromeIsExpanded ? .infinity : 0)
            .opacity(searchChromeIsExpanded ? 1 : 0)
            .clipped()
            .accessibilityHidden(!searchChromeIsExpanded)
    }

    var searchClearButton: some View {
        Button {
            searchText = ""
            searchFieldIsFocused = true
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(AppFont.subheadline())
                .foregroundStyle(.secondary)
                .frame(width: Self.searchChromeIconVisualSize, height: Self.searchChromeIconVisualSize)
                .frame(width: Self.searchChromeIconHitTarget, height: Self.searchChromeIconHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Clear search")
    }

    var searchTrailingButton: some View {
        HapticButton(feedbackStyle: .medium) {
            if searchChromeIsExpanded {
                closeSearch()
            } else {
                navigationState.select(.settings(nil))
            }
        } label: {
            ZStack {
                Image(systemName: AppShellSettingsAction.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: Self.searchChromeIconVisualSize, height: Self.searchChromeIconVisualSize)
                    .opacity(searchChromeIsExpanded ? 0 : 1)
                    .scaleEffect(searchChromeIsExpanded ? 0.72 : 1)
                    .rotationEffect(.degrees(searchChromeIsExpanded ? -18 : 0))

                Image(systemName: "xmark")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: Self.searchChromeIconVisualSize, height: Self.searchChromeIconVisualSize)
                    .opacity(searchChromeIsExpanded ? 1 : 0)
                    .scaleEffect(searchChromeIsExpanded ? 1 : 0.72)
                    .rotationEffect(.degrees(searchChromeIsExpanded ? 0 : 18))
            }
            .frame(width: Self.searchChromeIconHitTarget, height: Self.searchChromeIconHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(searchChromeIsExpanded ? "Close search" : "Settings")
        .accessibilityHint(
            searchChromeIsExpanded
                ? "Closes search and clears the current query."
                : "Opens Settings. Long press to switch servers."
        )
        // Long-press the settings control to switch the active server, reusing #17's
        // switch/add actions. Suppressed while search is expanded so the
        // "close search" tap state is untouched (#283). The plain tap above is
        // preserved — `contextMenu` adds long-press without stealing the tap.
        .contextMenu {
            if !searchChromeIsExpanded {
                AvatarServerSwitcherMenu(
                    model: AvatarServerSwitcherModel(
                        servers: authManager.servers,
                        activeServerID: authManager.activeServerID
                    ),
                    switchToServer: { account in
                        authManager.switchActiveServer(to: account)
                    },
                    addServer: { isPresentingAddServer = true },
                    manageServers: { navigationState.select(.settings(.servers)) }
                )
            }
        }
    }

    var isSearchingSessions: Bool {
        isSearchVisible || isSearchFocused
    }

    func closeSearch() {
        searchText = ""
        searchFieldIsFocused = false
        isSearchFocused = false

        withAnimation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion)) {
            searchChromeIsExpanded = false
            isSearchVisible = false
        }
    }

    func openSearch() {
        withAnimation(SessionListMotion.searchChromeAnimation(reduceMotion: reduceMotion)) {
            isSearchVisible = true
            searchChromeIsExpanded = true
        }
        searchFieldIsFocused = true
    }

    func openSearchFromKeyboard() {
        searchFieldIsFocused = false

        if horizontalSizeClass != .regular {
            navigationState.clearDestination()
        }

        Task { @MainActor in
            await Task.yield()
            openSearch()
        }
    }

    func handleSearchFieldFocusChange(_ isFocused: Bool) {
        guard isFocused else {
            isSearchFocused = false
            return
        }

        guard searchChromeIsExpanded || isSearchVisible else {
            searchFieldIsFocused = false
            isSearchFocused = false
            return
        }

        isSearchFocused = true
    }

}
