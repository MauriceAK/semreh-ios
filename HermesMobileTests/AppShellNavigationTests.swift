import XCTest
@testable import HermesMobile

@MainActor
final class AppShellNavigationTests: XCTestCase {
    func testBirdTabUsesNonemptyTemplateArtwork() {
        let image = BirdTabIcon.image
        XCTAssertEqual(image.size.width, 25, accuracy: 0.1)
        XCTAssertEqual(image.size.height, 25, accuracy: 0.1)
        XCTAssertEqual(image.renderingMode, .alwaysTemplate)
        XCTAssertNotNil(image.cgImage)
    }

    func testRootSettingsActionUsesOneGearDestination() {
        XCTAssertEqual(AppShellSettingsAction.systemImage, "gearshape")
        XCTAssertEqual(AppShellSettingsAction.accessibilityLabel, "Settings")
    }

    func testToolsDestinationOmitsSettingsAndServerLoopRows() {
        let tools = ControlView(
            authManager: AuthManager(),
            server: URL(staticString: "https://example.test"),
            showsConnectionRows: false
        )
        XCTAssertFalse(tools.showsConnectionRows)
    }

    func testBotProfileRoutesKeepExactProfileForChatAndSessionsFilter() throws {
        let profile = ProfileSummary(
            name: " research ",
            path: nil,
            isDefault: true,
            isActive: true,
            gatewayRunning: true,
            model: "model-a",
            provider: "provider-a",
            hasEnv: true,
            skillCount: 3
        )
        let name = try XCTUnwrap(profile.normalizedName)

        let chatRequest = NewChatRequest(profileName: name)
        let filterRequest = SessionFilterRequest(profileName: "  \(name)  ")

        XCTAssertEqual(chatRequest.profileName, name)
        XCTAssertEqual(filterRequest.profileName, name)
        XCTAssertNotEqual(chatRequest.id, filterRequest.id)
        XCTAssertTrue(SessionShellFilter.matches(
            SessionSummary(sessionId: "session-1", profile: name),
            bot: filterRequest.profileName,
            pinnedOnly: false
        ))
    }

    func testSessionFilterRequestRejectsNoProfileMutationAndSupportsRepeatRoutes() {
        let first = SessionFilterRequest(profileName: "work")
        let second = SessionFilterRequest(profileName: "work")

        XCTAssertEqual(first.profileName, second.profileName)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(NewChatRequest(profileName: first.profileName).profileName, "work")
    }

    func testProfileHistoryRouteClearsConflictingSessionFilters() throws {
        let route = try XCTUnwrap(
            SessionFilterRoutePolicy.profileHistoryRoute(profileName: "  research ")
        )

        XCTAssertEqual(route.profileName, "research")
        XCTAssertFalse(route.pinnedOnly)
        XCTAssertFalse(route.scheduledHistoryOnly)
        XCTAssertNil(route.projectID)
        XCTAssertEqual(route.searchText, "")
    }

    func testProfileHistoryRouteRejectsBlankProfileNames() {
        XCTAssertNil(SessionFilterRoutePolicy.profileHistoryRoute(profileName: "  \n"))
    }

    func testSessionDepartureResetsButIntentionalIncomingRoutesDoNot() {
        XCTAssertTrue(AppShellSessionReturnPolicy.resetsOnDeparture(from: .sessions, to: .control))
        XCTAssertTrue(AppShellSessionReturnPolicy.resetsOnDeparture(from: .sessions, to: .you))
        XCTAssertFalse(AppShellSessionReturnPolicy.resetsOnDeparture(from: .control, to: .sessions))
        XCTAssertFalse(AppShellSessionReturnPolicy.resetsOnDeparture(from: .you, to: .sessions))
        XCTAssertFalse(AppShellSessionReturnPolicy.resetsOnDeparture(from: .sessions, to: .sessions))
    }

    func testEmptyShellProjectsHideButSelectionKeepsClearFilterReachable() {
        XCTAssertFalse(AppShellOrganizerPolicy.showsProjects(isShell: true, hasProjects: false, hasSelection: false))
        XCTAssertTrue(AppShellOrganizerPolicy.showsProjects(isShell: true, hasProjects: true, hasSelection: false))
        XCTAssertTrue(AppShellOrganizerPolicy.showsProjects(isShell: true, hasProjects: false, hasSelection: true))
        XCTAssertTrue(AppShellOrganizerPolicy.showsProjects(isShell: false, hasProjects: false, hasSelection: false))
    }

    func testPrimaryTabsSeparateBotConfigurationFromSessionsAndActivity() {
        XCTAssertEqual(AppShellSurface.primaryTabs, [.control, .sessions, .you])
    }
    func testPrimarySurfacesHaveStableOrderAndLabels() {
        XCTAssertEqual(AppShellSurface.allCases, [.control, .sessions, .you])
        XCTAssertEqual(AppShellSurface.sessions.title, "Sessions")
        XCTAssertEqual(AppShellSurface.control.title, "Bots")
        XCTAssertEqual(AppShellSurface.you.title, "Activity")
    }

