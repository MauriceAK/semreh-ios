import XCTest
@testable import HermesMobile

final class SessionNavigationStateTests: XCTestCase {
    func testSelectingSessionUpdatesDestinationAndRestorationID() {
        let session = SessionSummary(sessionId: "session-1", title: "One")
        var state = SessionNavigationState()

        state.select(session)

        XCTAssertEqual(state.destination, .session(session))
        XCTAssertEqual(state.selectedSessionID, "session-1")
        XCTAssertEqual(state.lastSelectedSessionID, "session-1")
    }

    func testRestoreSelectsStoredSessionWhenItStillExists() {
        let first = SessionSummary(sessionId: "session-1", title: "One")
        let second = SessionSummary(sessionId: "session-2", title: "Two")
        var state = SessionNavigationState(lastSelectedSessionID: "session-2")

        state.restoreIfNeeded(from: [first, second])

        XCTAssertEqual(state.destination, .session(second))
        XCTAssertEqual(state.lastSelectedSessionID, "session-2")
    }

    func testRestoreClearsStoredSelectionWhenSessionNoLongerExists() {
        var state = SessionNavigationState(lastSelectedSessionID: "missing")

        state.restoreIfNeeded(from: [SessionSummary(sessionId: "session-1")])

        XCTAssertNil(state.destination)
        XCTAssertNil(state.lastSelectedSessionID)
    }

    func testRestorePreservesStoredSelectionWhenSessionListIsNotAuthoritative() {
        var state = SessionNavigationState(lastSelectedSessionID: "session-1")

        state.restoreIfNeeded(from: [], clearsMissingSelection: false)

        XCTAssertNil(state.destination)
        XCTAssertEqual(state.lastSelectedSessionID, "session-1")
    }

    func testRestoreSkipsWhileDeepLinkIsPendingAndKeepsStoredSelection() {
        let stored = SessionSummary(sessionId: "stored")
        var state = SessionNavigationState(lastSelectedSessionID: "stored")

        state.restoreIfNeeded(from: [stored], pendingDeepLinkedSessionID: "deep-linked")

        XCTAssertNil(state.destination)
        XCTAssertEqual(state.lastSelectedSessionID, "stored")
    }

    func testRestoreSkipsAfterPendingDeepLinkIsConsumedWhileLoadIsInFlight() {
        let stored = SessionSummary(sessionId: "stored")
        var state = SessionNavigationState(lastSelectedSessionID: "stored")

        let deepLinkedSessionID = state.beginDeepLinkedSessionLoad(id: "deep-linked")
        state.restoreIfNeeded(from: [stored], pendingDeepLinkedSessionID: nil)

        XCTAssertEqual(deepLinkedSessionID, "deep-linked")
        XCTAssertNil(state.destination)
        XCTAssertEqual(state.lastSelectedSessionID, "stored")

        state.finishDeepLinkedSessionLoad(id: deepLinkedSessionID)
        state.restoreIfNeeded(from: [stored], pendingDeepLinkedSessionID: nil)

        XCTAssertEqual(state.destination, .session(stored))
    }

    func testRestoreProceedsWhenPendingDeepLinkIDIsBlank() {
        let stored = SessionSummary(sessionId: "stored")
        var state = SessionNavigationState(lastSelectedSessionID: "stored")

        state.restoreIfNeeded(from: [stored], pendingDeepLinkedSessionID: "   ")

        XCTAssertEqual(state.destination, .session(stored))
    }

    func testInitialRefreshStartsBeforeDelayedDeepLinkFinishes() async {
        let recorder = SessionInitialLoadEventRecorder()

        await SessionListInitialLoad.run(
            resolvePendingDeepLink: {
                await recorder.record(.deepLinkStarted)
                try? await Task.sleep(nanoseconds: 50_000_000)
                await recorder.record(.deepLinkFinished)
            },
            refreshSessionsAndActiveProfile: {
                await recorder.record(.refreshStarted)
            },
            restoreLastSelectedSession: { _ in }
        )

        let events = await recorder.snapshot()
        guard let refreshIndex = events.firstIndex(of: .refreshStarted),
              let deepLinkFinishIndex = events.firstIndex(of: .deepLinkFinished)
        else {
            return XCTFail("Expected both refresh and deep-link completion events")
        }

        XCTAssertLessThan(refreshIndex, deepLinkFinishIndex)
    }

    func testInitialRestoreDoesNotWaitForDelayedNetworkRefresh() async {
        let recorder = SessionInitialLoadEventRecorder()

        await SessionListInitialLoad.run(
            resolvePendingDeepLink: {
                await recorder.record(.deepLinkStarted)
                await recorder.record(.deepLinkFinished)
            },
            refreshSessionsAndActiveProfile: {
                await recorder.record(.refreshStarted)
                try? await Task.sleep(nanoseconds: 100_000_000)
                await recorder.record(.refreshFinished)
            },
            restoreLastSelectedSession: { _ in
                await recorder.record(.restoredSelection)
            }
        )

        let events = await recorder.snapshot()
        let deepLinkFinishIndex = events.firstIndex(of: .deepLinkFinished)
        let restoredIndex = events.firstIndex(of: .restoredSelection)
        let refreshFinishIndex = events.firstIndex(of: .refreshFinished)

        XCTAssertNotNil(deepLinkFinishIndex)
        XCTAssertNotNil(restoredIndex)
        XCTAssertNotNil(refreshFinishIndex)
        XCTAssertLessThan(try! XCTUnwrap(deepLinkFinishIndex), try! XCTUnwrap(restoredIndex))
        XCTAssertLessThan(try! XCTUnwrap(restoredIndex), try! XCTUnwrap(refreshFinishIndex))
    }

    func testInitialRestoreReconcilesAgainAfterNetworkRefresh() async {
        let recorder = SessionInitialLoadEventRecorder()

        await SessionListInitialLoad.run(
            resolvePendingDeepLink: {},
            refreshSessionsAndActiveProfile: {
                await recorder.record(.refreshStarted)
                try? await Task.sleep(nanoseconds: 50_000_000)
                await recorder.record(.refreshFinished)
            },
            restoreLastSelectedSession: { _ in
                await recorder.record(.restoredSelection)
            }
        )

        let events = await recorder.snapshot()
        let restoreIndices = events.indices.filter { events[$0] == .restoredSelection }
        let refreshFinishIndex = try! XCTUnwrap(events.firstIndex(of: .refreshFinished))

        XCTAssertEqual(restoreIndices.count, 2)
        XCTAssertLessThan(try! XCTUnwrap(restoreIndices.first), refreshFinishIndex)
        XCTAssertGreaterThan(try! XCTUnwrap(restoreIndices.last), refreshFinishIndex)
    }

    func testInitialRestoreIsOptimisticBeforeRefreshAndAuthoritativeAfterward() async {
        let recorder = SessionRestoreAuthorityRecorder()

        await SessionListInitialLoad.run(
            resolvePendingDeepLink: {},
            refreshSessionsAndActiveProfile: {
                try? await Task.sleep(nanoseconds: 20_000_000)
            },
            restoreLastSelectedSession: { clearsMissingSelection in
                await recorder.record(clearsMissingSelection)
            }
        )

        let authorityValues = await recorder.snapshot()
        XCTAssertEqual(authorityValues, [false, true])
    }

    @MainActor
    func testInitialRestorePreservesSavedSessionAcrossEmptyCacheUntilLiveRefresh() async {
        let saved = SessionSummary(sessionId: "saved", title: "Saved")
        var state = SessionNavigationState(lastSelectedSessionID: saved.sessionId)
        var visibleSessions: [SessionSummary] = []

        await SessionListInitialLoad.run(
            resolvePendingDeepLink: {},
            refreshSessionsAndActiveProfile: {
                try? await Task.sleep(nanoseconds: 20_000_000)
                visibleSessions = [saved]
            },
            restoreLastSelectedSession: { clearsMissingSelection in
                if clearsMissingSelection {
                    state.reconcileAuthoritativeSelection(from: visibleSessions)
                } else {
                    state.restoreIfNeeded(
                        from: visibleSessions,
                        clearsMissingSelection: false
                    )
                }
            }
        )

        XCTAssertEqual(state.destination, .session(saved))
        XCTAssertEqual(state.lastSelectedSessionID, saved.sessionId)
    }