    func testOnlySessionsOffersTheShellPrimaryAction() {
        XCTAssertTrue(AppShellSurface.sessions.showsPrimaryAction)
        XCTAssertFalse(AppShellSurface.control.showsPrimaryAction)
        XCTAssertFalse(AppShellSurface.you.showsPrimaryAction)
    }

    func testSessionBotAndPinFiltersIntersectWithoutChangingMissingProfileMeaning() throws {
        let rows = try JSONDecoder().decode([SessionSummary].self, from: Data(#"[{"id":"1","profile":"research","pinned":true},{"id":"2","profile":"default","pinned":false},{"id":"3","pinned":true}]"#.utf8))
        XCTAssertEqual(rows.filter { SessionShellFilter.matches($0, bot: nil, pinnedOnly: false) }.count, 3)
        XCTAssertEqual(rows.filter { SessionShellFilter.matches($0, bot: nil, pinnedOnly: true) }.count, 2)
        XCTAssertEqual(rows.filter { SessionShellFilter.matches($0, bot: "research", pinnedOnly: true) }.count, 1)
        XCTAssertEqual(rows.filter { SessionShellFilter.matches($0, bot: "default", pinnedOnly: true) }.count, 0)
    }

    func testBotCatalogDropsMissingAndDuplicateNormalizedNames() throws {
        let data = Data(#"[{"name":"default"},{"name":" default "},{"name":""},{},{"name":"research"}]"#.utf8)
        let profiles = try JSONDecoder().decode([ProfileSummary].self, from: data)
        let unique = AppShellBotCatalog.uniqueProfiles(profiles)
        XCTAssertEqual(unique.compactMap(\.normalizedName), ["default", "research"])
        XCTAssertEqual(unique.first?.name, "default")
    }

    func testShellLoadRejectsCancelledReplacedDepartedAndOtherServerResponses() {
        let server = URL(staticString: "https://one.example.test")
        let request = AppShellLoadIdentity(server: server)
        let reentered = AppShellLoadIdentity(server: server)
        XCTAssertTrue(request.accepts(current: request, cancelled: false))
        XCTAssertFalse(request.accepts(current: request, cancelled: true))
        XCTAssertFalse(request.accepts(current: nil, cancelled: false))
        XCTAssertFalse(request.accepts(current: reentered, cancelled: false))
        XCTAssertTrue(reentered.accepts(current: reentered, cancelled: false))
        XCTAssertFalse(request.accepts(
            current: AppShellLoadIdentity(server: URL(staticString: "https://two.example.test")),
            cancelled: false
        ))
    }

    func testActivityScopeUsesInventoryDefaultWhenCurrentIsAbsent() throws {
        let data = Data(#"{"profiles":[{"name":"research"},{"name":"configured-default","isDefault":true}]}"#.utf8)
        let inventory = try JSONDecoder().decode(ProfilesResponse.self, from: data)
        XCTAssertEqual(AppShellActivityScope.resolve(current: nil, inventory: inventory), "configured-default")
        XCTAssertEqual(AppShellActivityScope.resolve(current: "  ", inventory: inventory), "configured-default")
        XCTAssertEqual(AppShellActivityScope.resolve(current: "running", inventory: inventory), "running")
    }

    func testActivityScopeWithNoCurrentOrInventoryProfileIsUnavailable() {
        let inventory = ProfilesResponse(profiles: [], active: nil, singleProfileMode: nil)
        XCTAssertNil(AppShellActivityScope.resolve(current: nil, inventory: inventory))
        XCTAssertNil(AppShellActivityScope.resolve(current: nil, inventory: nil))
    }

    func testLegacySurfaceRawValuesRemainStableForExistingRoutes() {
        XCTAssertEqual(AppShellSurface.sessions.rawValue, "sessions")
        XCTAssertEqual(AppShellSurface.control.rawValue, "control")
        XCTAssertEqual(AppShellSurface.you.rawValue, "you")
    }

    func testProductionSessionsAndControlEnableTheLocalOrganizer() {
        XCTAssertTrue(AppShellOrganizerPolicy.projectsEnabled)
    }

    func testShellSessionsShowsOnlyOrganizerWhenEnabledAndVisible() throws {
        let visibility = try XCTUnwrap(
            SessionListUtilityRowsVisibilityPolicy.visibleSections(
                usesShellChrome: true,
                projectsEnabled: true,
                isSearchingSessions: false,
                userVisibility: .showAll
            )
        )

        XCTAssertEqual(
            visibility,
            SidebarSectionVisibility(
                tasks: false,
                kanban: false,
                skills: false,
                memory: false,
                insights: false,
                activeProfile: false,
                projects: true
            )
        )
    }

    func testShellSessionsHidesOrganizerWhenDisabledHiddenOrSearching() {
        var projectsHidden = SidebarSectionVisibility.showAll
        projectsHidden.projects = false

        XCTAssertNil(
            SessionListUtilityRowsVisibilityPolicy.visibleSections(
                usesShellChrome: true,
                projectsEnabled: false,
                isSearchingSessions: false,
                userVisibility: .showAll
            )
        )
        XCTAssertNil(
            SessionListUtilityRowsVisibilityPolicy.visibleSections(
                usesShellChrome: true,
                projectsEnabled: true,
                isSearchingSessions: false,
                userVisibility: projectsHidden
            )
        )
        XCTAssertNil(
            SessionListUtilityRowsVisibilityPolicy.visibleSections(
                usesShellChrome: true,
                projectsEnabled: true,
                isSearchingSessions: true,
                userVisibility: .showAll
            )
        )
    }

    func testNonShellUtilityRowsPreserveUserVisibilityUnlessSearching() {
        let userVisibility = SidebarSectionVisibility(
            tasks: true,
            kanban: false,
            skills: true,
            memory: false,
            insights: true,
            activeProfile: true,
            projects: false
        )

        XCTAssertEqual(
            SessionListUtilityRowsVisibilityPolicy.visibleSections(
                usesShellChrome: false,
                projectsEnabled: true,
                isSearchingSessions: false,
                userVisibility: userVisibility
            ),
            userVisibility
        )
        var organizerDisabledVisibility = userVisibility
        organizerDisabledVisibility.projects = false
        var projectsVisible = userVisibility
        projectsVisible.projects = true
        XCTAssertEqual(
            SessionListUtilityRowsVisibilityPolicy.visibleSections(
                usesShellChrome: false,
                projectsEnabled: false,
                isSearchingSessions: false,
                userVisibility: projectsVisible
            ),
            organizerDisabledVisibility
        )
        XCTAssertNil(
            SessionListUtilityRowsVisibilityPolicy.visibleSections(
                usesShellChrome: false,
                projectsEnabled: true,
                isSearchingSessions: true,
                userVisibility: userVisibility
            )
        )
    }

    func testNestedControlDestinationHidesBothShellBarsAndResetsOnReentry() {
        var navigationState = ControlNavigationState()

        XCTAssertFalse(navigationState.isNestedDestinationPresented)
        XCTAssertTrue(
            AppShellChromePolicy.showsTopBar(
                surface: .control,
                isSessionConversationPresented: false,
                isControlDestinationPresented: false
            )
        )
        XCTAssertTrue(
            AppShellChromePolicy.showsBottomBar(
                isConversationPresented: false,
                isControlDestinationPresented: false
            )
        )

        navigationState.select(.tasks)

        XCTAssertTrue(navigationState.isNestedDestinationPresented)
        XCTAssertFalse(
            AppShellChromePolicy.showsTopBar(
                surface: .control,
                isSessionConversationPresented: false,
                isControlDestinationPresented: true
            )
        )
        XCTAssertFalse(
            AppShellChromePolicy.showsBottomBar(
                isConversationPresented: false,
                isControlDestinationPresented: true
            )
        )

        navigationState.resetForSurfaceDeactivation()

        XCTAssertFalse(navigationState.isNestedDestinationPresented)
    }

    func testSessionNavigationStateMarksOnlyConversationDestinationsAsConversation() {
        var state = SessionNavigationState()
        XCTAssertFalse(state.isConversationPresented)

        state.select(SessionSummary(sessionId: "session-1", title: "One"))
        XCTAssertTrue(state.isConversationPresented)

        state.clearDestination()
        state.select(.settings(nil))
        XCTAssertFalse(state.isConversationPresented)

        state.resetForShellSurfaceSwitch()
        XCTAssertNil(state.destination)
        XCTAssertNil(state.lastSelectedSessionID)
    }

    func testMessagesStyleUsesShellOnlyAsAnOptIn() {
        let session = SessionSummary(sessionId: "session-1", title: "One")
        let standard = SessionListRowsSection(
            viewModel: SessionListViewModel(server: URL(staticString: "https://example.test")),
            sessions: [session],
            emptyTitle: "Empty",
            emptyDescription: nil,
            isSearchActive: false,
            showsMessageCount: true,
            showsWorkspace: true,
            selectedSessionID: nil,
            actions: Self.noopActions
        )
        let shell = SessionListRowsSection(
            viewModel: SessionListViewModel(server: URL(staticString: "https://example.test")),
            sessions: [session],
            emptyTitle: "Empty",
            emptyDescription: nil,
            isSearchActive: false,
            showsMessageCount: true,
            showsWorkspace: true,
            selectedSessionID: nil,
            actions: Self.noopActions,
            useMessagesStyle: true,
            showsSectionHeader: false
        )

        XCTAssertFalse(standard.useMessagesStyle)
        XCTAssertTrue(shell.useMessagesStyle)
        XCTAssertTrue(standard.showsSectionHeader)
        XCTAssertFalse(shell.showsSectionHeader)
    }

    private static var noopActions: SessionListRowActions {
        SessionListRowActions(
            retryLoad: {},
            open: { _ in },
            togglePinned: { _ in },
            archive: { _ in },
            delete: { _ in },
            rename: { _ in },
            duplicate: { _ in },
            move: { _, _ in },
            createProject: { _ in },
            refreshProjects: {},
            export: { _, _ in }
        )
    }

}