    @MainActor
    func testInitialRestorePreservesSavedSessionAcrossStaleCacheUntilLiveRefresh() async {
        let saved = SessionSummary(sessionId: "saved", title: "Saved")
        let stale = SessionSummary(sessionId: "stale", title: "Stale")
        var state = SessionNavigationState(lastSelectedSessionID: saved.sessionId)
        var visibleSessions = [stale]

        await SessionListInitialLoad.run(
            resolvePendingDeepLink: {},
            refreshSessionsAndActiveProfile: {
                try? await Task.sleep(nanoseconds: 20_000_000)
                visibleSessions = [saved]
            },
            restoreLastSelectedSession: { clearsMissingSelection in
                if clearsMissingSelection {
                    state.reconcileAuthoritativeSelection(from: visibleSessions)
                } else {
                    state.restoreIfNeeded(
                        from: visibleSessions,
                        clearsMissingSelection: false
                    )
                }
            }
        )

        XCTAssertEqual(state.destination, .session(saved))
        XCTAssertEqual(state.lastSelectedSessionID, saved.sessionId)
    }

    @MainActor
    func testInitialRestoreEvictsCachedSessionMissingFromAuthoritativeList() async {
        let saved = SessionSummary(sessionId: "saved", title: "Saved")
        let remaining = SessionSummary(sessionId: "remaining", title: "Remaining")
        var state = SessionNavigationState(lastSelectedSessionID: saved.sessionId)
        var visibleSessions = [saved]

        await SessionListInitialLoad.run(
            resolvePendingDeepLink: {},
            refreshSessionsAndActiveProfile: {
                try? await Task.sleep(nanoseconds: 20_000_000)
                visibleSessions = [remaining]
            },
            restoreLastSelectedSession: { clearsMissingSelection in
                if clearsMissingSelection {
                    state.reconcileAuthoritativeSelection(from: visibleSessions)
                } else {
                    state.restoreIfNeeded(
                        from: visibleSessions,
                        clearsMissingSelection: false
                    )
                }
            }
        )

        XCTAssertNil(state.destination)
        XCTAssertNil(state.lastSelectedSessionID)
    }

    @MainActor
    func testAuthoritativeReconcileKeepsExplicitDeepLinkedSessionMissingFromSidebar() async {
        let remaining = SessionSummary(sessionId: "remaining", title: "Remaining")
        let archived = SessionSummary(sessionId: "archived", title: "Archived")
        var state = SessionNavigationState(lastSelectedSessionID: remaining.sessionId)
        var visibleSessions = [remaining]

        await SessionListInitialLoad.run(
            resolvePendingDeepLink: {
                state.select(archived)
            },
            refreshSessionsAndActiveProfile: {
                try? await Task.sleep(nanoseconds: 20_000_000)
                visibleSessions = [remaining]
            },
            restoreLastSelectedSession: { clearsMissingSelection in
                if clearsMissingSelection {
                    state.reconcileAuthoritativeSelection(from: visibleSessions)
                } else {
                    state.restoreIfNeeded(
                        from: visibleSessions,
                        clearsMissingSelection: false
                    )
                }
            }
        )

        XCTAssertEqual(state.destination, .session(archived))
        XCTAssertEqual(state.lastSelectedSessionID, archived.sessionId)
    }

    func testForegroundSessionRefreshRunsOnlyAfterInitialLoadCompletes() {
        XCTAssertFalse(SessionListForegroundRefreshPolicy.shouldRefresh(
            didCompleteInitialLoad: false,
            sceneIsActive: true
        ))
        XCTAssertFalse(SessionListForegroundRefreshPolicy.shouldRefresh(
            didCompleteInitialLoad: true,
            sceneIsActive: false
        ))
        XCTAssertTrue(SessionListForegroundRefreshPolicy.shouldRefresh(
            didCompleteInitialLoad: true,
            sceneIsActive: true
        ))
    }

    func testExplicitNewChatRouteOverridesStoredSelection() {
        let route = PendingNewChatRoute(initialDraft: "Shared draft")
        let created = SessionSummary(sessionId: "created-session")
        var state = SessionNavigationState(lastSelectedSessionID: "session-1")
        XCTAssertTrue(state.beginNewChatCreation(route))
        XCTAssertTrue(state.completeNewChatCreation(created, for: route))

        state.restoreIfNeeded(from: [SessionSummary(sessionId: "session-1")])

        XCTAssertEqual(state.destination, .newChat(session: created, route: route))
        XCTAssertEqual(state.lastSelectedSessionID, "created-session")
    }

    func testExplicitSessionRouteOverridesStoredSelection() {
        let stored = SessionSummary(sessionId: "stored")
        let deepLinked = SessionSummary(sessionId: "deep-linked")
        var state = SessionNavigationState(lastSelectedSessionID: "stored")
        state.select(deepLinked)

        state.restoreIfNeeded(from: [stored])

        XCTAssertEqual(state.destination, .session(deepLinked))
        XCTAssertEqual(state.lastSelectedSessionID, "deep-linked")
    }

    func testNewChatCreationInProgressRejectsDuplicateRequests() {
        let firstRoute = PendingNewChatRoute()
        let secondRoute = PendingNewChatRoute()
        var state = SessionNavigationState()

        XCTAssertTrue(state.beginNewChatCreation(firstRoute))
        XCTAssertFalse(state.beginNewChatCreation(secondRoute))
        XCTAssertTrue(state.isCreatingNewChat)
        XCTAssertNil(state.destination)
    }

    func testCreatedNewChatDestinationCarriesPayloadAndSelection() {
        let route = PendingNewChatRoute(
            initialDraft: "Imported draft",
            initialAttachments: [
                SharedAttachmentImport(
                    filename: "notes.txt",
                    typeIdentifier: "public.text",
                    data: Data("notes".utf8)
                )
            ],
            autoStartsVoiceInput: true,
            profileName: "work"
        )
        let created = SessionSummary(sessionId: "created-session")
        var state = SessionNavigationState()

        XCTAssertTrue(state.beginNewChatCreation(route))
        XCTAssertTrue(state.completeNewChatCreation(created, for: route))
        XCTAssertEqual(
            state.destination,
            .newChat(session: created, route: route)
        )
        XCTAssertEqual(state.selectedSessionID, "created-session")
        XCTAssertFalse(state.isCreatingNewChat)

        guard case let .newChat(destinationSession, destinationRoute) = state.destination else {
            return XCTFail("Expected a created New Chat destination")
        }
        XCTAssertEqual(destinationSession, created)
        XCTAssertEqual(destinationRoute.initialDraft, "Imported draft")
        XCTAssertEqual(destinationRoute.initialAttachments, route.initialAttachments)
        XCTAssertTrue(destinationRoute.autoStartsVoiceInput)
        XCTAssertEqual(destinationRoute.profileName, "work")
    }

    func testCreatedNewChatSkipsInitialMessageReloadButOrdinaryChatLoadsIt() {
        let route = PendingNewChatRoute(initialDraft: "draft")
        let created = SessionSummary(sessionId: "created-session")
        var state = SessionNavigationState()

        XCTAssertTrue(state.beginNewChatCreation(route))
        XCTAssertTrue(state.completeNewChatCreation(created, for: route))
        XCTAssertFalse(state.destination?.loadsInitialMessages == true)

        state.select(SessionSummary(sessionId: "ordinary-session"))
        XCTAssertTrue(state.destination?.loadsInitialMessages == true)
    }

    func testLocalDraftNewChatCompletesWithoutDurableID() {
        let route = PendingNewChatRoute(initialDraft: "direct draft", autoStartsVoiceInput: true)
        let draft = SessionSummary(sessionId: nil, title: "New Chat", profile: "default")
        var state = SessionNavigationState(lastSelectedSessionID: "previous-session")

        XCTAssertTrue(state.beginNewChatCreation(route))
        XCTAssertTrue(state.completeNewChatCreation(draft, for: route))

        XCTAssertFalse(state.isCreatingNewChat)
        XCTAssertEqual(state.destination, .newChat(session: draft, route: route))
        XCTAssertFalse(state.destination?.loadsInitialMessages == true)
        XCTAssertNil(state.selectedSessionID)
        XCTAssertEqual(state.lastSelectedSessionID, "previous-session")
    }

    func testLocalDraftNewChatRejectsStaleRouteWithoutClearingPendingCreation() {
        let pending = PendingNewChatRoute(initialDraft: "pending")
        let stale = PendingNewChatRoute(initialDraft: "stale")
        let draft = SessionSummary(sessionId: nil, title: "New Chat")
        var state = SessionNavigationState(lastSelectedSessionID: "previous-session")

        XCTAssertTrue(state.beginNewChatCreation(pending))
        XCTAssertFalse(state.completeNewChatCreation(draft, for: stale))

        XCTAssertTrue(state.isCreatingNewChat)
        XCTAssertNil(state.destination)
        XCTAssertEqual(state.lastSelectedSessionID, "previous-session")
    }

    func testCancelledLocalDraftNewChatRejectsCompletionAfterCancellation() {
        let route = PendingNewChatRoute(initialDraft: "cancelled")
        let draft = SessionSummary(sessionId: nil, title: "New Chat")
        var state = SessionNavigationState(lastSelectedSessionID: "previous-session")

        XCTAssertTrue(state.beginNewChatCreation(route))
        state.cancelNewChatCreation(for: route)
        XCTAssertFalse(state.completeNewChatCreation(draft, for: route))

        XCTAssertFalse(state.isCreatingNewChat)
        XCTAssertNil(state.destination)
        XCTAssertEqual(state.lastSelectedSessionID, "previous-session")
    }

    func testExternalNewChatRequestsDrainSharedImportBeforeAppIntentAfterCreation() {
        let inFlight = PendingNewChatRoute()
        let sharedImport = PendingNewChatRoute(initialDraft: "shared")
        let appIntent = PendingNewChatRoute(autoStartsVoiceInput: true)
        var state = SessionNavigationState()

        XCTAssertTrue(state.beginNewChatCreation(inFlight))
        XCTAssertEqual(
            SessionNewChatExternalRequestPolicy.next(
                sharedImportPending: true,
                appIntentPending: true
            ),
            .sharedImport
        )
        XCTAssertFalse(state.beginNewChatCreation(sharedImport))
        XCTAssertFalse(state.beginNewChatCreation(appIntent))

        XCTAssertTrue(state.completeNewChatCreation(SessionSummary(sessionId: "first"), for: inFlight))
        XCTAssertTrue(state.beginNewChatCreation(sharedImport))
        state.cancelNewChatCreation(for: sharedImport)
        XCTAssertFalse(state.isCreatingNewChat)
        XCTAssertTrue(state.beginNewChatCreation(appIntent))
        XCTAssertEqual(
            SessionNewChatExternalRequestPolicy.next(
                sharedImportPending: false,
                appIntentPending: true
            ),
            .appIntent
        )
    }

    func testFailedOrCancelledNewChatReleasesCreationGateForPendingRequest() {
        let first = PendingNewChatRoute()
        let pending = PendingNewChatRoute(initialDraft: "queued")
        var state = SessionNavigationState()

        XCTAssertTrue(state.beginNewChatCreation(first))
        state.cancelNewChatCreation(for: first)
        XCTAssertFalse(state.isCreatingNewChat)
        XCTAssertTrue(state.beginNewChatCreation(pending))
        state.cancelNewChatCreation(for: pending)

        XCTAssertTrue(state.beginNewChatCreation(first))
        XCTAssertTrue(state.completeNewChatCreation(SessionSummary(sessionId: "created"), for: first))
        XCTAssertFalse(state.isCreatingNewChat)
    }

    func testReturningFromCreatedNewChatClearsSelectionAndRunsCleanup() {
        let route = PendingNewChatRoute()
        let created = SessionSummary(sessionId: "created-session")
        var state = SessionNavigationState()
        XCTAssertTrue(state.beginNewChatCreation(route))
        XCTAssertTrue(state.completeNewChatCreation(created, for: route))
        let oldDestination = state.destination
        state.clearDestination()

        XCTAssertNil(state.destination)
        XCTAssertNil(state.selectedSessionID)
        XCTAssertFalse(state.isCreatingNewChat)

        var events: [NewChatReturnEvent] = []
        SessionListNewChatReturn.run(
            from: oldDestination,
            to: state.destination,
            suppressEmptyPlaceholders: { events.append(.suppressedPlaceholders) },
            refreshSessions: { events.append(.refreshedSessions) }
        )
        XCTAssertEqual(events, [.suppressedPlaceholders, .refreshedSessions])
    }

    func testOrdinarySessionDestinationRemainsUnchanged() {
        let session = SessionSummary(sessionId: "ordinary-session")
        var state = SessionNavigationState()

        state.select(session)

        XCTAssertEqual(state.destination, .session(session))
        XCTAssertEqual(state.selectedSessionID, "ordinary-session")
        XCTAssertFalse(state.isCreatingNewChat)
    }

    func testNewChatDestinationSuppressesBottomShell() {
        var navigationState = SessionNavigationState()
        let route = PendingNewChatRoute()
        XCTAssertTrue(navigationState.beginNewChatCreation(route))
        XCTAssertTrue(
            navigationState.completeNewChatCreation(
                SessionSummary(sessionId: "created-session"),
                for: route
            )
        )

        XCTAssertFalse(
            AppShellChromePolicy.showsBottomBar(
                isConversationPresented: navigationState.isConversationPresented
            )
        )
    }

    func testRemovingSelectedSessionClearsDestinationAndRestorationID() {
        let session = SessionSummary(sessionId: "session-1")
        var state = SessionNavigationState()
        state.select(session)

        state.remove(sessionID: "session-1")

        XCTAssertNil(state.destination)
        XCTAssertNil(state.lastSelectedSessionID)
    }

    func testRemovingRememberedSessionPreservesDifferentVisibleDestination() {
        var state = SessionNavigationState(lastSelectedSessionID: "session-1")
        state.select(SessionListUtilityDestination.tasks)

        state.remove(sessionID: "session-1")

        XCTAssertEqual(state.destination, .utility(.tasks))
        XCTAssertNil(state.lastSelectedSessionID)
    }

    func testUtilityDestinationRemainsSelectedAcrossLayoutReevaluation() {
        var state = SessionNavigationState()
        state.select(SessionListUtilityDestination.settings(nil))

        let reevaluatedState = state

        XCTAssertEqual(reevaluatedState.destination, .utility(.settings(nil)))
        XCTAssertNil(reevaluatedState.selectedSessionID)
    }

    func testKanbanIsSelectableAsAUtilityDestination() {
        var state = SessionNavigationState()

        state.select(SessionListUtilityDestination.kanban)

        XCTAssertEqual(state.destination, .utility(.kanban))
        XCTAssertNil(state.selectedSessionID)
    }

    func testReselectingRootDestinationAdvancesNavigationRevision() {
        var state = SessionNavigationState()
        state.select(SessionListUtilityDestination.skills)
        let firstRevision = state.rootRevision

        state.select(SessionListUtilityDestination.skills)

        XCTAssertEqual(state.destination, .utility(.skills))
        XCTAssertGreaterThan(state.rootRevision, firstRevision)
    }

    func testReadableContentWidthsKeepSecondaryAndWorkspaceSurfacesDistinct() {
        XCTAssertEqual(AdaptiveReadableContentWidth.secondaryDestination, 800)
        XCTAssertEqual(AdaptiveReadableContentWidth.workspace, 1_000)
        XCTAssertLessThan(
            AdaptiveReadableContentWidth.secondaryDestination,
            AdaptiveReadableContentWidth.workspace
        )
    }

    func testPersistenceUsesIndependentKeysPerServer() throws {
        let suiteName = "SessionNavigationStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstServer = try XCTUnwrap(URL(string: "https://first.example.com"))
        let secondServer = try XCTUnwrap(URL(string: "https://second.example.com"))

        SessionNavigationPersistence.save("first-session", for: firstServer, defaults: defaults)
        SessionNavigationPersistence.save("second-session", for: secondServer, defaults: defaults)

        XCTAssertEqual(
            SessionNavigationPersistence.load(for: firstServer, defaults: defaults),
            "first-session"
        )
        XCTAssertEqual(
            SessionNavigationPersistence.load(for: secondServer, defaults: defaults),
            "second-session"
        )
    }
}

private enum NewChatReturnEvent: Equatable {
    case suppressedPlaceholders
    case refreshedSessions
}

private actor SessionInitialLoadEventRecorder {
    enum Event: Equatable {
        case deepLinkStarted
        case refreshStarted
        case deepLinkFinished
        case restoredSelection
        case refreshFinished
    }

    private var events: [Event] = []

    func record(_ event: Event) {
        events.append(event)
    }

    func snapshot() -> [Event] {
        events
    }
}

private actor SessionRestoreAuthorityRecorder {
    private var values: [Bool] = []

    func record(_ value: Bool) {
        values.append(value)
    }

    func snapshot() -> [Bool] {
        values
    }
}
