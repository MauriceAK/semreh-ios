import SwiftUI
import UIKit
import XCTest
import Vision
import SwiftData
@testable import HermesMobile

@MainActor
final class ChatTranscriptViewRestoreTests: XCTestCase {
    func testHostedUnitRootIsolationFlagsAreEffective() {
        XCTAssertTrue(ProcessInfo.processInfo.arguments.contains("--semreh-unit-test-host"),
            "Unit TestAction must use its own args rather than inheriting LaunchAction")
        XCTAssertNotNil(ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"],
            "The neutral root must also be gated by actual XCTest host configuration")
    }

    func testMountedReadinessChecksPredicateOnDelayedFinalResumption() async throws {
        var instant = ContinuousClock().now
        var ready = false
        var suspensions = 0
        let satisfied = try await MountedReadinessWait.poll(
            condition: { ready }, now: { instant }, suspend: {
                suspensions += 1
                instant = instant.advanced(by: .seconds(4))
                ready = true
            })
        XCTAssertTrue(satisfied, "Read readiness before rejecting a delayed final resumption")
        XCTAssertEqual(suspensions, 1, "Do not add a post-deadline sleep or retry")
    }

    func testMountedReadinessStopsUnreadyAtOriginalBudget() async throws {
        var instant = ContinuousClock().now
        var suspensions = 0
        let satisfied = try await MountedReadinessWait.poll(
            condition: { false }, now: { instant }, suspend: {
                suspensions += 1
                instant = instant.advanced(by: .seconds(3))
            })
        XCTAssertFalse(satisfied)
        XCTAssertEqual(suspensions, 1, "Preserve the three-second setup budget")
    }

    func testMountedReadinessPropagatesCancellation() async throws {
        do {
            _ = try await MountedReadinessWait.poll(condition: { false }, suspend: {
                throw CancellationError()
            })
            XCTFail("Cancellation must escape the readiness helper")
        } catch is CancellationError {
            // Cancellation must not be rewritten as a setup timeout.
        }
    }

    // Controlled gateway mock, mounted production ChatView and native keyboard Send.
    // These are composer ownership regressions, not live Hermes/network evidence.
    func testMountedSteerRejectionAndTransportFailureRetainDraft() async throws {
        for explicit in [true, false] {
            for response in [MountedSteerResponse.rejected, .transportFailure] {
                let fixture = try await makeMountedSteerFixture()
                let submitted = explicit ? "/steer follow-up" : "follow-up"
                try await fixture.submit(submitted)
                XCTAssertEqual(try fixture.composer().text, submitted, "Keep text while acceptance is unknown")
                XCTAssertEqual(fixture.persistedDraft, submitted)
                await fixture.resolve(response)
                try await fixture.waitForResult(response)
                XCTAssertEqual(try fixture.composer().text, submitted)
                XCTAssertEqual(fixture.persistedDraft, submitted)
                await fixture.assertOnlySteer(text: "follow-up")
                await fixture.close()
            }
        }
    }

    func testMountedSteerAcceptanceClearsUnchangedDraft() async throws {
        for explicit in [true, false] {
            let fixture = try await makeMountedSteerFixture()
            try await fixture.submit(explicit ? "/steer follow-up" : "follow-up")
            await fixture.resolve(.accepted)
            try await fixture.waitForResult(.accepted)
            XCTAssertEqual(try fixture.composer().text, "")
            XCTAssertEqual(fixture.persistedDraft, "")
            XCTAssertEqual(fixture.model.pinnedLocalNotices, ["Steering hint delivered."])
            await fixture.assertOnlySteer(text: "follow-up")
            await fixture.close()
        }
    }

    func testMountedSteerDelayedResponsesRetainInterveningEdit() async throws {
        for explicit in [true, false] {
            for response in [MountedSteerResponse.accepted, .rejected] {
                let fixture = try await makeMountedSteerFixture()
                try await fixture.submit(explicit ? "/steer follow-up" : "follow-up")
                try fixture.edit("newer composer edit")
                await fixture.drain()
                await fixture.resolve(response)
                try await fixture.waitForResult(response)
                XCTAssertEqual(try fixture.composer().text, "newer composer edit")
                XCTAssertEqual(fixture.persistedDraft, "newer composer edit")
                await fixture.assertOnlySteer(text: "follow-up")
                await fixture.close()
            }
        }
    }

    func testMountedSteerClearAndRetypeRetainsDraft() async throws {
        for explicit in [true, false] {
            for response in [MountedSteerResponse.accepted, .rejected] {
                let fixture = try await makeMountedSteerFixture()
                let submitted = explicit ? "/steer follow-up" : "follow-up"
                try await fixture.submit(submitted)
                // No render/drain between edits: production binding must observe
                // both mutations even when the final bytes match the submission.
                try fixture.edit("")
                try fixture.edit(submitted)
                await fixture.drain()
                await fixture.resolve(response)
                try await fixture.waitForResult(response)
                XCTAssertEqual(try fixture.composer().text, submitted)
                XCTAssertEqual(fixture.persistedDraft, submitted)
                await fixture.assertOnlySteer(text: "follow-up")
                await fixture.close()
            }
        }
    }

    func testMountedSteerBackReopenRetiresOldCompletionOwnership() async throws {
        for explicit in [true, false] {
            for response in [MountedSteerResponse.accepted, .rejected] {
                for editsReplacement in [false, true] {
                    let fixture = try await makeMountedSteerFixture()
                    let submitted = explicit ? "/steer follow-up" : "follow-up"
                    try await fixture.submit(submitted)
                    let oldComposer = try fixture.composer()
                    try await fixture.back()
                    XCTAssertNil(oldComposer.window, "Back must actually unmount the old native composer")
                    XCTAssertEqual(fixture.persistedDraft, submitted)
                    try await fixture.reopen()
                    XCTAssertFalse(try fixture.composer() === oldComposer)
                    XCTAssertEqual(try fixture.composer().text, submitted, "Reopen consumes the persisted draft")
                    // Cover both equal bytes with a different writer and a newer
                    // native edit made while the old completion is still blocked.
                    let replacement = editsReplacement ? "replacement writer text" : submitted
                    if editsReplacement {
                        try fixture.edit(replacement)
                        try await fixture.waitForPersistedDraft(replacement)
                    }
                    let persistedBeforeOldCompletion = fixture.persistedDraft
                    XCTAssertEqual(persistedBeforeOldCompletion, replacement)
                    await fixture.resolve(response)
                    try await fixture.waitForResult(response)
                    XCTAssertEqual(try fixture.composer().text, replacement)
                    XCTAssertEqual(fixture.persistedDraft, persistedBeforeOldCompletion,
                        "The retired writer must not overwrite the replacement's established persisted state")
                    try await fixture.back()
                    XCTAssertEqual(fixture.persistedDraft, replacement)
                    try await fixture.reopen()
                    XCTAssertEqual(try fixture.composer().text, replacement)
                    await fixture.assertOnlySteer(text: "follow-up")
                    await fixture.close()
                }
            }
        }
    }

    private func makeMountedSteerFixture() async throws -> MountedSteerFixture {
        // XCTest can enter its first async case before scene activation finishes.
        // Wait for actual foreground ownership; never accept a background render
        // or dismiss a system permission dialog to manufacture mounted proof.
        let deadline = Date().addingTimeInterval(10)
        while !UIApplication.shared.connectedScenes.contains(where: {
            ($0 as? UIWindowScene)?.activationState == .foregroundActive
        }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let fixture = try MountedSteerFixture()
        addTeardownBlock { @MainActor in await fixture.close() }
        try await fixture.start()
        return fixture
    }

    func testLegacyMetricsDeferAndCoalesceUsingFreshGeometry() async {
        let owner = ChatScrollMetricPublication()
        let initial = ChatScrollMetrics(distanceFromBottom: 600, isUserInteracting: false,
            isDirectlyInteracting: false, isDecelerating: false)
        var current = initial
        var received: [ChatScrollMetrics] = []
        let lease = owner.bind(readCurrent: { current }, publish: { received.append($0) })
        for distance in 1...100 {
            owner.submit(.init(distanceFromBottom: CGFloat(distance), isUserInteracting: false,
                isDirectlyInteracting: false, isDecelerating: false), owner: lease)
        }
        XCTAssertTrue(received.isEmpty, "Layout/KVO must never publish synchronously")
        current = .init(distanceFromBottom: 900, isUserInteracting: false,
            isDirectlyInteracting: false, isDecelerating: false)
        let drained = expectation(description: "main queue drain")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertEqual(received, [current], "Delivery re-reads geometry rather than replaying 100")
    }

    func testLegacyMetricsExitFlushPreservesBriefTouchAndOnlyPublishesOnce() async {
        let owner = ChatScrollMetricPublication()
        let touch = ChatScrollMetrics(distanceFromBottom: 500, isUserInteracting: true,
            isDirectlyInteracting: true, isDecelerating: false)
        let settled = ChatScrollMetrics(distanceFromBottom: 700, isUserInteracting: false,
            isDirectlyInteracting: false, isDecelerating: false)
        var received: [ChatScrollMetrics] = []
        let lease = owner.bind(readCurrent: { settled }, publish: { received.append($0) })
        owner.submit(touch, owner: lease)
        owner.submit(settled, owner: lease)
        XCTAssertTrue(owner.hasPendingDirectInteraction, "Follow/restore must yield before state publication")
        owner.flush() // Back action, before capturing immutable restore intent.
        XCTAssertEqual(received, [
            .init(distanceFromBottom: 700, isUserInteracting: true,
                isDirectlyInteracting: true, isDecelerating: false), settled])
        XCTAssertFalse(owner.hasPendingDirectInteraction)
        owner.suspend()
        let drained = expectation(description: "retired drain")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertEqual(received.count, 2, "Queued delivery must not overwrite the exit snapshot")
    }

    func testLegacyMetricsRejectOldLeaseAfterScopeChangeAndWarmReopen() async {
        do {
            let owner = ChatScrollMetricPublication()
            let old = ChatScrollMetrics(distanceFromBottom: 0, isUserInteracting: true,
                isDirectlyInteracting: true, isDecelerating: false)
            let fresh = ChatScrollMetrics(distanceFromBottom: 800, isUserInteracting: false,
                isDirectlyInteracting: false, isDecelerating: false)
            var received: [ChatScrollMetrics] = []
            let retired = owner.bind(readCurrent: { old }, publish: { received.append($0) })
            owner.submit(old, owner: retired)
            owner.suspend()
            // Even a late representable update while leaving cannot reactivate it.
            let suspended = owner.bind(readCurrent: { old }, publish: { received.append($0) })
            owner.submit(old, owner: suspended)
            owner.resume()
            let active = owner.bind(readCurrent: { fresh }, publish: { received.append($0) })
            owner.invalidate(ifOwnedBy: retired) // Late old-view dismantle.
            owner.submit(old, owner: retired)
            owner.submit(fresh, owner: active)
            let drained = expectation(description: "new lease drain")
            DispatchQueue.main.async { drained.fulfill() }
            await fulfillment(of: [drained], timeout: 1)
            XCTAssertEqual(received, [fresh])
        }
    }

    func testLegacyMetricsDropDetachedGeometryAndDoNotRetainOwner() async {
        var owner: ChatScrollMetricPublication? = ChatScrollMetricPublication()
        weak var weakOwner = owner
        let metrics = ChatScrollMetrics(distanceFromBottom: 500, isUserInteracting: false,
            isDirectlyInteracting: false, isDecelerating: false)
        var received: [ChatScrollMetrics] = []
        let lease = owner!.bind(readCurrent: { nil }, publish: { received.append($0) })
        owner!.submit(metrics, owner: lease)
        owner!.flush()
        XCTAssertTrue(received.isEmpty, "A detached viewport has no valid geometry")
        owner = nil
        XCTAssertNil(weakOwner, "The queued drain must not retain a dead owner")
        let drained = expectation(description: "weak drain")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertTrue(received.isEmpty)
    }

    func testLegacyObserverDefersTouchPublicationButCancelsLeaseImmediately() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let scroll = MetricPublicationTestScrollView(frame: window.bounds)
        let observer = UIView(frame: .zero)
        window.addSubview(scroll)
        scroll.addSubview(observer)
        scroll.contentSize = CGSize(width: 400, height: 2000)
        let owner = ChatScrollMetricPublication()
        var received: [ChatScrollMetrics] = []
        var cancellations = 0
        let coordinator = ChatScrollObserver.Coordinator(
            metricContext: .init(isStreaming: false, scope: UUID(), restoreToken: 1, latestToken: nil),
            publication: owner, onDirectInteraction: { cancellations += 1 },
            onMetrics: { received.append($0) }, onContentSizeChange: { _ in },
            onScrollViewReady: { _ in })
        coordinator.attachIfNeeded(from: observer, delivery: .deferred)
        scroll.directTouch = true
        coordinator.reportMetrics(delivery: .deferred)
        XCTAssertEqual(cancellations, 1)
        XCTAssertTrue(received.isEmpty, "The old direct-interaction branch fails this assertion")
        owner.flush()
        XCTAssertEqual(received.count, 1)
        XCTAssertTrue(received[0].isDirectlyInteracting)
        coordinator.detach()
    }

    func testLegacyObserverRetiresPendingTouchForNewScopeRestoreAndLatest() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let scroll = MetricPublicationTestScrollView(frame: window.bounds)
        let observer = UIView(frame: .zero)
        window.addSubview(scroll)
        scroll.addSubview(observer)
        scroll.contentSize = CGSize(width: 400, height: 2000)
        let owner = ChatScrollMetricPublication()
        let scope = UUID()
        var received: [ChatScrollMetrics] = []
        let coordinator = ChatScrollObserver.Coordinator(
            metricContext: .init(isStreaming: false, scope: scope, restoreToken: 1, latestToken: nil),
            publication: owner, onDirectInteraction: {}, onMetrics: { received.append($0) },
            onContentSizeChange: { _ in }, onScrollViewReady: { _ in })
        coordinator.attachIfNeeded(from: observer, delivery: .deferred)
        let nextScope = UUID()
        let contexts: [ChatScrollObserver.MetricContext] = [
            .init(isStreaming: false, scope: nextScope, restoreToken: 1, latestToken: nil),
            .init(isStreaming: false, scope: nextScope, restoreToken: 2, latestToken: nil),
            .init(isStreaming: false, scope: nextScope, restoreToken: 2,
                  latestToken: .init(generation: 1, issue: 1))]
        for context in contexts {
            scroll.directTouch = true
            coordinator.reportMetrics(delivery: .deferred)
            XCTAssertTrue(owner.hasPendingDirectInteraction)
            scroll.directTouch = false
            coordinator.updateMetricContext(context)
            owner.flush()
            XCTAssertTrue(received.isEmpty, "Prior ownership must not publish into a new decision")
            XCTAssertFalse(owner.hasPendingDirectInteraction)
        }
        coordinator.reportMetrics(delivery: .deferred)
        owner.flush()
        XCTAssertEqual(received.count, 1)
        XCTAssertFalse(received[0].isDirectlyInteracting)
        coordinator.detach()
    }

    func testLegacyOldObserverCannotRenewOrDetachReplacementPublication() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let owner = ChatScrollMetricPublication()
        var received: [Int] = []
        var retainedScrolls: [UIScrollView] = []
        var coordinators: [ChatScrollObserver.Coordinator] = []
        for index in 0...1 {
            let scroll = UIScrollView(frame: window.bounds)
            let observer = UIView(frame: .zero)
            window.addSubview(scroll)
            scroll.addSubview(observer)
            scroll.contentSize = CGSize(width: 400, height: 2000)
            let coordinator = ChatScrollObserver.Coordinator(
                metricContext: .init(isStreaming: false, scope: UUID(), restoreToken: 1, latestToken: nil),
                publication: owner, onDirectInteraction: {}, onMetrics: { _ in received.append(index) },
                onContentSizeChange: { _ in }, onScrollViewReady: { _ in })
            coordinator.attachIfNeeded(from: observer, delivery: .deferred)
            retainedScrolls.append(scroll)
            coordinators.append(coordinator)
        }
        coordinators[0].reportMetrics(delivery: .deferred)
        coordinators[0].updateMetricContext(.init(isStreaming: true, scope: UUID(), restoreToken: 2, latestToken: nil))
        coordinators[0].detach()
        owner.flush()
        XCTAssertEqual(received, [1], "Old observations and dismantle must not steal the new lease")
        coordinators[1].detach()
        XCTAssertEqual(retainedScrolls.count, 2)
    }

    func testObserverProducerCancellationDefersProductionRestoreCompletionExactlyOnce() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let scroll = MetricPublicationTestScrollView(frame: window.bounds)
        let observer = UIView(frame: .zero)
        window.addSubview(scroll); scroll.addSubview(observer)
        scroll.contentSize = CGSize(width: 400, height: 2000)
        let publication = ChatScrollMetricPublication()
        let tracker = ChatTranscriptViewportTracker()
        let settlement = ChatWarmReaderSettlement(
            point: .init(messageID: "reader", minY: -40, viewportWidth: 400), scope: nil)
        tracker.warmReaderSettlement = settlement
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1, target: .message(id: "reader"))
        var parent = ChatTranscriptRestoreOutcomeState()
        parent.begin(request)
        var owned: ChatTranscriptRestoreRequest? = request
        var completed = false
        var deliveries = 0
        settlement.bindRestoreCompletion(request, isCurrent: {
            tracker.warmReaderSettlement === settlement && owned == request
        }, complete: { outcome in
            completed = true
            owned = nil
            deliveries += 1
            XCTAssertTrue(parent.complete(request, outcome: outcome, currentScope: request.scope))
        })
        let coordinator = ChatScrollObserver.Coordinator(
            metricContext: .init(isStreaming: false, scope: request.scope, restoreToken: 1, latestToken: nil),
            publication: publication,
            onDirectInteraction: { tracker.cancelCorrectionsFromProducer(restoreTask: nil) },
            onMetrics: { _ in }, onContentSizeChange: { _ in }, onScrollViewReady: { _ in })
        coordinator.attachIfNeeded(from: observer, delivery: .deferred)
        scroll.directTouch = true
        coordinator.reportMetrics(delivery: .deferred)
        XCTAssertFalse(settlement.isActive, "Correction ownership is withdrawn inside layout")
        XCTAssertFalse(completed, "The production completion boundary must not publish inside layout")
        XCTAssertEqual(owned, request)
        XCTAssertEqual(parent.pending, request)
        let drain = expectation(description: "terminal completion drain")
        DispatchQueue.main.async { drain.fulfill() }
        await fulfillment(of: [drain], timeout: 1)
        XCTAssertTrue(completed)
        XCTAssertNil(parent.pending)
        XCTAssertEqual(deliveries, 1)
        settlement.cancel(); publication.flush()
        XCTAssertEqual(deliveries, 1, "Lifecycle cancellation cannot deliver the same terminal twice")
        coordinator.detach()
    }

    func testDeferredWarmCancellationCannotClearReplacementRestoreOrScope() async {
        for changeScope in [false, true] {
            let tracker = ChatTranscriptViewportTracker()
            let memory = ChatWarmReaderMemory()
            let server = URL(string: "https://fixture.invalid")!
            memory.bind(to: .init(server: server, profile: "default", sessionID: "reader"))
            let settlement = ChatWarmReaderSettlement(
                point: .init(messageID: "reader", minY: -40, viewportWidth: 400), scope: memory.scope)
            tracker.warmReaderSettlement = settlement
            let old = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1, target: .message(id: "reader"))
            let next = ChatTranscriptRestoreRequest(scope: changeScope ? UUID() : old.scope,
                generation: 2, target: .message(id: "replacement"))
            var parent = ChatTranscriptRestoreOutcomeState()
            parent.begin(old)
            var owned = old
            var currentScope = old.scope
            settlement.bindRestoreCompletion(old, isCurrent: {
                tracker.warmReaderSettlement === settlement && owned == old && settlement.scope == memory.scope
            }, complete: { outcome in
                _ = parent.complete(old, outcome: outcome, currentScope: currentScope)
                XCTFail("An obsolete warm callback must not reach SwiftUI completion")
            })
            tracker.cancelCorrectionsFromProducer(restoreTask: nil)
            owned = changeScope ? old : next
            currentScope = next.scope
            if changeScope {
                memory.bind(to: .init(server: server, profile: "default", sessionID: "replacement"))
            }
            parent.begin(next)
            let drain = expectation(description: "stale terminal drain")
            DispatchQueue.main.async { drain.fulfill() }
            await fulfillment(of: [drain], timeout: 1)
            XCTAssertEqual(parent.pending, next)
            XCTAssertEqual(owned, changeScope ? old : next)
            XCTAssertTrue(settlement.hasDelivered(old), "Terminal evidence is consumed once even when its owner retired")
        }
    }

    func testReplacementCoordinatorAttachesWhileSuspendedAndResumesWithoutRebinding() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let publication = ChatScrollMetricPublication()
        var scrolls: [MetricPublicationTestScrollView] = []
        var observers: [UIView] = []
        var coordinators: [ChatScrollObserver.Coordinator] = []
        var received: [Int] = []
        var ready: [Int] = []
        var sizes: [Int] = []
        var cancellations: [Int] = []
        for index in 0...1 {
            if index == 1 { publication.suspend() }
            let scroll = MetricPublicationTestScrollView(frame: window.bounds)
            let observer = UIView(frame: .zero)
            window.addSubview(scroll); scroll.addSubview(observer)
            scroll.contentSize = CGSize(width: 400, height: 2000)
            let coordinator = ChatScrollObserver.Coordinator(
                metricContext: .init(isStreaming: false, scope: UUID(), restoreToken: 1, latestToken: nil),
                publication: publication, onDirectInteraction: { cancellations.append(index) },
                onMetrics: { _ in received.append(index) },
                onContentSizeChange: { _ in sizes.append(index) },
                onScrollViewReady: { _ in ready.append(index) })
            coordinator.attachIfNeeded(from: observer, delivery: .deferred)
            scrolls.append(scroll); observers.append(observer); coordinators.append(coordinator)
        }
        publication.flush()
        XCTAssertTrue(received.isEmpty); XCTAssertTrue(ready.isEmpty); XCTAssertTrue(sizes.isEmpty)
        scrolls[1].directTouch = true
        coordinators[1].reportMetrics(delivery: .deferred)
        XCTAssertTrue(cancellations.isEmpty, "Suspended observers cannot resurrect correction callbacks")
        coordinators[0].detach() // Must not invalidate B's suspended binding.
        publication.resume()
        let staleHost = MetricPublicationTestScrollView(frame: window.bounds)
        window.addSubview(staleHost); staleHost.addSubview(observers[0])
        staleHost.contentSize = CGSize(width: 400, height: 2000)
        staleHost.directTouch = true
        coordinators[0].attachIfNeeded(from: observers[0], delivery: .deferred)
        coordinators[0].reportMetrics(delivery: .deferred)
        coordinators[0].detach()
        coordinators[1].reportMetrics(delivery: .deferred) // No attach/bind call after resume.
        XCTAssertEqual(cancellations, [1])
        XCTAssertTrue(received.isEmpty)
        publication.flush()
        XCTAssertEqual(received, [1]); XCTAssertEqual(ready, [1]); XCTAssertEqual(sizes, [1])
        coordinators[1].detach()
    }

    func testBriefTouchWithdrawsMeasuredFollowSlotAndStaleCompletionCannotClearRearm() {
        let tracker = ChatTranscriptViewportTracker()
        tracker.hasPendingMeasuredLayoutGrowth = true
        _ = tracker.layoutFollowState.recordContentHeight(1000)
        let nextAllowed = Date().addingTimeInterval(1)
        tracker.measuredLayoutFollowNextAllowedAt = nextAllowed
        let oldGeneration = tracker.measuredLayoutFollowGeneration
        let oldTask = Task { @MainActor in _ = try? await Task.sleep(for: .seconds(10)) }
        tracker.measuredLayoutFollowTask = oldTask
        tracker.cancelCorrectionsFromProducer(restoreTask: nil)
        XCTAssertTrue(oldTask.isCancelled)
        XCTAssertNil(tracker.measuredLayoutFollowTask, "A brief touch must free the scheduling slot immediately")
        XCTAssertTrue(tracker.hasPendingMeasuredLayoutGrowth)
        XCTAssertEqual(tracker.measuredLayoutFollowNextAllowedAt, nextAllowed)
        XCTAssertEqual(tracker.layoutFollowState.recordContentHeight(1010), .grew,
                       "Cancellation must preserve the measured-height baseline")
        let newGeneration = tracker.measuredLayoutFollowGeneration
        let newTask = Task { @MainActor in _ = try? await Task.sleep(for: .seconds(10)) }
        tracker.measuredLayoutFollowTask = newTask
        XCTAssertFalse(tracker.finishMeasuredLayoutFollow(generation: oldGeneration))
        XCTAssertNotNil(tracker.measuredLayoutFollowTask, "An old wake must not clear the new task")
        XCTAssertFalse(newTask.isCancelled)
        XCTAssertTrue(tracker.finishMeasuredLayoutFollow(generation: newGeneration))
        XCTAssertNil(tracker.measuredLayoutFollowTask)
        newTask.cancel()
    }

    func testDelayedLatestPreservesNewerObserverTouchAndParentRestoreIntent() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let scroll = MetricPublicationTestScrollView(frame: window.bounds)
        let observer = UIView(frame: .zero)
        window.addSubview(scroll); scroll.addSubview(observer)
        scroll.contentSize = CGSize(width: 400, height: 2000)
        let publication = ChatScrollMetricPublication()
        var received: [ChatScrollMetrics] = []
        let coordinator = ChatScrollObserver.Coordinator(
            metricContext: .init(isStreaming: false, scope: UUID(), restoreToken: 1, latestToken: nil),
            publication: publication, onDirectInteraction: {}, onMetrics: { received.append($0) },
            onContentSizeChange: { _ in }, onScrollViewReady: { _ in })
        coordinator.attachIfNeeded(from: observer, delivery: .deferred)
        let ticket = publication.beginLatestDecision()
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 2, target: .message(id: "reader"))
        var parent = ChatTranscriptRestoreOutcomeState()
        parent.begin(request)
        var commands = 0
        let delayed = Task { @MainActor in
            await publication.performLatestAfterWindowChange(ticket) {
                commands += 1
                parent.acceptUserIntent()
            }
        }
        scroll.directTouch = true
        coordinator.reportMetrics(delivery: .deferred)
        scroll.directTouch = false // Brief touch still supersedes the old tap.
        XCTAssertTrue(publication.hasPendingDirectInteraction)
        await delayed.value
        XCTAssertEqual(commands, 0)
        XCTAssertEqual(parent.pending, request)
        publication.flush()
        XCTAssertTrue(received.contains { $0.isDirectlyInteracting }, "Old Latest must not discard the touch edge")
        coordinator.detach()
    }

    func testDelayedLatestRejectsLeaveScopeAndReplacementButAllowsCurrentWindowDecision() async {
        for boundary in ["leave", "scope", "replacement", "current"] {
            let publication = ChatScrollMetricPublication()
            let source = UIView()
            let replacement = UIView()
            let metrics = ChatScrollMetrics(distanceFromBottom: 100, isUserInteracting: false,
                isDirectlyInteracting: false, isDecelerating: false)
            publication.bind(source: ObjectIdentifier(source), readCurrent: { metrics }, publish: { _ in })
            let ticket = publication.beginLatestDecision()
            var commands = 0
            let delayed = Task { @MainActor in
                await publication.performLatestAfterWindowChange(ticket) { commands += 1 }
            }
            switch boundary {
            case "leave": publication.suspend()
            case "scope": publication.invalidate()
            case "replacement":
                publication.bind(source: ObjectIdentifier(replacement), readCurrent: { metrics }, publish: { _ in })
            default:
                // Same observer renews its metric lease as the tail window realizes.
                publication.bind(source: ObjectIdentifier(source), readCurrent: { metrics }, publish: { _ in })
            }
            await delayed.value
            XCTAssertEqual(commands, boundary == "current" ? 1 : 0, boundary)
        }
    }

    func testLatestExpectedDifferentSourceReplacementWaitsForMountedReadinessAndAppliesOnce() async {
        for detachFirst in [true, false] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
            let publication = ChatScrollMetricPublication()
            let context = ChatScrollObserver.MetricContext(isStreaming: false, scope: UUID(),
                restoreToken: 1, latestToken: nil, transcriptIdentity: "fixture", windowGeneration: 0)
            var target = context
            target.windowGeneration = 1
            var deliveries: [String] = []
            var commands = 0
            var scrolls: [MetricPublicationTestScrollView] = []
            var views: [ChatScrollObserver.ObserverView] = []
            var coordinators: [ChatScrollObserver.Coordinator] = []
            for index in 0...1 {
                if index == 1 {
                    let ticket = publication.beginLatestDecision()
                    XCTAssertTrue(publication.expectLatestReplacement(ticket, context: target) {
                        commands += 1
                        XCTAssertEqual(Array(deliveries.suffix(3)), ["ready1", "size1", "metrics1"],
                                       "Latest must run after the replacement's attachment drain")
                        XCTAssertTrue(publication.isBoundSource(ObjectIdentifier(coordinators[1])))
                    })
                    if detachFirst {
                        // Actual observer removal invokes didMoveToSuperview/window.
                        views[0].removeFromSuperview()
                        ChatScrollObserver.dismantleUIView(views[0], coordinator: coordinators[0])
                    }
                    await drainLegacyMetricQueue()
                    XCTAssertEqual(commands, 0, "The old viewport cannot satisfy replacement readiness")
                }
                let scroll = MetricPublicationTestScrollView(frame: window.bounds)
                scroll.contentSize = CGSize(width: 400, height: 2000)
                let coordinator = ChatScrollObserver.Coordinator(
                    metricContext: index == 0 ? context : target, publication: publication,
                    onDirectInteraction: {}, onMetrics: { _ in deliveries.append("metrics\(index)") },
                    onContentSizeChange: { _ in deliveries.append("size\(index)") },
                    onScrollViewReady: { view in
                        guard view != nil else { deliveries.append("nil\(index)"); return }
                        deliveries.append("ready\(index)")
                    })
                let observer = ChatScrollObserver.ObserverView(coordinator: coordinator)
                scrolls.append(scroll); views.append(observer); coordinators.append(coordinator)
                window.addSubview(scroll)
                scroll.addSubview(observer) // Mount through real ObserverView callbacks, no helper bind.
                if index == 0 { await drainLegacyMetricQueue(); deliveries.removeAll() }
            }
            XCTAssertEqual(commands, 0, "Binding alone must not issue Latest inside UIKit layout")
            if !detachFirst {
                views[0].removeFromSuperview()
                ChatScrollObserver.dismantleUIView(views[0], coordinator: coordinators[0])
            }
            await drainLegacyMetricQueue()
            XCTAssertEqual(commands, 1, "A different source with the requested window owns the original intent")
            await drainLegacyMetricQueue()
            views[1].layoutSubviews()
            await drainLegacyMetricQueue()
            XCTAssertEqual(commands, 1, "Repeated layout/drains cannot apply the intent twice")
            XCTAssertFalse(deliveries.contains("nil0"), "Old teardown cannot clear the new viewport")
            ChatScrollObserver.dismantleUIView(views[1], coordinator: coordinators[1])
            XCTAssertEqual(scrolls.count, 2)
        }
    }

    func testLatestExpectedReplacementRejectsInterposedIntentAndLogicalContextChanges() async {
        for boundary in ["touch", "latest", "restore", "cancellation", "scope", "reader", "identity", "window", "leave", "detachNew"] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
            let publication = ChatScrollMetricPublication()
            let original = ChatScrollObserver.MetricContext(isStreaming: false, scope: UUID(),
                restoreToken: 1, latestToken: nil, transcriptIdentity: "fixture", windowGeneration: 0)
            var target = original
            target.windowGeneration = 1
            var commands = 0
            var coordinators: [ChatScrollObserver.Coordinator] = []
            var observers: [ChatScrollObserver.ObserverView] = []
            var scrolls: [MetricPublicationTestScrollView] = []
            for index in 0...1 {
                if index == 1 {
                    let ticket = publication.beginLatestDecision()
                    XCTAssertTrue(publication.expectLatestReplacement(ticket, context: target) { commands += 1 })
                    switch boundary {
                    case "touch":
                        scrolls[0].directTouch = true
                        observers[0].layoutSubviews()
                        scrolls[0].directTouch = false
                    case "latest": _ = publication.beginLatestDecision()
                    case "restore": target = Self.replacingMetricOrigin(target, restoreToken: target.restoreToken + 1)
                    case "cancellation": target = Self.replacingMetricOrigin(target, cancellationToken: target.cancellationToken + 1)
                    case "scope": target = Self.replacingMetricOrigin(target, scope: UUID())
                    case "reader":
                        target.readerScope = .init(server: URL(string: "https://fixture.invalid")!,
                            profile: "default", sessionID: "different")
                    case "identity": target.transcriptIdentity = "different"
                    case "window": target.windowGeneration = 2
                    case "leave": publication.suspend(); publication.resume()
                    default: break
                    }
                }
                let scroll = MetricPublicationTestScrollView(frame: window.bounds)
                scroll.contentSize = CGSize(width: 400, height: 2000)
                let coordinator = ChatScrollObserver.Coordinator(
                    metricContext: index == 0 ? original : target, publication: publication,
                    onDirectInteraction: {}, onMetrics: { _ in }, onContentSizeChange: { _ in },
                    onScrollViewReady: { _ in })
                let observer = ChatScrollObserver.ObserverView(coordinator: coordinator)
                coordinators.append(coordinator); observers.append(observer); scrolls.append(scroll)
                window.addSubview(scroll); scroll.addSubview(observer)
                if index == 0 { await drainLegacyMetricQueue() }
            }
            if boundary == "detachNew" {
                observers[1].removeFromSuperview()
                ChatScrollObserver.dismantleUIView(observers[1], coordinator: coordinators[1])
                scrolls[1].addSubview(observers[1])
                coordinators[1].attachIfNeeded(from: observers[1], delivery: .deferred)
            }
            await drainLegacyMetricQueue()
            XCTAssertEqual(commands, 0, boundary)
            for (view, coordinator) in zip(observers, coordinators) {
                ChatScrollObserver.dismantleUIView(view, coordinator: coordinator)
            }
        }
    }

    func testLatestExpectedReplacementRejectsOriginContextChangesBeforeNewBind() async {
        for boundary in ["restore", "cancellation", "scope", "latestToken", "identity", "window"] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
            let publication = ChatScrollMetricPublication()
            let original = ChatScrollObserver.MetricContext(isStreaming: false, scope: UUID(),
                restoreToken: 1, latestToken: nil, transcriptIdentity: "fixture", windowGeneration: 0)
            var target = original
            target.windowGeneration = 1
            var commands = 0
            let origin = ChatScrollObserver.Coordinator(metricContext: original, publication: publication,
                onDirectInteraction: {}, onMetrics: { _ in }, onContentSizeChange: { _ in },
                onScrollViewReady: { _ in })
            let oldView = ChatScrollObserver.ObserverView(coordinator: origin)
            let oldHost = UIScrollView(frame: window.bounds)
            oldHost.contentSize = CGSize(width: 400, height: 2000)
            window.addSubview(oldHost); oldHost.addSubview(oldView)
            await drainLegacyMetricQueue()
            let ticket = publication.beginLatestDecision()
            XCTAssertTrue(publication.expectLatestReplacement(ticket, context: target) { commands += 1 })
            var changed = original
            switch boundary {
            case "restore": changed = Self.replacingMetricOrigin(changed, restoreToken: changed.restoreToken + 1)
            case "cancellation": changed = Self.replacingMetricOrigin(changed, cancellationToken: changed.cancellationToken + 1)
            case "scope": changed = Self.replacingMetricOrigin(changed, scope: UUID())
            case "latestToken": changed = Self.replacingMetricOrigin(changed, latestToken: .init(generation: 2, issue: 1))
            case "identity": changed.transcriptIdentity = "different"
            default: changed.windowGeneration = 2
            }
            origin.updateMetricContext(changed)
            XCTAssertFalse(publication.acceptsLatestDecision(ticket), boundary)
            let replacement = ChatScrollObserver.Coordinator(metricContext: target, publication: publication,
                onDirectInteraction: {}, onMetrics: { _ in }, onContentSizeChange: { _ in },
                onScrollViewReady: { _ in })
            let newView = ChatScrollObserver.ObserverView(coordinator: replacement)
            let newHost = UIScrollView(frame: window.bounds)
            newHost.contentSize = CGSize(width: 400, height: 2000)
            window.addSubview(newHost); newHost.addSubview(newView)
            await drainLegacyMetricQueue()
            XCTAssertEqual(commands, 0, "Matching labels on a later source cannot resurrect a retired intent")
            ChatScrollObserver.dismantleUIView(oldView, coordinator: origin)
            ChatScrollObserver.dismantleUIView(newView, coordinator: replacement)
        }
    }

    func testLatestExpectedReplacementRejectsOldOwnerReattachButAcceptsNewOwner() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let publication = ChatScrollMetricPublication()
        let original = ChatScrollObserver.MetricContext(isStreaming: false, scope: UUID(),
            restoreToken: 1, latestToken: nil, windowGeneration: 0)
        var target = original
        target.windowGeneration = 1
        var commands = 0
        var oldCancellations = 0
        let old = ChatScrollObserver.Coordinator(metricContext: original, publication: publication,
            onDirectInteraction: { oldCancellations += 1 }, onMetrics: { _ in },
            onContentSizeChange: { _ in }, onScrollViewReady: { _ in })
        let oldView = ChatScrollObserver.ObserverView(coordinator: old)
        let oldHost = MetricPublicationTestScrollView(frame: window.bounds)
        oldHost.contentSize = CGSize(width: 400, height: 2000)
        window.addSubview(oldHost); oldHost.addSubview(oldView)
        await drainLegacyMetricQueue()
        let ticket = publication.beginLatestDecision()
        XCTAssertTrue(publication.expectLatestReplacement(ticket, context: target) { commands += 1 })
        oldView.removeFromSuperview() // Retire the origin before the replacement binds.
        let staleHost = MetricPublicationTestScrollView(frame: window.bounds)
        staleHost.contentSize = CGSize(width: 400, height: 2000)
        staleHost.directTouch = true
        window.addSubview(staleHost); staleHost.addSubview(oldView)
        old.updateMetricContext(target) // Even matching labels cannot authorize this stale source.
        oldView.layoutSubviews()
        await drainLegacyMetricQueue()
        XCTAssertEqual(commands, 0)
        XCTAssertEqual(oldCancellations, 0, "A detached origin cannot cancel the replacement through a stale producer")
        let next = ChatScrollObserver.Coordinator(metricContext: target, publication: publication,
            onDirectInteraction: {}, onMetrics: { _ in }, onContentSizeChange: { _ in },
            onScrollViewReady: { _ in })
        let nextView = ChatScrollObserver.ObserverView(coordinator: next)
        let nextHost = MetricPublicationTestScrollView(frame: window.bounds)
        nextHost.contentSize = CGSize(width: 400, height: 2000)
        window.addSubview(nextHost); nextHost.addSubview(nextView)
        oldView.layoutSubviews()
        ChatScrollObserver.dismantleUIView(oldView, coordinator: old)
        await drainLegacyMetricQueue()
        XCTAssertEqual(commands, 1)
        XCTAssertEqual(oldCancellations, 0)
        ChatScrollObserver.dismantleUIView(nextView, coordinator: next)
    }

    func testLatestExpectedReplacementCancelsWhenReadyCallbackChangesOwnership() async {
        for boundary in ["restore", "cancellation", "latestToken", "touch", "leave"] {
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
            let publication = ChatScrollMetricPublication()
            let original = ChatScrollObserver.MetricContext(isStreaming: false, scope: UUID(),
                restoreToken: 1, latestToken: nil, windowGeneration: 0)
            var target = original
            target.windowGeneration = 1
            var commands = 0
            weak var readyCoordinator: ChatScrollObserver.Coordinator?
            var coordinators: [ChatScrollObserver.Coordinator] = []
            var views: [ChatScrollObserver.ObserverView] = []
            var hosts: [MetricPublicationTestScrollView] = []
            for index in 0...1 {
                if index == 1 {
                    let ticket = publication.beginLatestDecision()
                    XCTAssertTrue(publication.expectLatestReplacement(ticket, context: target) { commands += 1 })
                }
                let host = MetricPublicationTestScrollView(frame: window.bounds)
                host.contentSize = CGSize(width: 400, height: 2000)
                let coordinator = ChatScrollObserver.Coordinator(
                    metricContext: index == 0 ? original : target, publication: publication,
                    onDirectInteraction: {}, onMetrics: { _ in }, onContentSizeChange: { _ in },
                    onScrollViewReady: { view in
                        guard index == 1, view != nil else { return }
                        switch boundary {
                        case "restore":
                            var changed = target
                            changed = Self.replacingMetricOrigin(changed, restoreToken: changed.restoreToken + 1)
                            readyCoordinator?.updateMetricContext(changed)
                        case "cancellation":
                            readyCoordinator?.updateMetricContext(Self.replacingMetricOrigin(
                                target, cancellationToken: target.cancellationToken + 1))
                        case "latestToken":
                            var changed = target
                            changed = Self.replacingMetricOrigin(changed, latestToken: .init(generation: 2, issue: 1))
                            readyCoordinator?.updateMetricContext(changed)
                        case "touch":
                            host.directTouch = true
                            readyCoordinator?.reportMetrics(delivery: .deferred)
                            host.directTouch = false
                        default: publication.suspend()
                        }
                    })
                if index == 1 { readyCoordinator = coordinator }
                let view = ChatScrollObserver.ObserverView(coordinator: coordinator)
                coordinators.append(coordinator); views.append(view); hosts.append(host)
                window.addSubview(host); host.addSubview(view)
                if index == 0 { await drainLegacyMetricQueue() }
            }
            await drainLegacyMetricQueue()
            await drainLegacyMetricQueue()
            XCTAssertEqual(commands, 0, boundary)
            for (view, coordinator) in zip(views, coordinators) {
                ChatScrollObserver.dismantleUIView(view, coordinator: coordinator)
            }
            XCTAssertEqual(hosts.count, 2)
        }
    }

    func testLatestExpectedReplacementFreshDrainTouchRetiresWithoutProducerCallback() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let publication = ChatScrollMetricPublication()
        let original = ChatScrollObserver.MetricContext(isStreaming: false, scope: UUID(),
            restoreToken: 1, latestToken: nil,
            readerScope: .init(server: URL(string: "https://fixture.invalid")!,
                               profile: "reader", sessionID: "fresh-touch"),
            transcriptIdentity: "fixture", windowGeneration: 0)
        var target = original
        target.windowGeneration = 1
        var commands = 0
        var deliveredTouch = false
        var producerTouches = 0
        var coordinators: [ChatScrollObserver.Coordinator] = []
        var views: [ChatScrollObserver.ObserverView] = []
        var hosts: [MetricPublicationTestScrollView] = []
        var decision: Int?
        for index in 0...1 {
            if index == 1 {
                let ticket = publication.beginLatestDecision()
                decision = ticket
                XCTAssertTrue(publication.expectLatestReplacement(ticket, context: target) { commands += 1 })
            }
            let host = MetricPublicationTestScrollView(frame: window.bounds)
            host.contentSize = CGSize(width: 400, height: 2000)
            let coordinator = ChatScrollObserver.Coordinator(
                metricContext: index == 0 ? original : target, publication: publication,
                onDirectInteraction: { producerTouches += 1 }, onMetrics: { deliveredTouch = deliveredTouch || $0.isDirectlyInteracting },
                onContentSizeChange: { _ in }, onScrollViewReady: { _ in })
            let view = ChatScrollObserver.ObserverView(coordinator: coordinator)
            coordinators.append(coordinator); views.append(view); hosts.append(host)
            window.addSubview(host); host.addSubview(view) // Submits idle geometry.
            if index == 0 { await drainLegacyMetricQueue() }
        }
        // No reportMetrics/layout/offset/content-size producer call after this edge.
        hosts[1].directTouch = true
        XCTAssertEqual(commands, 0, "Submission must not publish synchronously")
        await drainLegacyMetricQueue()
        XCTAssertTrue(deliveredTouch, "The queued drain must observe UIKit's fresh tracking state")
        XCTAssertEqual(producerTouches, 0, "No producer callback may supply the touch edge for this regression")
        XCTAssertFalse(publication.acceptsLatestDecision(decision!))
        XCTAssertEqual(commands, 0)
        hosts[1].directTouch = false
        coordinators[1].reportMetrics(delivery: .deferred)
        await drainLegacyMetricQueue()
        XCTAssertEqual(commands, 0, "Release and a later idle drain cannot resurrect Latest")
        for (view, coordinator) in zip(views, coordinators) {
            ChatScrollObserver.dismantleUIView(view, coordinator: coordinator)
        }
    }

    func testLatestExpectedReplacementCancellationBeforeDrainRetiresSamePresentation() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let publication = ChatScrollMetricPublication()
        let original = ChatScrollObserver.MetricContext(isStreaming: false, scope: UUID(),
            restoreToken: 7, latestToken: .init(generation: 3, issue: 2), cancellationToken: 4,
            readerScope: .init(server: URL(string: "https://fixture.invalid")!,
                               profile: "reader", sessionID: "cancellation"),
            transcriptIdentity: "fixture", windowGeneration: 0)
        var target = original
        target.windowGeneration = 1
        var commands = 0
        var coordinators: [ChatScrollObserver.Coordinator] = []
        var views: [ChatScrollObserver.ObserverView] = []
        for index in 0...1 {
            if index == 1 {
                let ticket = publication.beginLatestDecision()
                XCTAssertTrue(publication.expectLatestReplacement(ticket, context: target) { commands += 1 })
            }
            let host = UIScrollView(frame: window.bounds)
            host.contentSize = CGSize(width: 400, height: 2000)
            let coordinator = ChatScrollObserver.Coordinator(metricContext: index == 0 ? original : target,
                publication: publication, onDirectInteraction: {}, onMetrics: { _ in },
                onContentSizeChange: { _ in }, onScrollViewReady: { _ in })
            let view = ChatScrollObserver.ObserverView(coordinator: coordinator)
            coordinators.append(coordinator); views.append(view)
            window.addSubview(host); host.addSubview(view)
            if index == 0 { await drainLegacyMetricQueue() }
        }
        let cancelled = Self.replacingMetricOrigin(target, cancellationToken: 5)
        XCTAssertEqual(cancelled.scope, target.scope)
        XCTAssertEqual(cancelled.restoreToken, target.restoreToken)
        XCTAssertEqual(cancelled.latestToken, target.latestToken)
        XCTAssertEqual(cancelled.readerScope, target.readerScope)
        XCTAssertEqual(cancelled.transcriptIdentity, target.transcriptIdentity)
        XCTAssertEqual(cancelled.windowGeneration, target.windowGeneration)
        XCTAssertFalse(target.hasSameLogicalPresentation(cancelled))
        coordinators[1].updateMetricContext(cancelled)
        await drainLegacyMetricQueue()
        coordinators[1].reportMetrics(delivery: .deferred)
        await drainLegacyMetricQueue()
        XCTAssertEqual(commands, 0, "New Send/older-history intent cancels the retained action with all other labels unchanged")
        for (view, coordinator) in zip(views, coordinators) {
            ChatScrollObserver.dismantleUIView(view, coordinator: coordinator)
        }
    }

    func testLatestExpectedReplacementCannotApplyDuringBackMetricsFlush() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let publication = ChatScrollMetricPublication()
        let original = ChatScrollObserver.MetricContext(isStreaming: false, scope: UUID(),
            restoreToken: 1, latestToken: nil, windowGeneration: 0)
        var target = original
        target.windowGeneration = 1
        var commands = 0
        var metrics = 0
        var coordinators: [ChatScrollObserver.Coordinator] = []
        var views: [ChatScrollObserver.ObserverView] = []
        var hosts: [UIScrollView] = []
        for index in 0...1 {
            if index == 1 {
                let ticket = publication.beginLatestDecision()
                XCTAssertTrue(publication.expectLatestReplacement(ticket, context: target) { commands += 1 })
            }
            let host = UIScrollView(frame: window.bounds)
            host.contentSize = CGSize(width: 400, height: 2000)
            let coordinator = ChatScrollObserver.Coordinator(
                metricContext: index == 0 ? original : target, publication: publication,
                onDirectInteraction: {}, onMetrics: { _ in metrics += 1 },
                onContentSizeChange: { _ in }, onScrollViewReady: { _ in })
            let view = ChatScrollObserver.ObserverView(coordinator: coordinator)
            coordinators.append(coordinator); views.append(view); hosts.append(host)
            window.addSubview(host); host.addSubview(view)
            if index == 0 { await drainLegacyMetricQueue() }
        }
        let beforeExit = metrics
        publication.flush() // The production Back/disappear ordering.
        XCTAssertGreaterThan(metrics, beforeExit, "Back still captures the final fresh metric")
        XCTAssertEqual(commands, 0, "Back's explicit flush cannot change the user's navigation intent")
        publication.suspend()
        await drainLegacyMetricQueue()
        XCTAssertEqual(commands, 0)
        for (view, coordinator) in zip(views, coordinators) {
            ChatScrollObserver.dismantleUIView(view, coordinator: coordinator)
        }
        XCTAssertEqual(hosts.count, 2)
    }

    /// Rebuild immutable origin fields while preserving every presentation label.
    private static func replacingMetricOrigin(
        _ context: ChatScrollObserver.MetricContext,
        scope: UUID? = nil,
        restoreToken: Int? = nil,
        latestToken: ChatExplicitBottomGeometryToken? = nil,
        cancellationToken: Int? = nil
    ) -> ChatScrollObserver.MetricContext {
        .init(
            isStreaming: context.isStreaming,
            scope: scope ?? context.scope,
            restoreToken: restoreToken ?? context.restoreToken,
            latestToken: latestToken ?? context.latestToken,
            cancellationToken: cancellationToken ?? context.cancellationToken,
            readerScope: context.readerScope,
            transcriptIdentity: context.transcriptIdentity,
            windowGeneration: context.windowGeneration
        )
    }

    private func drainLegacyMetricQueue() async {
        let drain = expectation(description: "deferred observer lifecycle drain")
        DispatchQueue.main.async { drain.fulfill() }
        await fulfillment(of: [drain], timeout: 1)
    }

    func testObserverExposesReadOnlyAttachmentBeforeQueuedReadyAndClearsItOnDetach() async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let host = UIScrollView(frame: window.bounds)
        host.contentSize = CGSize(width: 400, height: 2000)
        let publication = ChatScrollMetricPublication()
        var ready = 0
        var metrics = 0
        let coordinator = ChatScrollObserver.Coordinator(
            metricContext: .init(isStreaming: false, scope: UUID(), restoreToken: 1, latestToken: nil),
            publication: publication, onDirectInteraction: {}, onMetrics: { _ in metrics += 1 },
            onContentSizeChange: { _ in }, onScrollViewReady: { _ in ready += 1 })
        let view = ChatScrollObserver.ObserverView(coordinator: coordinator)
        window.addSubview(host); host.addSubview(view)
        XCTAssertTrue(publication.attachedScrollView === host,
                      "A fresh row preference can read actual attachment before ready publication")
        XCTAssertEqual(ready, 0)
        XCTAssertEqual(metrics, 0)
        await drainLegacyMetricQueue()
        XCTAssertEqual(ready, 1)
        XCTAssertGreaterThan(metrics, 0)
        ChatScrollObserver.dismantleUIView(view, coordinator: coordinator)
        XCTAssertNil(publication.attachedScrollView, "Detached leases cannot confirm cached row geometry")
        await drainLegacyMetricQueue()
    }

    func testObserverAttachmentAndContentSizeDeferAndReadGeometryAfterAlignment() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let scroll = MetricPublicationTestScrollView(frame: window.bounds)
        let observer = UIView(frame: .zero)
        window.addSubview(scroll); scroll.addSubview(observer)
        scroll.contentSize = CGSize(width: 400, height: 2000)
        let publication = ChatScrollMetricPublication()
        var ready = 0
        var sizes: [CGSize] = []
        var received: [ChatScrollMetrics] = []
        let coordinator = ChatScrollObserver.Coordinator(
            metricContext: .init(isStreaming: false, scope: UUID(), restoreToken: 1, latestToken: nil),
            publication: publication, onDirectInteraction: {}, onMetrics: { received.append($0) },
            onContentSizeChange: { sizes.append($0) }, onScrollViewReady: { view in
                if let view {
                    ready += 1
                    view.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
                }
            })
        coordinator.attachIfNeeded(from: observer, delivery: .deferred)
        XCTAssertEqual(ready, 0); XCTAssertTrue(sizes.isEmpty); XCTAssertTrue(received.isEmpty)
        scroll.contentSize = CGSize(width: 400, height: 2100)
        XCTAssertTrue(sizes.isEmpty)
        publication.flush()
        XCTAssertEqual(ready, 1)
        XCTAssertEqual(sizes, [CGSize(width: 400, height: 2000), CGSize(width: 400, height: 2100)],
                       "Deferral must retain the attachment baseline and subsequent growth")
        XCTAssertEqual(received.last?.distanceFromBottom, 1000,
                       "Attachment alignment must precede the delivered geometry read")
        scroll.contentSize = CGSize(width: 400, height: 2200)
        XCTAssertEqual(sizes.count, 2, "Content-size KVO must not publish synchronously")
        publication.flush()
        XCTAssertEqual(sizes.last, CGSize(width: 400, height: 2200))
        XCTAssertEqual(received.last?.distanceFromBottom, 1100)
        coordinator.detach()
    }

    func testBackCaptureCannotBeReplacedByTeardownGeometry() {
        let memory = ChatWarmReaderMemory()
        let saved = ChatWarmReaderMemory.Point(messageID: "row1", minY: -107, viewportWidth: 402)
        memory.capture(saved)
        memory.suspendCapture()
        memory.capture(.init(messageID: "row0", minY: 114, viewportWidth: 402))
        XCTAssertEqual(memory.point, saved)
        memory.resumeCapture()
        memory.capture(.init(messageID: "row2", minY: -20, viewportWidth: 402))
        XCTAssertEqual(memory.point?.messageID, "row2")
    }

    func testWarmAttachmentCandidateRestoresIntraRowOffsetOnlyAtProvisionalTop() throws {
        let scope = UUID()
        let sample = ChatInitialMeasuredTarget(id: "row1", scope: scope, restoreToken: 0,
            renderRevision: 4, viewportWidth: 402,
            frame: CGRect(x: 16, y: 706, width: 346, height: 2780))
        func offset(current: CGFloat, revision: Int = 4, interacting: Bool = false) -> CGFloat? {
            ChatInitialMeasuredTarget.initialOffset(for: sample, targetID: "row1", scope: scope,
                restoreToken: 0, renderRevision: revision, viewportWidth: 402, nativeWidth: 402,
                nativeHeight: 755, contentHeight: 5000, currentOffset: current,
                topInset: 0, bottomInset: 0, isAttached: true, restoreActive: true,
                isCancelled: false, isDirectlyInteracting: interacting, targetMinY: -107)
        }
        XCTAssertEqual(try XCTUnwrap(offset(current: 0)), 813)
        XCTAssertNil(offset(current: 706), "Native seed already moved; await fresh geometry")
        XCTAssertNil(offset(current: 0, revision: 5), "Reflow invalidates the candidate")
        XCTAssertNil(offset(current: 0, interacting: true), "A drag owns the viewport")
    }

    func testWarmReaderLateRequestConsumesAttachedAlignmentExactlyOnce() {
        let lease = ChatWarmReaderSettlement(
            point: .init(messageID: "A", minY: -216, viewportWidth: 402), scope: nil)
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1, target: .message(id: "A"))
        var outcomes: [ChatTranscriptRestoreOutcome] = []
        // Attached geometry precedes asynchronous parent startup.
        XCTAssertNil(lease.observe(delta: 0, currentOffset: 216, lower: 0, upper: 1_000))
        var parent = ChatTranscriptRestoreOutcomeState()
        parent.begin(request)
        lease.bind(request) {
            outcomes.append($0)
            XCTAssertTrue(parent.complete(request, outcome: $0, currentScope: request.scope))
        }
        lease.bind(request) { outcomes.append($0) }
        lease.expire()
        XCTAssertNil(parent.pending, "The late token must release the parent's paging gate")
        XCTAssertFalse(parent.preservesDurableTarget)
        XCTAssertEqual(outcomes, [.success])
        XCTAssertFalse(lease.isActive)
    }

    func testWarmReaderQuiescentLeasesRetireWithoutAnotherPreference() async {
        // Success, absent target, and a correction clamped at the content edge
        // all stop producing preferences. Each must retire on the single timer.
        for geometry in ["aligned", "missing", "clamped"] {
            let lease = ChatWarmReaderSettlement(
                point: .init(messageID: "A", minY: -216, viewportWidth: 402), scope: nil)
            let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1, target: .message(id: "A"))
            var outcomes: [ChatTranscriptRestoreOutcome] = []
            lease.bind(request) { outcomes.append($0) }
            if geometry == "aligned" {
                XCTAssertNil(lease.observe(delta: 0, currentOffset: 216, lower: 0, upper: 1_000))
            } else if geometry == "missing" {
                XCTAssertNil(lease.observe(delta: nil, currentOffset: 0, lower: 0, upper: 1_000))
            } else {
                // A real nonzero measured delta cannot move an offset whose
                // available range has collapsed to zero. No alignment follows.
                let delta = lease.point.correction(
                    frame: CGRect(x: 0, y: 0, width: 402, height: 500), viewportWidth: 402)
                XCTAssertEqual(delta, 216)
                XCTAssertNil(lease.observe(delta: delta, currentOffset: 0, lower: 0, upper: 0))
            }
            let retired = expectation(description: "retired \(geometry) without preferences")
            lease.startExpiry(after: .milliseconds(10), isCurrent: { true }) { retired.fulfill() }
            await fulfillment(of: [retired], timeout: 1)
            XCTAssertFalse(lease.isActive, geometry)
            XCTAssertEqual(outcomes, [geometry == "aligned" ? .success : .exhausted], geometry)
            lease.expire()
            XCTAssertEqual(outcomes.count, 1)
        }
    }

    func testWarmReaderRequestAfterQuiescentExpiryIsExhaustedExactlyOnce() async {
        let lease = ChatWarmReaderSettlement(
            point: .init(messageID: "A", minY: -216, viewportWidth: 402), scope: nil)
        let retired = expectation(description: "pre-token expiry")
        lease.startExpiry(after: .milliseconds(10), isCurrent: { true }) { retired.fulfill() }
        await fulfillment(of: [retired], timeout: 1)
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1, target: .message(id: "A"))
        var outcomes: [ChatTranscriptRestoreOutcome] = []
        lease.bind(request) { outcomes.append($0) }
        lease.bind(request) { outcomes.append($0) }
        XCTAssertEqual(outcomes, [.exhausted])
    }

    func testWarmReaderCancellationAndObsoleteOwnerCannotPublishExpiry() async {
        let point = ChatWarmReaderMemory.Point(messageID: "A", minY: -216, viewportWidth: 402)
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1, target: .message(id: "A"))
        for reason in ["disappear", "new-owner", "identity", "arrow", "follow-latest", "interaction"] {
            let lease = ChatWarmReaderSettlement(point: point, scope: nil)
            var outcomes: [ChatTranscriptRestoreOutcome] = []
            var retirements = 0
            lease.bind(request) { outcomes.append($0) }
            lease.startExpiry(after: .milliseconds(10), isCurrent: { true }) { retirements += 1 }
            lease.cancel()
            try? await Task.sleep(for: .milliseconds(25))
            XCTAssertFalse(lease.isActive, reason)
            XCTAssertEqual(outcomes, [.cancelled], reason)
            XCTAssertEqual(retirements, 0, reason)
        }
        let obsolete = ChatWarmReaderSettlement(point: point, scope: nil)
        var outcomes: [ChatTranscriptRestoreOutcome] = []
        obsolete.bind(request) { outcomes.append($0) }
        obsolete.startExpiry(after: .milliseconds(10), isCurrent: { false }) {
            XCTFail("Obsolete owner must not mutate view state")
        }
        try? await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(obsolete.isActive)
        XCTAssertTrue(outcomes.isEmpty)
    }

    func testPersistenceUsesCurrentVisibleIDAfterCancelledWarmSettlement() throws {
        let suite = "warm-persistence-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = try XCTUnwrap(URL(string: "https://fixture.invalid"))
        let session = SessionSummary(sessionId: "reader", title: "Reader")
        let model = ChatViewModel(session: session, server: server, userDefaults: defaults,
                                  gatewayRuntimeProvider: { _ in throw URLError(.cannotConnectToHost) })
        let memory = try XCTUnwrap(model.warmTranscriptReaderMemory)
        let point = ChatWarmReaderMemory.Point(messageID: "A", minY: -216, viewportWidth: 402)
        memory.point = point
        let lease = ChatWarmReaderSettlement(point: point, scope: memory.scope)
        // Visible B arrives during settlement, when warm capture is suppressed.
        // Interaction cancels the lease and Back persists before another sample.
        let visibleID = "B"
        lease.cancel()
        model.rememberTranscriptRestorePoint(followingLatest: false, visibleMessageID: visibleID)
        XCTAssertEqual(TranscriptRestoreStore(defaults: defaults)
            .load(server: server, sessionID: "reader").visibleMessageID, "B")
        XCTAssertNil(memory.point)
        XCTAssertEqual(model.transcriptRestoreTarget, .message(id: "B"))

        memory.point = point
        model.rememberTranscriptRestorePoint(followingLatest: false, visibleMessageID: "A")
        XCTAssertEqual(memory.point, point, "Matching geometry can be reused")
        model.rememberTranscriptRestorePoint(followingLatest: false, visibleMessageID: nil)
        XCTAssertNil(memory.point, "No supplied visible identity must not resurrect A")
        XCTAssertNil(TranscriptRestoreStore(defaults: defaults)
            .load(server: server, sessionID: "reader").visibleMessageID)
        memory.point = point
        model.rememberTranscriptRestorePoint(followingLatest: true, visibleMessageID: "A")
        XCTAssertNil(memory.point)
    }

    func testWarmReaderUsesFreshRowDeltaAcrossDifferentWindows() throws {
        let point = ChatWarmReaderMemory.Point(messageID: "rich-row", minY: -162.333,
                                               viewportWidth: 402)
        // The same row can have unrelated absolute content offsets in two
        // bounded windows. Both corrections must recover its viewport position.
        for (offset, rowY) in [(CGFloat(100), CGFloat(54)), (CGFloat(4_000), CGFloat(900))] {
            let delta = try XCTUnwrap(point.correction(
                frame: CGRect(x: 16, y: rowY, width: 346, height: 2_780), viewportWidth: 402
            ))
            let correctedOffset = offset + delta
            XCTAssertEqual(rowY - (correctedOffset - offset), point.minY, accuracy: 0.001)
        }
        XCTAssertNil(point.correction(frame: CGRect(x: 0, y: 0, width: 346, height: 2_780),
                                     viewportWidth: 600), "Reflow invalidates the saved point")
        XCTAssertNil(point.correction(frame: .zero, viewportWidth: 402))
    }

    func testWarmReaderMemoryIsScopedToCanonicalSessionAndProfile() throws {
        let memory = ChatWarmReaderMemory()
        let server = try XCTUnwrap(URL(string: "https://fixture.invalid"))
        let original = ChatWarmReaderMemory.Scope(server: server, profile: "default", sessionID: "one")
        memory.bind(to: original)
        let point = ChatWarmReaderMemory.Point(messageID: "row", minY: -216, viewportWidth: 402)
        memory.point = point
        memory.bind(to: original)
        XCTAssertEqual(memory.point, point, "Warm reuse keeps measured geometry")
        memory.bind(to: .init(server: server, profile: "other", sessionID: "one"))
        XCTAssertNil(memory.point)
        memory.point = point
        memory.bind(to: .init(server: server, profile: "other", sessionID: "two"))
        XCTAssertNil(memory.point)
        memory.point = point
        memory.bind(to: nil)
        XCTAssertNil(memory.point, "A new, unassigned chat cannot inherit reader geometry")
    }

    func testMountedOrdinaryTranscriptCapturesRetainedHandoffs() async throws {
        for mode in [MountedActivityMode.retainedAndLive, .loose] {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let model = MountedActivityModel()
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = UIHostingController(
                rootView: MountedActivityTranscriptRoot(model: model, mode: mode)
            )
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKey()
            }

            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(90))
            attachActivityImage(of: window, named: "Mounted ordinary transcript \(mode) initial")
            if mode == .retainedAndLive {
                model.liveText = "Continuing to examine the next source segment."
                try await Task.sleep(for: .milliseconds(100))
                attachActivityImage(of: window, named: "Mounted activity update +0.10s hierarchy")
                try await Task.sleep(for: .milliseconds(200))
                attachActivityImage(of: window, named: "Mounted activity update +0.30s hierarchy")
                attachActivityImage(of: window, named: "Mounted activity update +0.30s layer", usesLayer: true)
                try await Task.sleep(for: .milliseconds(350))
                attachActivityImage(of: window, named: "Mounted activity update +0.65s hierarchy")
                attachActivityImage(of: window, named: "Mounted activity update +0.65s layer", usesLayer: true)
            }
        }
    }

    func testMountedOrdinaryTranscriptUnperturbedLiveUpdateStaysMounted() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let model = MountedActivityModel()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = UIHostingController(
            rootView: MountedActivityTranscriptRoot(model: model, mode: .retainedAndLive)
        )
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        // Keep the interval around the update entirely free of in-process
        // screenshot requests; simctl records the real display externally.
        try await Task.sleep(for: .milliseconds(350))
        print("ACTIVITY_UNPERTURBED_UPDATE_BEGIN epoch=\(Date().timeIntervalSince1970)")
        model.liveText = "Continuing to examine the next source segment."
        try await Task.sleep(for: .milliseconds(1_250))
        print("ACTIVITY_UNPERTURBED_UPDATE_END epoch=\(Date().timeIntervalSince1970)")
        XCTAssertFalse(window.isHidden)
        XCTAssertNotNil(window.rootViewController)
    }

    private func attachActivityImage(of window: UIWindow, named name: String, usesLayer: Bool = false) {
        window.layoutIfNeeded()
        let screenshot = UIGraphicsImageRenderer(bounds: window.bounds).image { context in
            if usesLayer {
                window.layer.render(in: context.cgContext)
            } else {
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBareThinkingUsesTrailingCurrentActivityOnly() {
        let retainedAssistant = ChatTranscriptTypingIndicatorPolicy.shouldShowBareIndicator(
            isEligible: true, hasActiveStream: true, showsActivityCards: true,
            trailingMessageRole: "assistant", hasTrailingRetainedReasoning: true,
            hasTrailingCompletedTools: false
        )
        XCTAssertFalse(retainedAssistant, "Retained Thinking already conveys current progress")

        let retainedTool = ChatTranscriptTypingIndicatorPolicy.shouldShowBareIndicator(
            isEligible: true, hasActiveStream: true, showsActivityCards: true,
            trailingMessageRole: "assistant", hasTrailingRetainedReasoning: false,
            hasTrailingCompletedTools: true
        )
        XCTAssertFalse(retainedTool, "Completed tool activity in the trailing assistant is already visible")

        let newerUserRow = ChatTranscriptTypingIndicatorPolicy.shouldShowBareIndicator(
            isEligible: true, hasActiveStream: true, showsActivityCards: true,
            trailingMessageRole: "user", hasTrailingRetainedReasoning: true,
            hasTrailingCompletedTools: false
        )
        XCTAssertTrue(newerUserRow, "Historical assistant activity must not hide a new turn's progress")
    }

#if DEBUG
    func testNativeRichPendingJumpIsCancelledByReaderDragAndDisappearance() {
        let controller = ChatStableViewportPrototype.Controller()
        controller.loadViewIfNeeded()
        controller.pendingNativeJumpAt = CACurrentMediaTime()
        controller.scrollViewWillBeginDragging(controller.scroll)
        XCTAssertNil(controller.pendingNativeJumpAt)
        controller.pendingNativeJumpAt = CACurrentMediaTime()
        controller.viewWillDisappear(false)
        XCTAssertNil(controller.pendingNativeJumpAt)
    }

    func testPrototypeLateHighlightHeightRefinementKeepsTailAttached() {
        let controller = ChatStableViewportPrototype.Controller()
        controller.loadViewIfNeeded()
        controller.scroll.delegate = nil
        controller.width = 370
        let ids = ["first", "tail"]
        controller.input = ChatStableViewportPrototype(
            ids: ids, revisionAt: { index in
                let message = ChatMessage(role: "assistant", content: "Geometry fixture \(index)",
                                          timestamp: Double(index), messageId: ids[index])
                return StableViewportRowRevision(
                    message: TranscriptMessage(loadedIndex: index, renderID: ids[index],
                                               anchorID: ids[index], message: message),
                    outgoingInsertionEvent: nil,
                    allowsOutgoingMotion: false, reasoningGroups: [], toolCallGroups: [],
                    liveReasoningText: "", liveToolCalls: [], streamingAssistantMessageID: nil,
                    liveTokensPerSecond: nil, localAttachmentPreviews: nil,
                    compressionReferenceCard: nil, listeningMessageID: nil,
                    showsThinkingAndToolCards: false, isViewingCachedData: false,
                    hasActiveStream: false, isRegeneratingMessage: false,
                    isEditingMessage: false, isForkingMessage: false,
                    transcriptMediaCacheNamespace: "geometry-test")
            }, revision: 0,
            typeKey: "test", bottomInset: 0, spacing: 12, reduceMotion: false,
            initialID: nil, startsAtBottom: false, onJumpToLatest: {},
            onScrollState: { _, _, _, _ in }, nativeRichDark: false, nativeRichWrapsCodeLines: false,
            nativePromptFillHex: "#E7D3B3", nativePromptForegroundHex: "#30251D", nativePromptBorderHex: "#C6AB83",
            onDirectSelectText: { _ in }, onDirectCopy: { _ in }, onDirectOpenURL: { _ in },
            makeRow: { _, _ in AnyView(Text("row")) }
        )
        controller.heights = [100, 1_000]
        controller.scroll.frame = CGRect(x: 0, y: 0, width: 402, height: 600)
        controller.rebuildPositions()
        controller.scroll.contentOffset.y = controller.bottomOffset
        controller.applyHeight(900, index: 1)
        XCTAssertEqual(controller.scroll.contentOffset.y, controller.bottomOffset, accuracy: 0.5)
        // Once the reader leaves the tail, refinements must preserve their
        // row-local anchor rather than silently pulling them back to latest.
        controller.scroll.contentOffset.y = 200
        let readerLocalOffset = controller.scroll.contentOffset.y - controller.positions[1]
        controller.applyHeight(200, index: 0)
        XCTAssertEqual(controller.scroll.contentOffset.y - controller.positions[1], readerLocalOffset, accuracy: 0.5)
    }

    func testPrototypeRejectsIntrinsicWidthProbeAsDisplayedGeometry() {
        // Actual cold rich-row regression: an intrinsic-width fitting probe
        // reported 206k height before the real 370pt-wide row reported 7.8k.
        XCTAssertFalse(ChatStableViewportPrototype.Controller.isDisplaySize(
            CGSize(width: 162, height: 206_231), width: 370
        ))
        XCTAssertTrue(ChatStableViewportPrototype.Controller.isDisplaySize(
            CGSize(width: 370, height: 7_812), width: 370
        ))
    }

    func testPrototypeGeometryRequiresFinitePositiveCurrentWidthAndHeight() {
        for size in [CGSize(width: 370, height: 0), CGSize(width: 370, height: CGFloat.infinity),
                     CGSize(width: CGFloat.nan, height: 100), CGSize(width: 369, height: 100)] {
            XCTAssertFalse(ChatStableViewportPrototype.Controller.isDisplaySize(size, width: 370))
        }
        XCTAssertFalse(ChatStableViewportPrototype.Controller.isDisplaySize(CGSize(width: 0, height: 10), width: 0))
        XCTAssertTrue(ChatStableViewportPrototype.Controller.isDisplaySize(CGSize(width: 370.25, height: 100), width: 370))
    }
#endif
    func testFirstDisplayLinkTickAfterWindowAttachmentTargetsSavedMessage() async throws {
        // Two different offscreen IDs expose a binding that merely keeps the
        // default top offset while the saved ID is present in the source data.
        for savedRow in [10, 20] {
            do {
                try await assertFirstAttachedLayerStartsAtSavedMessage(savedRow)
            } catch {
                // A missing/unreadable first image must not skip evidence for
                // the other target. Each thrown error still fails the test.
                XCTFail("Saved row \(savedRow) capture failed: \(error)")
            }
        }
    }

    private func assertFirstAttachedLayerStartsAtSavedMessage(_ savedRow: Int) async throws {
        let appeared = expectation(description: "transcript enters the SwiftUI view lifecycle")
        let firstDisplayLinkTick = expectation(description: "first display-link tick after window attachment is sampled")
        var hasAppeared = false
        var hasSampledFirstDisplayLinkTick = false
        var proxyFallbackRequests: [(id: String, animated: Bool)] = []
        var latestRestoreRequests = 0
        var publishedRowIDs: [String] = []
        var publishedRowIDsAtTick: [String] = []
        var firstTickImage: UIImage?
        var laterTickImages: [(Int, UIImage)] = []
        let boundedTicks = expectation(description: "four attached layer samples captured")
        let restoreProbe = ChatTranscriptRestoreProbe()

        let window = try mountTranscript(
            restoreScrollToken: 1,
            restoreTarget: .message(id: "message-\(savedRow)"),
            onAppear: {
                guard !hasAppeared else { return }
                hasAppeared = true
                appeared.fulfill()
            },
            onRestoreLatest: { _ in
                restoreProbe.record("callback.latest")
                latestRestoreRequests += 1
            },
            onRestoreMessage: { id, animated in
                restoreProbe.record("callback.proxy id=\(id) animated=\(animated)")
                proxyFallbackRequests.append((id: id, animated: animated))
            },
            onVisibleRowIDChange: { id in
                restoreProbe.record("callback.visible id=\(id ?? "nil")")
                if let id { publishedRowIDs.append(id) }
            },
            restoreProbe: restoreProbe,
            onDisplayLinkTick: { attachedWindow, tick, timestamp, targetTimestamp in
                restoreProbe.record("tick.\(tick).begin timestamp=\(timestamp) targetTimestamp=\(targetTimestamp) published=\(publishedRowIDs)")
                restoreProbe.record(attachedScrollDescription(in: attachedWindow))
                if tick == 1 {
                    hasSampledFirstDisplayLinkTick = true
                    publishedRowIDsAtTick = publishedRowIDs
                }
                if let attachedWindow {
                    let image = UIGraphicsImageRenderer(bounds: attachedWindow.bounds).image { context in
                        // Capture the existing layer tree at the tick. A
                        // drawHierarchy(afterScreenUpdates:) call can force a
                        // later SwiftUI layout and mask an initial flash.
                        attachedWindow.layer.render(in: context.cgContext)
                    }
                    if tick == 1 {
                        firstTickImage = image
                    } else { laterTickImages.append((tick, image)) }
                }
                if tick == 1 {
                    // Observe after the original raw capture, in the same callback.
                    // No layout, repaint, crop, or replacement of the judged image.
                    restoreProbe.record(firstTickViewportDescription(in: attachedWindow))
                }
                restoreProbe.record("tick.\(tick).end")
                if tick == 1 { firstDisplayLinkTick.fulfill() }
                if tick == 4 { boundedTicks.fulfill() }
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [appeared, firstDisplayLinkTick, boundedTicks], timeout: 1)
        // Retain the existing 200 ms no-fallback guard after the four samples.
        // This delay never determines which image is the first-tick assertion.
        try await Task.sleep(for: .milliseconds(200))
        if let firstTickImage {
            let attachment = XCTAttachment(image: firstTickImage)
            attachment.name = "First attached display-link tick layer tree, saved row \(savedRow)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // These later trees are separate observations, never a replacement
        // for tick 1 or proof of compositor presentation. Save evidence before
        // OCR/assertions so even unreadable first pixels retain the timeline.
        for (tick, laterImage) in laterTickImages {
            let laterAttachment = XCTAttachment(image: laterImage)
            laterAttachment.name = "Attached display-link tick \(tick) layer tree, saved row \(savedRow)"
            laterAttachment.lifetime = .keepAlways
            add(laterAttachment)
        }
        let timeline = XCTAttachment(string: restoreProbe.events.joined(separator: "\n")
            + "\ndroppedEvents=\(restoreProbe.droppedEvents)")
        timeline.name = "Restore lifecycle and native geometry, saved row \(savedRow)"
        timeline.lifetime = .keepAlways
        add(timeline)
        XCTAssertTrue(hasSampledFirstDisplayLinkTick)
        XCTAssertEqual(laterTickImages.count, 3)
        let image = try XCTUnwrap(firstTickImage, "The display-link probe must be attached to the window")
        let firstVisibleNumber = try firstVisibleTranscriptMessageNumber(in: image)
        XCTAssertEqual(firstVisibleNumber, savedRow,
                       "The first captured layer tree must show the saved row first; published IDs before the tick: \(publishedRowIDsAtTick)")
        XCTAssertTrue(publishedRowIDsAtTick.allSatisfy { $0 == "message-\(savedRow)" },
                      "A provisional row must not escape as the durable reader position")
        XCTAssertEqual(proxyFallbackRequests.count, 0,
                       "Initial positioning must not need proxy fallback; observed \(proxyFallbackRequests)")
        XCTAssertEqual(latestRestoreRequests, 0,
                       "A saved-message restore must not request the latest content")
    }

    func testFirstVisibleTranscriptRowReadsLeadingIndexInClippedHeading() throws {
        let bounds = CGRect(x: 0, y: 0, width: 180, height: 48)
        for index in [2, 20] {
            let image = UIGraphicsImageRenderer(bounds: bounds).image { context in
                context.cgContext.setFillColor(UIColor.white.cgColor)
                context.cgContext.fill(bounds)
                ("Restored \(index) transcript message" as NSString).draw(at: CGPoint(x: 8, y: 12),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 17), .foregroundColor: UIColor.black])
            }
            XCTAssertEqual(try firstVisibleTranscriptMessageNumber(in: image, prefix: "Restored"), index)
        }
    }

    private func firstVisibleTranscriptMessageNumber(
        in image: UIImage, prefix: String = "Restored transcript message"
    ) throws -> Int {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let cgImage = try XCTUnwrap(image.cgImage)
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        let pattern = NSRegularExpression.escapedPattern(for: prefix) + #"\s+(\d+)"#
        let visibleRows = (request.results ?? []).compactMap { observation -> (Int, CGFloat)? in
            guard let text = observation.topCandidates(1).first?.string,
                  let range = text.range(of: pattern, options: .regularExpression),
                  let number = Int(text[range].split(separator: " ").last ?? "")
            else { return nil }
            return (number, observation.boundingBox.maxY)
        }
        XCTAssertFalse(visibleRows.isEmpty, "The tick image must contain a readable transcript row")
        return try XCTUnwrap(visibleRows.max(by: { $0.1 < $1.1 })?.0)
    }

    #if DEBUG
    func testNativeRawLayerMaskCaptureControl() async throws {
        // Diagnostic only: the scored production capture remains unchanged.
        // Both trees are taken in the same callback without layout/commit;
        // removing a mask here is never a product fix or presentation proof.
        let input = nativeMotionInput(scope: "raw-mask-control-\(UUID().uuidString)",
            initialID: "native-row-10", rowContentPrefix: "Restored transcript message ")
        let controller = ChatNativeTranscriptViewport.Controller(input: input)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        // This raw-capture control's white backdrop requires fixed text contrast.
        window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .white
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        let captured = expectation(description: "paired first raw native mask captures")
        var masked: UIImage?
        var unmasked: UIImage?
        var maskWasPresent = false
        var beforeOffset: CGPoint?
        var afterOffset: CGPoint?
        let probe = WindowAttachmentDisplayLinkProbeView()
        probe.onDisplayLinkTick = { attached, tick, _, _ in
            guard tick == 1, let attached else { return }
            func render() -> UIImage {
                UIGraphicsImageRenderer(bounds: attached.bounds).image { context in
                    attached.layer.render(in: context.cgContext)
                }
            }
            beforeOffset = controller.collection.contentOffset
            masked = render()
            let mask = controller.collection.layer.mask
            maskWasPresent = mask != nil
            controller.collection.layer.mask = nil
            unmasked = render()
            controller.collection.layer.mask = mask
            afterOffset = controller.collection.contentOffset
            captured.fulfill()
        }
        controller.view.addSubview(probe)
        defer {
            probe.stop()
            probe.onDisplayLinkTick = nil
            probe.removeFromSuperview()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        await fulfillment(of: [captured], timeout: 2)
        XCTAssertTrue(maskWasPresent)
        XCTAssertEqual(beforeOffset, afterOffset)
        let original = try XCTUnwrap(masked)
        let withoutMask = try XCTUnwrap(unmasked)
        for (name, image) in [("Native raw first tick with original mask", original),
                              ("Native raw same tick diagnostic mask removed", withoutMask)] {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        func observedRow(_ image: UIImage) throws -> Int? {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
            return (request.results ?? []).compactMap { observation -> (Int, CGFloat)? in
                guard let text = observation.topCandidates(1).first?.string,
                      let range = text.range(of: #"Restored transcript message\s+(\d+)"#, options: .regularExpression),
                      let number = Int(text[range].split(separator: " ").last ?? "") else { return nil }
                return (number, observation.boundingBox.maxY)
            }.max(by: { $0.1 < $1.1 })?.0
        }
        let originalRow = try observedRow(original)
        let unmaskedRow = try observedRow(withoutMask)
        let receipt = XCTAttachment(string: "maskPresent=\(maskWasPresent) maskedRow=\(String(describing: originalRow)) unmaskedRow=\(String(describing: unmaskedRow)) offsetUnchanged=\(beforeOffset == afterOffset)")
        receipt.name = "Native raw capture mask discrimination"
        receipt.lifetime = .keepAlways
        add(receipt)
        XCTAssertEqual(unmaskedRow, 10, "The paired unmasked raw observer must read the mounted target")
    }
    #endif

    func testPlainNavigationFirstRawTickControl() async throws {
        // Discriminate the raw capture/navigation seam from transcript ownership.
        // No chat view, row host, scroll, restore or network participates here.
        for navigates in [false, true] {
            let route = ReaderShellRoute()
            let capture = ReaderShellCapture()
            let root = PlainReaderShellRoot(route: route, capture: capture, navigates: navigates)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive }))
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = UIHostingController(rootView: root)
            let completed = capture.beginVisit()
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previous?.makeKey()
            }
            if navigates {
                // Match the production-shell prerequisite. Do not construct or
                // pre-render the destination before its scored first attachment.
                guard try await MountedReadinessWait.poll(condition: {
                    capture.neutralRootAppearanceCompleted && window.isKeyWindow && !window.isHidden
                }) else {
                    XCTFail("Timed out waiting for the plain control's neutral navigation root")
                    return
                }
            }
            route.chatPresented = true
            await fulfillment(of: [completed], timeout: 4)
            XCTAssertEqual(capture.samples.map(\.tick), [1, 2, 3, 4])
            for sample in capture.samples {
                let image = try XCTUnwrap(sample.image)
                let attachment = XCTAttachment(image: image)
                attachment.name = "Plain control navigation \(navigates) raw tick \(sample.tick)"
                attachment.lifetime = .keepAlways
                add(attachment)
                let geometry = XCTAttachment(string: sample.geometry)
                geometry.name = "Plain control navigation \(navigates) geometry tick \(sample.tick)"
                geometry.lifetime = .keepAlways
                add(geometry)
                if let presented = sample.presentedImage {
                    let attachment = XCTAttachment(image: presented)
                    attachment.name = "Plain control navigation \(navigates) presented tick \(sample.tick)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
            // Positive controls for the judged instruments, on a CPU-renderable
            // tree. The raw layer-tree observer must read the label in both
            // cases; the presented observer is asserted for the no-navigation
            // case only. With a push, the plain label attaches at the very
            // first transition frame, when the presented surface can still be
            // the pre-composite black frame (observed in
            // daily-driver-restoration-and-drafts-04); the production shell's
            // own first presented tick is verified to show the restored rows,
            // and this control documents the seam instead of asserting a
            // timing the production gate does not rely on.
            let first = try XCTUnwrap(capture.samples.first?.image)
            XCTAssertEqual(try firstVisibleTranscriptMessageNumber(in: first), 10,
                           "The raw first-tick observer must read a plain label before judging chat rows")
            if !navigates {
                let firstPresented = try XCTUnwrap(capture.samples.first?.presentedImage)
                XCTAssertEqual(try firstVisibleTranscriptMessageNumber(in: firstPresented), 10,
                               "The presented first-tick observer must read a plain label before judging chat rows")
            }
        }
    }

    func testMissingSavedMessageKeepsBoundedProxyFallback() async throws {
        let appeared = expectation(description: "transcript enters the SwiftUI view lifecycle")
        let fallbackRequested = expectation(description: "missing lazy target requests a proxy fallback")
        fallbackRequested.assertForOverFulfill = false
        var hasAppeared = false

        let window = try mountTranscript(
            restoreScrollToken: 1,
            restoreTarget: .message(id: "not-loaded"),
            onAppear: {
                guard !hasAppeared else { return }
                hasAppeared = true
                appeared.fulfill()
            },
            onRestoreLatest: { _ in
                XCTFail("A saved-message restore must not request the latest content.")
            },
            onRestoreMessage: { id, animated in
                XCTAssertEqual(id, "not-loaded")
                XCTAssertFalse(animated)
                fallbackRequested.fulfill()
            }
        )
        defer { tearDown(window) }

        await fulfillment(of: [appeared, fallbackRequested], timeout: 1)
    }

    func testInitialMountWithZeroRestoreTokenDoesNotRequestRestore() async throws {
        let appeared = expectation(description: "transcript enters the SwiftUI view lifecycle")
        var hasAppeared = false
        var restoreRequests = 0

        let window = try mountTranscript(
            restoreScrollToken: 0,
            restoreTarget: .latest,
            onAppear: {
                guard !hasAppeared else { return }
                hasAppeared = true
                appeared.fulfill()
            },
            onRestoreLatest: { _ in restoreRequests += 1 },
            onRestoreMessage: { _, _ in restoreRequests += 1 }
        )
        defer { tearDown(window) }

        await fulfillment(of: [appeared], timeout: 1)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(restoreRequests, 0, "A zero restore token must not request a restore")
    }

    func testMeasuredLegacyMissingTargetDeliversOnceOutsideLayoutAndSameTokenUpdates() async throws {
        var callbacks: [String] = []
        var inLayout = true
        var transcript = makeLegacyCompatibilityTranscript { id, animated in
            XCTAssertFalse(inLayout, "Layout must queue the legacy callback")
            XCTAssertFalse(animated)
            callbacks.append(id)
        }
        let (host, fixture) = try mountLegacyCompatibilityTranscript(transcript)
        defer { tearDown(fixture) }
        let native = try XCTUnwrap(findLegacyCompatibilityViewport(in: host))
        XCTAssertEqual(native.pendingRestore?.outcome, .unavailable)
        XCTAssertTrue(callbacks.isEmpty)
        inLayout = false
        await drainNativeScrollQueue()
        XCTAssertEqual(callbacks, ["legacy-missing"])
        XCTAssertEqual(native.completedRequest?.target, .message(id: "legacy-missing"))
        XCTAssertFalse(native.follows)

        for revision in 1...4 {
            inLayout = true
            transcript.transcriptRenderRevision = revision
            host.rootView = LegacyCompatibilityRoot(transcript: transcript)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            native.collection.setNeedsLayout()
            native.collection.layoutIfNeeded()
            inLayout = false
            await drainNativeScrollQueue()
        }
        XCTAssertEqual(callbacks, ["legacy-missing"], "The same token must not repeat its fallback")
    }

    func testMeasuredLegacyReplacementRejectsQueuedFallbackAndPositionsLoadedRow() async throws {
        var callbacks: [String] = []
        var transcript = makeLegacyCompatibilityTranscript { id, _ in callbacks.append(id) }
        let (host, fixture) = try mountLegacyCompatibilityTranscript(transcript)
        defer { tearDown(fixture) }
        let native = try XCTUnwrap(findLegacyCompatibilityViewport(in: host))
        XCTAssertEqual(native.pendingRestore?.outcome, .unavailable)

        transcript.restoreScrollToken = 2
        transcript.restoreTarget = .message(id: "message-10")
        host.rootView = LegacyCompatibilityRoot(transcript: transcript)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertEqual(native.input.restoreRequest?.generation, 2,
                       "Exercise replacement through the mounted production view")
        for _ in 0..<8 {
            native.collection.setNeedsLayout()
            native.collection.layoutIfNeeded()
            await drainNativeScrollQueue()
        }
        XCTAssertTrue(callbacks.isEmpty, "Neither the stale missing row nor the loaded replacement uses a proxy")
        XCTAssertEqual(native.completedRequest?.target, .message(id: "message-10"))
        XCTAssertEqual(native.currentAnchor()?.id, "message-10")
        let layout = try XCTUnwrap(native.collection.collectionViewLayout as? ChatNativeTranscriptViewport.Controller.ColumnLayout)
        XCTAssertTrue(layout.measured.contains(.row("message-10")))
    }

    func testMeasuredLegacyScopeReplacementRejectsOldQueuedFallback() async throws {
        var callbacks: [String] = []
        var transcript = makeLegacyCompatibilityTranscript { id, animated in
            XCTAssertFalse(animated)
            callbacks.append(id)
        }
        transcript.outgoingInsertionScope = UUID()
        let (host, fixture) = try mountLegacyCompatibilityTranscript(transcript)
        defer { tearDown(fixture) }
        let native = try XCTUnwrap(findLegacyCompatibilityViewport(in: host))
        let oldScope = native.input.scope
        XCTAssertEqual(native.pendingRestore?.outcome, .unavailable)

        transcript.outgoingInsertionScope = UUID()
        transcript.restoreTarget = .message(id: "replacement-scope-missing")
        host.rootView = LegacyCompatibilityRoot(transcript: transcript)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertNotEqual(native.input.scope, oldScope)
        for _ in 0..<4 {
            native.collection.setNeedsLayout()
            native.collection.layoutIfNeeded()
            await drainNativeScrollQueue()
        }
        XCTAssertEqual(callbacks, ["replacement-scope-missing"])
        XCTAssertFalse(native.follows)
    }

    func testMeasuredLegacyCancellationRejectsQueuedFallbackAndSameTokenRearm() async throws {
        var callbacks: [String] = []
        var transcript = makeLegacyCompatibilityTranscript { id, _ in callbacks.append(id) }
        let (host, fixture) = try mountLegacyCompatibilityTranscript(transcript)
        defer { tearDown(fixture) }
        let native = try XCTUnwrap(findLegacyCompatibilityViewport(in: host))
        XCTAssertEqual(native.pendingRestore?.outcome, .unavailable)
        transcript.transcriptRestoreCancellationToken = 1
        host.rootView = LegacyCompatibilityRoot(transcript: transcript)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        XCTAssertEqual(native.input.cancellationToken, 1)
        for revision in 1...4 {
            transcript.transcriptRenderRevision = revision
            host.rootView = LegacyCompatibilityRoot(transcript: transcript)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await drainNativeScrollQueue()
        }
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertNil(native.input.restoreRequest, "Cancellation retires this legacy token")
        XCTAssertFalse(native.follows)
    }

    func testMeasuredLegacySameTokenTargetChangeWithdrawsQueuedFallback() async throws {
        var callbacks: [String] = []
        var transcript = makeLegacyCompatibilityTranscript { id, _ in callbacks.append(id) }
        let (host, fixture) = try mountLegacyCompatibilityTranscript(transcript)
        defer { tearDown(fixture) }
        let native = try XCTUnwrap(findLegacyCompatibilityViewport(in: host))
        XCTAssertEqual(native.pendingRestore?.outcome, .unavailable)
        transcript.restoreTarget = .message(id: "same-token-new-target")
        host.rootView = LegacyCompatibilityRoot(transcript: transcript)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await drainNativeScrollQueue()
        XCTAssertNil(native.input.restoreRequest, "A changed target cannot replay the same token")
        XCTAssertTrue(callbacks.isEmpty, "The previous target no longer owns callback delivery")
    }

    func testMeasuredLegacySceneExitAndDisappearanceRejectQueuedFallback() async throws {
        for disappears in [false, true] {
            var callbacks: [String] = []
            let transcript = makeLegacyCompatibilityTranscript { id, _ in callbacks.append(id) }
            let (host, fixture) = try mountLegacyCompatibilityTranscript(transcript)
            defer { tearDown(fixture) }
            let native = try XCTUnwrap(findLegacyCompatibilityViewport(in: host))
            XCTAssertEqual(native.pendingRestore?.outcome, .unavailable)
            host.rootView = LegacyCompatibilityRoot(transcript: transcript,
                isVisible: !disappears, scenePhase: .inactive)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await drainNativeScrollQueue()
            XCTAssertTrue(callbacks.isEmpty, "A retired presentation cannot deliver its queued fallback")
            if disappears {
                XCTAssertTrue(native.stopped)
            } else {
                host.rootView = LegacyCompatibilityRoot(transcript: transcript)
                host.view.setNeedsLayout()
                host.view.layoutIfNeeded()
                await drainNativeScrollQueue()
                XCTAssertTrue(callbacks.isEmpty, "Activation must not replay the cancelled token")
            }
        }
    }

    func testMeasuredLegacyReaderDragSupersedesQueuedUnavailable() async throws {
        var callbacks: [String] = []
        let transcript = makeLegacyCompatibilityTranscript { id, _ in callbacks.append(id) }
        let (host, fixture) = try mountLegacyCompatibilityTranscript(transcript)
        defer { tearDown(fixture) }
        let native = try XCTUnwrap(findLegacyCompatibilityViewport(in: host))
        XCTAssertEqual(native.pendingRestore?.outcome, .unavailable)
        native.scrollViewWillBeginDragging(native.collection)
        await drainNativeScrollQueue()
        XCTAssertTrue(callbacks.isEmpty)
        XCTAssertFalse(native.follows)
        XCTAssertEqual(native.completedRequest?.target, .message(id: "legacy-missing"))
    }

    func testMeasuredTypedCompletionDoesNotReplayThroughLegacyAdapter() async throws {
        var callbacks: [String] = []
        var outcomes: [ChatTranscriptRestoreOutcome] = []
        var transcript = makeLegacyCompatibilityTranscript { id, _ in callbacks.append(id) }
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1,
                                                   target: .message(id: "legacy-missing"))
        transcript.initialRestoreRequest = request
        transcript.onInitialRestoreOutcome = { delivered, outcome in
            XCTAssertEqual(delivered, request)
            outcomes.append(outcome)
        }
        let (host, fixture) = try mountLegacyCompatibilityTranscript(transcript)
        defer { tearDown(fixture) }
        let native = try XCTUnwrap(findLegacyCompatibilityViewport(in: host))
        XCTAssertEqual(native.pendingRestore?.outcome, .unavailable)
        await drainNativeScrollQueue()
        XCTAssertEqual(outcomes, [.unavailable])
        XCTAssertTrue(callbacks.isEmpty)

        transcript.initialRestoreRequest = nil
        host.rootView = LegacyCompatibilityRoot(transcript: transcript)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        for _ in 0..<4 {
            native.collection.setNeedsLayout()
            native.collection.layoutIfNeeded()
            await drainNativeScrollQueue()
        }
        XCTAssertNil(native.input.restoreRequest)
        XCTAssertEqual(outcomes, [.unavailable])
        XCTAssertTrue(callbacks.isEmpty, "A typed outcome must never manufacture a legacy fallback")
    }

    func testMeasuredLegacyZeroTokenDoesNotProduceMissingTargetRequest() async throws {
        var callbacks: [String] = []
        var transcript = makeLegacyCompatibilityTranscript { id, _ in callbacks.append(id) }
        transcript.restoreScrollToken = 0
        let (host, fixture) = try mountLegacyCompatibilityTranscript(transcript)
        defer { tearDown(fixture) }
        let native = try XCTUnwrap(findLegacyCompatibilityViewport(in: host))
        for _ in 0..<4 {
            native.collection.setNeedsLayout()
            native.collection.layoutIfNeeded()
            await drainNativeScrollQueue()
        }
        XCTAssertNil(native.input.restoreRequest)
        XCTAssertTrue(callbacks.isEmpty)
    }

    func testProductionChatShellFreshAndWarmReaderRestore() async throws {
        for savedRow in [10, 20] {
            let suite = "shell-reader-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let session = SessionSummary(sessionId: "shell-reader-\(UUID().uuidString)", title: "Reader restore fixture")
            let server = try XCTUnwrap(URL(string: "http://127.0.0.1:9"))
            let model = ChatViewModel(session: session, server: server, userDefaults: defaults,
                                      gatewayRuntimeProvider: { _ in throw URLError(.cannotConnectToHost) })
            model.seedTranscriptForTesting((0..<60).map { index in
                // Keep the index near the leading edge during the native push.
                // A clipped trailing 20 must not be misread as row 2 by OCR.
                ChatMessage(role: index.isMultiple(of: 2) ? "user" : "assistant",
                            content: "Restored \(index) transcript message\n\nReader fixture body \(index). The same display row is the durable reading unit.",
                            timestamp: Double(index), messageId: "shell-message-\(index)")
            })
            let displayRows = model.displayedTranscriptMessages
            XCTAssertEqual(displayRows.count, 60)
            let targetID = displayRows[savedRow].renderID
            XCTAssertEqual(displayRows[savedRow].message.messageId, "shell-message-\(savedRow)")
            let restoreStore = TranscriptRestoreStore(defaults: defaults)
            model.rememberTranscriptRestorePoint(followingLatest: false, visibleMessageID: targetID)
            XCTAssertEqual(restoreStore.load(server: server, sessionID: session.sessionId ?? session.id).visibleMessageID, targetID)

            let schema = Schema([CachedSession.self, CachedMessage.self, CachedSessionPreviewRecord.self])
            let container = try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            let route = ReaderShellRoute()
            let capture = ReaderShellCapture()
            let root = ReaderShellRoot(route: route, session: session, server: server,
                                       model: model, capture: capture).modelContainer(container)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive }), "A foreground scene is required")
            let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            // Match the real scene at attachment; do not manufacture a width
            // transition before judging the original raw first-tick image.
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = UIHostingController(rootView: root)
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKey()
            }

            // Complete neutral setup before the single scored navigation request.
            // This must not wait for or pre-render the chat destination.
            guard try await MountedReadinessWait.poll(condition: {
                capture.neutralRootAppearanceCompleted && window.isKeyWindow && !window.isHidden
            }) else {
                XCTFail("Timed out waiting for neutral reader-shell appearance: completed=\(capture.neutralRootAppearanceCompleted), key=\(window.isKeyWindow), hidden=\(window.isHidden)")
                return
            }

            var firstImages: [UIImage] = []
            for visit in 1...2 {
                let completed = capture.beginVisit()
                route.chatPresented = true
                await fulfillment(of: [completed], timeout: 4)
                XCTAssertEqual(capture.samples.map(\.tick), [1, 2, 3, 4],
                               "Every entry must retain the original first attachment tick and later ticks separately")
                for sample in capture.samples {
                    let image = try XCTUnwrap(sample.image, "The full window must be attached at tick \(sample.tick)")
                    let attachment = XCTAttachment(image: image)
                    attachment.name = "Production shell row \(savedRow) visit \(visit) raw tick \(sample.tick)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                    let geometry = XCTAttachment(string: sample.geometry)
                    geometry.name = "Production shell row \(savedRow) visit \(visit) geometry tick \(sample.tick)"
                    geometry.lifetime = .keepAlways
                    add(geometry)
                    if let presented = sample.presentedImage {
                        let attachment = XCTAttachment(image: presented)
                        attachment.name = "Production shell row \(savedRow) visit \(visit) presented tick \(sample.tick)"
                        attachment.lifetime = .keepAlways
                        add(attachment)
                    }
                    if let forced = sample.forcedDiagnostic {
                        let diagnostic = XCTAttachment(image: forced)
                        diagnostic.name = "Production shell row \(savedRow) visit \(visit) diagnostic forced tick \(sample.tick)"
                        diagnostic.lifetime = .keepAlways
                        add(diagnostic)
                    }
                }
                // The judged first tick is the presented render-server frame:
                // the raw layer-tree capture cannot represent display-list-backed
                // transcript content (same-tick blank vs readable proved in
                // daily-driver-firsttick-instrument-01); raw stays attached as
                // supplementary evidence.
                let firstImage = try XCTUnwrap(capture.samples.first?.presentedImage)
                firstImages.append(firstImage)
                // This visit has no user drag. An unconfirmed restore deliberately
                // preserves its durable seed on disappearance; clearing that seed
                // here would manufacture loss outside the production lifecycle.
                // Readback checks preservation, not a new write. The real-drag UI
                // test covers accepting a changed reader position before Back.
                XCTAssertEqual(restoreStore.load(server: server, sessionID: session.sessionId ?? session.id).visibleMessageID, targetID,
                               "Mounting without a user gesture must preserve the durable reader target")
                route.chatPresented = false
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertEqual(model.transcriptRestoreTarget, .message(id: targetID),
                               "ChatView disappearance must keep the display-row identity")
                XCTAssertEqual(restoreStore.load(server: server, sessionID: session.sessionId ?? session.id).visibleMessageID, targetID,
                               "Leaving without a user gesture must preserve the durable display-row identity")
            }
            let timeline = XCTAttachment(string: capture.probe.events.joined(separator: "\n"))
            timeline.name = "Production shell named-space restore trace, row \(savedRow)"
            timeline.lifetime = .keepAlways
            add(timeline)
            for (visit, firstImage) in firstImages.enumerated() {
                do {
                    XCTAssertEqual(try firstVisibleTranscriptMessageNumber(in: firstImage, prefix: "Restored"), savedRow,
                                   "The first presented frame at the first attached production tick on visit \(visit + 1) must show the saved reader row first")
                } catch {
                    XCTFail("Production shell first tick on visit \(visit + 1) could not be read: \(error)")
                }
            }
        }
    }

    #if DEBUG
    func testNativeMissingSavedTargetCompletesUnavailableOnceAndReleasesParent() async throws {
        let scope = UUID()
        let request = ChatTranscriptRestoreRequest(scope: scope, generation: 1,
                                                   target: .message(id: "not-loaded"))
        var parent = ChatTranscriptRestoreOutcomeState()
        parent.begin(request)
        var outcomes: [ChatTranscriptRestoreOutcome] = []
        let input = nativeRestoreRegressionInput(request: request) { delivered, outcome in
            XCTAssertEqual(delivered, request)
            outcomes.append(outcome)
            XCTAssertTrue(parent.complete(delivered, outcome: outcome, currentScope: scope))
        }
        let (controller, fixture) = try mountNativeRestoreRegression(input)
        defer { controller.stop(); tearDown(fixture) }

        // The real native layout queues its terminal result; no legacy proxy
        // callback or manufactured success participates in this assertion.
        XCTAssertEqual(controller.pendingRestore?.outcome, .unavailable)
        await drainNativeScrollQueue()
        XCTAssertEqual(outcomes, [.unavailable])
        XCTAssertEqual(controller.completedRequest, request)
        XCTAssertNil(parent.pending)
        XCTAssertTrue(parent.preservesDurableTarget)
        XCTAssertFalse(controller.follows, "A missing saved row must not become Latest intent")
        for _ in 0..<4 {
            controller.collection.setNeedsLayout()
            controller.collection.layoutIfNeeded()
            await drainNativeScrollQueue()
        }
        XCTAssertEqual(outcomes, [.unavailable], "Further layout must not repeat terminal delivery")
    }

    func testNativeMissingTargetReplacementRejectsQueuedUnavailableAndMeasuresNewTarget() async throws {
        let scope = UUID()
        let original = ChatTranscriptRestoreRequest(scope: scope, generation: 1,
                                                    target: .message(id: "not-loaded"))
        let replacement = ChatTranscriptRestoreRequest(scope: scope, generation: 2,
                                                       target: .message(id: "native-row-10"))
        var parent = ChatTranscriptRestoreOutcomeState()
        parent.begin(original)
        var deliveredRequests: [ChatTranscriptRestoreRequest] = []
        var outcomes: [ChatTranscriptRestoreOutcome] = []
        let completion: (ChatTranscriptRestoreRequest, ChatTranscriptRestoreOutcome) -> Void = { request, outcome in
            deliveredRequests.append(request)
            outcomes.append(outcome)
            XCTAssertTrue(parent.complete(request, outcome: outcome, currentScope: scope))
        }
        let (controller, fixture) = try mountNativeRestoreRegression(
            nativeRestoreRegressionInput(request: original, onRestore: completion))
        defer { controller.stop(); tearDown(fixture) }
        XCTAssertEqual(controller.pendingRestore?.outcome, .unavailable)

        // Replace before the queued old result drains, just as a new restore
        // request can supersede layout's previous producer callback.
        parent.begin(replacement)
        controller.update(nativeRestoreRegressionInput(request: replacement, onRestore: completion))
        for _ in 0..<8 {
            controller.collection.layoutIfNeeded()
            await drainNativeScrollQueue()
        }
        XCTAssertEqual(deliveredRequests, [replacement])
        XCTAssertEqual(outcomes, [.success])
        XCTAssertEqual(controller.completedRequest, replacement)
        XCTAssertNil(parent.pending)
        XCTAssertFalse(parent.preservesDurableTarget)
        let path = try XCTUnwrap(controller.dataSource.indexPath(for: .row("native-row-10")))
        XCTAssertNotNil(controller.collection.cellForItem(at: path))
        let layout = try XCTUnwrap(controller.collection.collectionViewLayout as? ChatNativeTranscriptViewport.Controller.ColumnLayout)
        XCTAssertTrue(layout.measured.contains(.row("native-row-10")))
        XCTAssertEqual(controller.currentAnchor()?.id, "native-row-10")
    }

    func testNativeMissingTargetCancellationSupersedesQueuedUnavailableOnce() async throws {
        let scope = UUID()
        let request = ChatTranscriptRestoreRequest(scope: scope, generation: 1,
                                                   target: .message(id: "not-loaded"))
        var parent = ChatTranscriptRestoreOutcomeState()
        parent.begin(request)
        var outcomes: [ChatTranscriptRestoreOutcome] = []
        let completion: (ChatTranscriptRestoreRequest, ChatTranscriptRestoreOutcome) -> Void = { delivered, outcome in
            XCTAssertEqual(delivered, request)
            outcomes.append(outcome)
            XCTAssertTrue(parent.complete(delivered, outcome: outcome, currentScope: scope))
        }
        let (controller, fixture) = try mountNativeRestoreRegression(
            nativeRestoreRegressionInput(request: request, onRestore: completion))
        defer { controller.stop(); tearDown(fixture) }
        XCTAssertEqual(controller.pendingRestore?.outcome, .unavailable)
        controller.update(nativeRestoreRegressionInput(request: request, cancellationToken: 1,
                                                        onRestore: completion))
        for _ in 0..<4 {
            controller.collection.layoutIfNeeded()
            await drainNativeScrollQueue()
        }
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertEqual(controller.completedRequest, request)
        XCTAssertNil(parent.pending)
        XCTAssertTrue(parent.preservesDurableTarget)
        XCTAssertFalse(controller.follows)
    }

    private func nativeRestoreRegressionInput(
        request: ChatTranscriptRestoreRequest, cancellationToken: Int = 0,
        onRestore: @escaping (ChatTranscriptRestoreRequest, ChatTranscriptRestoreOutcome) -> Void
    ) -> ChatNativeTranscriptViewport {
        let base = nativeMotionInput(scope: "native-restore-\(request.scope.uuidString)", initialID: nil,
                                     cancellationToken: cancellationToken, restoreRequest: request)
        return ChatNativeTranscriptViewport(
            ids: base.ids, revisionAt: base.revisionAt, revision: base.revision, typeKey: base.typeKey,
            scope: base.scope, initialID: base.initialID, restoreRequest: base.restoreRequest,
            cancellationToken: base.cancellationToken, latestToken: base.latestToken,
            explicitLatest: base.explicitLatest, following: base.following,
            horizontalPadding: base.horizontalPadding, spacing: base.spacing,
            bottomInset: base.bottomInset, environment: base.environment,
            makeRow: base.makeRow, makeHeader: base.makeHeader, makeFooter: base.makeFooter,
            onLatest: { XCTFail("Missing-target completion must not issue a Latest command") },
            onState: base.onState, onRestore: onRestore, onRefresh: base.onRefresh)
    }

    private func mountNativeRestoreRegression(_ input: ChatNativeTranscriptViewport) throws
        -> (ChatNativeTranscriptViewport.Controller, MountedWindowFixture) {
        let controller = ChatNativeTranscriptViewport.Controller(input: input)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (controller, MountedWindowFixture(window: window, previousKeyWindow: previous))
    }

    func testR58MountedBoundaryUnchangedKeyAndEagerControlGeometry() async throws {
        var frames: [[CGRect]] = []
        for eager in [false, true] {
            let (controller, fixture) = try mountNativeMotion(initialID: nil, ids: [])
            defer { controller.stop(); tearDown(fixture) }
            controller.reusesBoundaryConfigurations = !eager
            var input = nativeMotionInput(scope: controller.input.scope, initialID: nil, ids: [],
                                          footerHeight: 48, headerHeight: 24)
            input.headerRevision = .spacer(height: 24)
            input.footerRevision = .spacer(height: 48)
            controller.update(input)
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded()
            let before = controller.boundaryConfigurations
            let original = try nativeBoundaryFrames(controller)
            for _ in 0..<10 { controller.update(input) }
            controller.view.layoutIfNeeded()
            XCTAssertEqual(controller.boundaryConfigurations - before, eager ? 20 : 0)
            XCTAssertEqual(try nativeBoundaryFrames(controller), original)
            XCTAssertEqual(original[1].height, 48, accuracy: 1)
            frames.append(original)
            // The top host includes its realized safe-area contribution. Require
            // the requested growth, not equality with the bare SwiftUI height.
            input = nativeMotionInput(scope: input.scope, initialID: nil, ids: [],
                                      footerHeight: 48, headerHeight: 34)
            input.headerRevision = .spacer(height: 34)
            input.footerRevision = .spacer(height: 48)
            controller.update(input)
            try await Task.sleep(for: .milliseconds(100))
            controller.view.layoutIfNeeded()
            XCTAssertEqual(try nativeBoundaryFrames(controller)[0].height - original[0].height,
                           10, accuracy: 1)
        }
        XCTAssertEqual(frames[0], frames[1], "Reuse must preserve realized boundary geometry")
    }

    func testR58MountedBoundaryChangedAndAbsentKeysRefreshGeometry() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: nil, ids: [])
        defer { controller.stop(); tearDown(fixture) }
        var input = nativeMotionInput(scope: controller.input.scope, initialID: nil, ids: [],
                                      footerHeight: 48, headerHeight: 24)
        input.headerRevision = .spacer(height: 24)
        input.footerRevision = .spacer(height: 48)
        controller.update(input)
        try await Task.sleep(for: .milliseconds(100))
        let before = controller.boundaryConfigurations
        input = nativeMotionInput(scope: input.scope, initialID: nil, ids: [],
                                  footerHeight: 96, headerHeight: 24)
        input.headerRevision = .spacer(height: 24)
        input.footerRevision = .spacer(height: 96)
        controller.update(input)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(controller.boundaryConfigurations, before)
        XCTAssertEqual(try nativeBoundaryFrames(controller)[1].height, 96, accuracy: 1)
        // Missing keys restore the real factories, including independently changed content.
        controller.update(nativeMotionInput(scope: input.scope, initialID: nil, ids: [], footerHeight: 130))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try nativeBoundaryFrames(controller)[1].height, 130, accuracy: 1)
        let eagerBefore = controller.boundaryConfigurations
        controller.update(controller.input)
        XCTAssertEqual(controller.boundaryConfigurations - eagerBefore, 2)
    }

    func testR58MountedBoundaryScopeTypeWidthLifecycleAndReappearance() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: nil, ids: [])
        defer { controller.stop(); tearDown(fixture) }
        func keyed(scope: String, type: String) -> ChatNativeTranscriptViewport {
            var input = nativeMotionInput(scope: scope, initialID: nil, ids: [],
                                          footerHeight: 48, typeKey: type, headerHeight: 24)
            input.headerRevision = .spacer(height: 24)
            input.footerRevision = .spacer(height: 48)
            return input
        }
        controller.update(keyed(scope: controller.input.scope, type: "first"))
        try await Task.sleep(for: .milliseconds(100))
        for input in [keyed(scope: controller.input.scope, type: "second"),
                      keyed(scope: "r58-replacement-\(UUID())", type: "second")] {
            let before = controller.boundaryConfigurations
            controller.update(input)
            try await Task.sleep(for: .milliseconds(60))
            XCTAssertGreaterThan(controller.boundaryConfigurations, before)
            XCTAssertEqual(try nativeBoundaryFrames(controller)[1].height, 48, accuracy: 1)
        }
        let oldWidth = try nativeBoundaryFrames(controller)[0].width
        let beforeWidth = controller.boundaryConfigurations
        controller.view.frame.size.width -= 40
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertGreaterThan(controller.boundaryConfigurations, beforeWidth)
        XCTAssertEqual(try nativeBoundaryFrames(controller)[0].width, oldWidth - 40, accuracy: 1)
        let beforeResumeFrames = try nativeBoundaryFrames(controller)
        let boundaryItems: [ChatNativeTranscriptViewport.Controller.Item] = [.header, .footer]
        let boundaryCells = try boundaryItems.map { item in
            let path = try XCTUnwrap(controller.dataSource.indexPath(for: item))
            return try XCTUnwrap(controller.collection.cellForItem(at: path) as? ChatNativeTranscriptViewport.Controller.Cell)
        }
        let beforeResumeStamps = boundaryCells.map(\.boundaryStamp)
        controller.suspendPresentation()
        controller.presentationVisible = true
        controller.applicationActive = true
        let beforeResume = controller.boundaryConfigurations
        controller.resumePresentation()
        XCTAssertEqual(controller.boundaryConfigurations - beforeResume, 2,
                       "Resume must immediately reacquire both realized boundary hosts")
        for (index, item) in boundaryItems.enumerated() {
            XCTAssertNotEqual(boundaryCells[index].boundaryStamp, beforeResumeStamps[index])
            XCTAssertEqual(boundaryCells[index].boundaryStamp, controller.boundaryStamp(for: item))
            XCTAssertNotNil(boundaryCells[index].contentConfiguration)
            XCTAssertNotNil(boundaryCells[index].didFit)
        }
        XCTAssertEqual(try nativeBoundaryFrames(controller), beforeResumeFrames,
                       "Resume must preserve the refreshed boundary geometry")
        let afterResume = controller.boundaryConfigurations
        controller.update(controller.input)
        XCTAssertEqual(controller.boundaryConfigurations, afterResume,
                       "An identical update must reuse the hosts refreshed by resume")
        XCTAssertEqual(try nativeBoundaryFrames(controller), beforeResumeFrames)

        var longInput = nativeMotionInput(scope: controller.input.scope, initialID: "native-row-0", headerHeight: 24)
        longInput.headerRevision = .spacer(height: 24)
        controller.update(longInput)
        try await Task.sleep(for: .milliseconds(100))
        controller.ownership = .reading
        controller.anchor = nil // This fixture positions directly, without a UIKit drag.
        controller.collection.setContentOffset(.zero, animated: false)
        controller.collection.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let headerPath = try XCTUnwrap(controller.dataSource.indexPath(for: .header))
        let headerHeight = try XCTUnwrap(controller.collection.cellForItem(at: headerPath)).frame.height
        controller.collection.setContentOffset(CGPoint(x: 0, y: controller.bottomOffset), animated: false)
        controller.collection.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.collection.indexPathsForVisibleItems.contains(headerPath))
        longInput = nativeMotionInput(scope: controller.input.scope, initialID: "native-row-0", headerHeight: 77)
        longInput.headerRevision = .spacer(height: 77)
        controller.update(longInput)
        controller.collection.setContentOffset(.zero, animated: false)
        controller.collection.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        controller.collection.layoutIfNeeded()
        let header = try XCTUnwrap(controller.collection.cellForItem(at: headerPath))
        XCTAssertTrue(controller.collection.indexPathsForVisibleItems.contains(headerPath))
        XCTAssertEqual(header.frame.height - headerHeight, 53, accuracy: 1,
                       "Reappearing cells must apply the requested 24-to-77 height growth")
        // Force a new dequeue with an unchanged key as well.
        let beforeReload = controller.boundaryConfigurations
        controller.collection.reloadData()
        controller.collection.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertGreaterThan(controller.boundaryConfigurations, beforeReload)
        XCTAssertEqual(try XCTUnwrap(controller.collection.cellForItem(at: headerPath)).frame.height,
                       headerHeight + 53, accuracy: 1)
    }

    private func nativeBoundaryFrames(_ controller: ChatNativeTranscriptViewport.Controller) throws -> [CGRect] {
        try [ChatNativeTranscriptViewport.Controller.Item.header, .footer].map { item in
            let path = try XCTUnwrap(controller.dataSource.indexPath(for: item))
            let cell = try XCTUnwrap(controller.collection.cellForItem(at: path))
            return cell.frame
        }
    }

    func testMountedNativeIdentityReusePreservesContentScopeAndStructuralChanges() async throws {
        let scope = "identity-cache-\(UUID().uuidString)"
        let (controller, fixture) = try mountNativeMotion(scope: scope, initialID: "native-row-5")
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        let original = controller.input.ids
        XCTAssertEqual(controller.identityBuilds, 1)
        for _ in 0..<20 { controller.update(controller.input) }
        XCTAssertEqual(controller.identityBuilds, 1, "Unchanged identity must not rebuild the history index")

        for (nextScope, text) in [(scope, "Updated current content العربية 👩🏽‍💻"),
                                  (scope + "-replacement", "Replacement scope content")] {
            controller.update(nativeMotionInput(scope: nextScope, initialID: "native-row-5",
                                                revision: 1, liveText: text))
            controller.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertEqual(controller.identityBuilds, 1, "Equal IDs may reuse structure, never stale row content")
            let revision = try XCTUnwrap(controller.revisions["native-row-6"])
            XCTAssertEqual(revision.message.message.content, text)
        }
        let sequences = [original + ["append"], ["prepend"] + original + ["append"],
                         ["prepend"] + Array(original.reversed()), ["replacement"], []]
        for (index, ids) in sequences.enumerated() {
            controller.update(nativeMotionInput(scope: controller.input.scope,
                                                initialID: ids.first ?? "", ids: ids))
            controller.view.layoutIfNeeded()
            XCTAssertEqual(controller.identityBuilds, index + 2)
            XCTAssertEqual(controller.indices, Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) }))
            XCTAssertEqual(controller.dataSource.snapshot().itemIdentifiers,
                           [.header] + ids.map(ChatNativeTranscriptViewport.Controller.Item.row) + [.footer])
            XCTAssertTrue(controller.revisions.keys.allSatisfy { controller.indices[$0] != nil },
                          "Removed rows must not accumulate revision payloads")
        }
    }

    func testMountedNativeColumnAttributesTrackCommittedStructuralSnapshotsImmediately() async throws {
        typealias Owner = ChatNativeTranscriptViewport.Controller
        let scope = "column-commit-\(UUID())"
        let original = (0..<4).map { "native-row-\($0)" }
        let (controller, fixture) = try mountNativeMotion(scope: scope, initialID: original[0], ids: original)
        defer { controller.stop(); tearDown(fixture) }
        await drainNativeScrollQueue()
        let layout = try XCTUnwrap(controller.collection.collectionViewLayout as? Owner.ColumnLayout)
        _ = try assertNativeCommittedColumnAttributes(controller)
        let removedPath = try XCTUnwrap(controller.dataSource.indexPath(for: .row(original[3])))
        let removedFit = try XCTUnwrap(layout.layoutAttributesForItem(at: removedPath)?.copy() as? UICollectionViewLayoutAttributes)
        let oldKey = try XCTUnwrap(layout.key)
        removedFit.size.height = 999

        // No layoutIfNeeded or queue drain between update and these queries:
        // cached pre-shrink frames must not leak indices 2, 3, 4 into a 2-item
        // collection, and growth/replacement must expose their current geometry.
        let sequences = [[], original + ["appended"], ["replacement-a", "replacement-b"],
                         ["replacement-b", "replacement-a"], ["final-row"]]
        for (revision, ids) in sequences.enumerated() {
            controller.update(nativeMotionInput(scope: scope, initialID: ids.first, ids: ids,
                                                revision: revision + 1))
            XCTAssertEqual(controller.dataSource.snapshot().itemIdentifiers,
                           [.header] + ids.map(Owner.Item.row) + [.footer])
            _ = try assertNativeCommittedColumnAttributes(controller)
            if !ids.contains(original[3]) {
                layout.didFit(removedFit, item: .row(original[3]), key: oldKey)
                XCTAssertFalse(layout.measured.contains(.row(original[3])),
                               "A retired source receipt must not revive a removed measurement")
            }
            controller.collection.layoutIfNeeded()
            await drainNativeScrollQueue()
            _ = try assertNativeCommittedColumnAttributes(controller)
            XCTAssertTrue(controller.revisions.keys.allSatisfy { controller.indices[$0] != nil })
        }
    }

    func testMountedNativeColumnSameCountTypeAndScopeCommitRejectsStaleGeometryAndReceipts() async throws {
        typealias Owner = ChatNativeTranscriptViewport.Controller
        let scope = "column-key-\(UUID())"
        let ids = ["native-row-0", "native-row-1"]
        let (controller, fixture) = try mountNativeMotion(scope: scope, initialID: ids[0], ids: ids)
        defer { controller.stop(); tearDown(fixture) }
        await drainNativeScrollQueue()
        let layout = try XCTUnwrap(controller.collection.collectionViewLayout as? Owner.ColumnLayout)
        let path = try XCTUnwrap(controller.dataSource.indexPath(for: .row(ids[0])))
        let cell = try XCTUnwrap(controller.collection.cellForItem(at: path) as? Owner.Cell)
        let staleFit = try XCTUnwrap(cell.didFit)
        let oldAttributes = try XCTUnwrap(layout.layoutAttributesForItem(at: path)?.copy() as? UICollectionViewLayoutAttributes)
        oldAttributes.size.height = 999
        let before = try assertNativeCommittedColumnAttributes(controller)

        // Same-count changes cannot be detected by clipping cached indices.
        // Padding changes make stale frame widths directly observable before prepare.
        for (revision, nextScope, type, padding) in [(1, scope, "column-new-type", CGFloat(40)),
                                                    (2, scope + "-replacement", "column-new-type", CGFloat(70))] {
            controller.update(nativeMotionInput(scope: nextScope, initialID: ids[0], ids: ids,
                revision: revision, typeKey: type, horizontalPadding: padding,
                rowContentPrefix: "Current canonical revision \(revision) row "))
            let immediate = try assertNativeCommittedColumnAttributes(controller)
            XCTAssertNotEqual(immediate[1].width, before[1].width)
            staleFit(oldAttributes)
            XCTAssertEqual(try assertNativeCommittedColumnAttributes(controller), immediate,
                           "A receipt from the previous content/key must not change current frames")
            controller.collection.layoutIfNeeded()
            await drainNativeScrollQueue()
            _ = try assertNativeCommittedColumnAttributes(controller)
            let currentCell = try XCTUnwrap(controller.collection.cellForItem(at: path) as? Owner.Cell)
            XCTAssertEqual(currentCell.rowStamp, controller.rowStamp(for: ids[0]))
            XCTAssertEqual(controller.revisions[ids[0]]?.message.message.content,
                           "Current canonical revision \(revision) row 0")
        }
    }

    @discardableResult
    private func assertNativeCommittedColumnAttributes(_ controller: ChatNativeTranscriptViewport.Controller,
                                                       file: StaticString = #filePath, line: UInt = #line) throws -> [CGRect] {
        let collection = controller.collection!
        let layout = collection.collectionViewLayout
        let count = collection.numberOfItems(inSection: 0)
        XCTAssertEqual(count, controller.dataSource.snapshot().numberOfItems, file: file, line: line)
        let rect = CGRect(x: -1_000, y: -1_000, width: 100_000, height: 1_000_000)
        let elements = try XCTUnwrap(layout.layoutAttributesForElements(in: rect), file: file, line: line)
        XCTAssertEqual(elements.map(\.indexPath), (0..<count).map { IndexPath(item: $0, section: 0) },
                       "Every committed item must have exactly one current attribute", file: file, line: line)
        XCTAssertTrue(elements.allSatisfy { $0.indexPath.section == 0 && $0.indexPath.item < count },
                      "Element attributes must be inside UIKit's committed count", file: file, line: line)
        XCTAssertNil(layout.layoutAttributesForItem(at: IndexPath(item: count, section: 0)), file: file, line: line)
        XCTAssertNil(layout.layoutAttributesForItem(at: IndexPath(item: count + 3, section: 0)), file: file, line: line)
        XCTAssertNil(layout.layoutAttributesForItem(at: IndexPath(item: -1, section: 0)), file: file, line: line)
        XCTAssertNil(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 1)), file: file, line: line)
        var frames: [CGRect] = []
        for index in 0..<count {
            let path = IndexPath(item: index, section: 0)
            let attribute = try XCTUnwrap(layout.layoutAttributesForItem(at: path), file: file, line: line)
            let element = try XCTUnwrap(elements.first { $0.indexPath == path }, file: file, line: line)
            XCTAssertEqual(attribute.frame, element.frame, file: file, line: line)
            XCTAssertEqual(attribute.frame.minX, controller.input.horizontalPadding, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(attribute.frame.width, max(1, collection.bounds.width - 2 * controller.input.horizontalPadding),
                           accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(attribute.frame.minY, frames.last.map { $0.maxY + controller.input.spacing } ?? 16,
                           accuracy: 0.01, file: file, line: line)
            frames.append(attribute.frame)
        }
        XCTAssertEqual(layout.collectionViewContentSize.height,
                       (frames.last?.maxY ?? 16) + controller.input.bottomInset,
                       accuracy: 0.01, file: file, line: line)
        return frames
    }

    func testMountedNativeIdentityReuseUpdatePathMeasurement() async throws {
        let ids = (0..<1_000).map { "native-row-\($0)" }
        let updates = 120
        var samples: [[String: Any]] = []
        for trial in 0..<3 {
            for reuse in (trial.isMultiple(of: 2) ? [false, true] : [true, false]) {
                let scope = "identity-measure-\(trial)-\(reuse)"
                let (controller, fixture) = try mountNativeMotion(scope: scope, initialID: "native-row-5",
                                                                  ids: ids, reusesIdentitySnapshot: reuse)
                defer { controller.stop(); tearDown(fixture) }
                try await Task.sleep(for: .milliseconds(60))
                // Fresh equal arrays resemble repeated SwiftUI inputs. Prepare
                // outside timing; measure actual mounted controller update work.
                let inputs = (0..<updates).map { tick in
                    nativeMotionInput(scope: scope, initialID: "native-row-5",
                                      ids: ids.map { "\($0)" }, revision: tick)
                }
                let start = CACurrentMediaTime()
                for input in inputs { controller.update(input) }
                let elapsed = CACurrentMediaTime() - start
                XCTAssertEqual(controller.identityBuilds, reuse ? 1 : updates + 1)
                XCTAssertEqual(controller.indices.count, ids.count)
                samples.append(["trial": trial, "reuses_identity": reuse, "updates": updates,
                                "logical_rows": ids.count, "elapsed_seconds": elapsed,
                                "identity_builds": controller.identityBuilds,
                                "mounted_cells": controller.collection.visibleCells.count])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "scope": "Mounted native controller update CPU wall time, no layout drain in timed loop; not FPS or whole-chat latency",
            "samples": samples
        ], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "r43-native-identity-update-measurement"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMountedNativeMotionResignActiveCancelsWithoutResumeSnap() async throws {
        let (controller, fixture) = try mountNativeMotion()
        defer { controller.stop(); tearDown(fixture) }
        try await startMountedNativeMotion(controller)
        let before = try XCTUnwrap(controller.currentAnchor())
        let offset = controller.collection.contentOffset.y
        let completed = controller.motionCompleted
        let cancelled = controller.motionCancelled
        let epoch = controller.presentationEpoch
        // Deliver the real UIKit notification, not the controller's handler.
        // This is notification mechanics coverage, not physical backgrounding.
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification,
                                        object: UIApplication.shared)
        XCTAssertNil(controller.motionLink)
        XCTAssertEqual(controller.motionCancelled, cancelled + 1)
        XCTAssertGreaterThan(controller.presentationEpoch, epoch)
        let samples = controller.motionSamples
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(controller.motionSamples, samples)
        XCTAssertEqual(controller.collection.contentOffset.y, offset, accuracy: 1)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification,
                                        object: UIApplication.shared)
        try await assertNativeReaderRemains(controller, id: before.id, delta: before.delta,
                                           offset: offset, completed: completed)
    }

    func testMountedNativeMotionDisappearanceCancelsWithoutResumeSnap() async throws {
        let (controller, fixture) = try mountNativeMotion()
        defer { controller.stop(); tearDown(fixture) }
        try await startMountedNativeMotion(controller)
        let completed = controller.motionCompleted
        let cancelled = controller.motionCancelled
        let cover = UIViewController()
        cover.view.backgroundColor = .systemBackground
        cover.modalPresentationStyle = .fullScreen
        let disappeared = expectation(description: "UIKit completes full-screen cover")
        controller.present(cover, animated: false) { disappeared.fulfill() }
        await fulfillment(of: [disappeared], timeout: 2)
        XCTAssertTrue(controller.presentedViewController === cover)
        XCTAssertNil(controller.view.window, "A real full-screen presentation must detach the transcript")
        XCTAssertNil(controller.motionLink)
        XCTAssertEqual(controller.motionCancelled, cancelled + 1)
        // UIKit may run another motion tick before delivering viewWillDisappear.
        // Score the cancellation boundary, not the earlier presentation request.
        let before = try XCTUnwrap(controller.anchor)
        let offset = controller.collection.contentOffset.y
        let cancelledSamples = controller.motionSamples
        XCTAssertEqual(controller.motionCompleted, completed)
        let resumed = expectation(description: "UIKit completes transcript reappearance")
        cover.dismiss(animated: false) { resumed.fulfill() }
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertTrue(controller.view.window === fixture.window)
        try await assertNativeReaderRemains(controller, id: before.id, delta: before.delta,
                                           offset: offset, completed: completed)
        XCTAssertEqual(controller.motionSamples, cancelledSamples)
    }

    func testMountedNativeReduceMotionReachesRealizedTailWithoutAnimation() async throws {
        let (controller, fixture) = try mountNativeMotion(reduceMotion: true)
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(controller.realizedTailArrival)
        controller.latest.sendActions(for: .touchUpInside)
        XCTAssertNil(controller.motionLink)
        for _ in 0..<40 {
            if controller.realizedTailArrival { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(controller.realizedTailArrival, "Reduce Motion still needs a mounted, measured footer")
        XCTAssertTrue(controller.follows)
        XCTAssertEqual(controller.motionSamples, 0)
        XCTAssertEqual(controller.motionCompleted, 0)
    }

    func testMountedNativeParkedLiveRevisionsKeepAnchorThroughEachChunk() async throws {
        let scope = "native-stream-\(UUID().uuidString)"
        let (controller, fixture) = try mountNativeMotion(scope: scope, initialID: "native-row-5")
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        let parked = try XCTUnwrap(controller.currentAnchor())
        XCTAssertEqual(parked.id, "native-row-5")
        let offset = controller.collection.contentOffset.y
        var text = ""
        var samples: [String] = []
        defer {
            let evidence = XCTAttachment(string: samples.joined(separator: "\n"))
            evidence.name = "Mounted native live revision anchor samples (synthetic inputs)"
            evidence.lifetime = .keepAlways
            add(evidence)
        }
        for chunk in 1...6 {
            text += "Live chunk \(chunk): source continues across the mounted native row.\n"
            let active = chunk < 6
            controller.update(nativeMotionInput(scope: scope, initialID: "native-row-5",
                                                revision: chunk, liveText: text, active: active))
            try await Task.sleep(for: .milliseconds(60))
            let current = try XCTUnwrap(controller.currentAnchor())
            XCTAssertEqual(current.id, parked.id, "Chunk \(chunk), active=\(active)")
            XCTAssertEqual(current.delta, parked.delta, accuracy: 1)
            XCTAssertEqual(controller.collection.contentOffset.y, offset, accuracy: 1)
            XCTAssertFalse(controller.follows)
            XCTAssertNil(controller.motionLink)
            // The changing row is actually realized and reconfigured during the
            // live samples; this is not just a completed endpoint assertion.
            let path = try XCTUnwrap(controller.dataSource.indexPath(for: .row("native-row-6")))
            XCTAssertNotNil(controller.collection.cellForItem(at: path))
            let rendered = try XCTUnwrap(controller.revisions["native-row-6"])
            XCTAssertEqual(rendered.message.message.content, text)
            XCTAssertEqual(rendered.hasActiveStream, active)
            XCTAssertEqual(rendered.streamingAssistantMessageID, active ? "native-row-6" : nil)
            samples.append("chunk=\(chunk) active=\(active) anchor=\(current.id) delta=\(current.delta) offset=\(controller.collection.contentOffset.y) sourceCharacters=\(text.count)")
        }
    }

    // Delegate delivery below exercises mounted ownership mechanics only. The
    // UI journey must independently prove a physical status-bar tap is delivered.
    func testMountedNativeSystemTopOwnsMotionThroughParentEchoAndCompletion() async throws {
        let (controller, fixture) = try mountNativeMotion()
        defer { controller.stop(); tearDown(fixture) }
        try await startMountedNativeMotion(controller)
        XCTAssertTrue(controller.scrollViewShouldScrollToTop(controller.collection))
        XCTAssertNil(controller.motionLink)
        XCTAssertTrue(controller.interacting)
        XCTAssertTrue(controller.lastPublished?.metrics.isDirectlyInteracting == true)
        let echo = try XCTUnwrap(controller.latestEchoCancellationToken)
        controller.update(nativeMotionInput(scope: controller.input.scope,
            initialID: "native-row-1", cancellationToken: echo, following: true))
        XCTAssertTrue(controller.systemTopActive)
        let midpoint = controller.collection.contentOffset.y / 2
        controller.collection.setContentOffset(CGPoint(x: 0, y: midpoint), animated: false)
        controller.collection.layoutIfNeeded()
        controller.settleLayout()
        XCTAssertEqual(controller.collection.contentOffset.y, midpoint, accuracy: 1)
        controller.collection.setContentOffset(CGPoint(x: 0, y: -controller.collection.adjustedContentInset.top), animated: false)
        controller.collection.layoutIfNeeded()
        controller.scrollViewDidScrollToTop(controller.collection)
        controller.settleLayout()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(controller.systemTopActive)
        XCTAssertFalse(controller.follows)
        XCTAssertEqual(controller.systemTopRequests, 1)
        XCTAssertEqual(controller.systemTopCompleted, 1)
        XCTAssertEqual(controller.collection.contentOffset.y, -controller.collection.adjustedContentInset.top, accuracy: 1)
        XCTAssertEqual(controller.currentAnchor()?.id, "native-row-0")
        XCTAssertTrue(controller.probe.accessibilityValue?.contains("topCompleted=1") == true)
        XCTAssertTrue(controller.scrollViewShouldScrollToTop(controller.collection))
        controller.latest.sendActions(for: .touchUpInside)
        XCTAssertFalse(controller.systemTopActive, "A newer explicit latest tap must replace OS ascent")
        XCTAssertNotNil(controller.motionLink)
    }

    func testMountedNativeSystemTopCancellationRejectsStaleCompletionAndResume() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-5")
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(controller.scrollViewShouldScrollToTop(controller.collection))
        let offset = controller.collection.contentOffset.y
        NotificationCenter.default.post(name: UIApplication.willResignActiveNotification,
                                        object: UIApplication.shared)
        XCTAssertFalse(controller.systemTopActive)
        controller.scrollViewDidScrollToTop(controller.collection)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification,
                                        object: UIApplication.shared)
        // An ordinary follow echo without a cancellation edge is not a new tap.
        controller.update(nativeMotionInput(scope: controller.input.scope,
            initialID: "native-row-5", following: true))
        controller.collection.layoutIfNeeded()
        XCTAssertFalse(controller.follows)
        controller.update(nativeMotionInput(scope: controller.input.scope,
            initialID: "native-row-5", cancellationToken: 1, following: true))
        controller.collection.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(controller.collection.contentOffset.y, offset, accuracy: 1)
        XCTAssertFalse(controller.follows)
        XCTAssertEqual(controller.systemTopCompleted, 0)
        XCTAssertTrue(controller.scrollViewShouldScrollToTop(controller.collection))
        controller.scrollViewWillBeginDragging(controller.collection)
        controller.scrollViewDidScrollToTop(controller.collection)
        XCTAssertFalse(controller.systemTopActive)
        XCTAssertEqual(controller.systemTopCompleted, 0)
        XCTAssertTrue(controller.scrollViewShouldScrollToTop(controller.collection))
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1,
                                                   target: .message(id: "native-row-10"))
        controller.update(nativeMotionInput(scope: controller.input.scope,
            initialID: "native-row-5", cancellationToken: 1, restoreRequest: request))
        controller.scrollViewDidScrollToTop(controller.collection)
        XCTAssertFalse(controller.systemTopActive)
        if case .restoring(let target) = controller.ownership {
            XCTAssertEqual(target?.id, "native-row-10")
        } else {
            XCTFail("A new restore must replace system-top ownership")
        }
        XCTAssertEqual(controller.systemTopCompleted, 0)
    }

    func testMountedNativeQueuedRefreshDoesNotStartAfterScopeChangeOrStop() async throws {
        for stops in [false, true] {
            var firstCalls = 0
            var replacementCalls = 0
            let (controller, fixture) = try mountNativeMotion(onRefresh: { _ in firstCalls += 1 })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertTrue(controller.isPresentationActive)
            let refresh = try XCTUnwrap(controller.collection.refreshControl)
            refresh.beginRefreshing()
            controller.refreshHistory()
            let queued = try XCTUnwrap(controller.refreshTask)
            XCTAssertTrue(refresh.isRefreshing)
            // No suspension between queueing and invalidating: the backend task
            // has not begun its first main-actor turn.
            if stops {
                controller.stop()
            } else {
                controller.update(nativeMotionInput(scope: "replacement-\(UUID())", initialID: "native-row-5",
                    onRefresh: { _ in replacementCalls += 1 }))
            }
            XCTAssertNil(controller.refreshTask)
            XCTAssertFalse(refresh.isRefreshing, "Obsolete spinner must end synchronously")
            await queued.value
            XCTAssertEqual(firstCalls, 0)
            XCTAssertEqual(replacementCalls, 0, "A queued old refresh cannot call the new chat")
        }
    }

    func testMountedNativeOldRefreshCannotFinishReplacementAndCoverKeepsOwner() async throws {
        let firstStarted = expectation(description: "First backend refresh entered")
        let replacementStarted = expectation(description: "Replacement backend refresh entered")
        var firstFinish: CheckedContinuation<Void, Never>?
        var replacementFinish: CheckedContinuation<Void, Never>?
        var firstCurrent: (@MainActor () -> Bool)?
        var replacementCurrent: (@MainActor () -> Bool)?
        var firstCalls = 0
        let (controller, fixture) = try mountNativeMotion(onRefresh: { isCurrent in
            firstCalls += 1
            firstCurrent = isCurrent
            await withCheckedContinuation { continuation in
                firstFinish = continuation
                firstStarted.fulfill()
            }
        })
        defer {
            controller.stop(); tearDown(fixture)
            firstFinish?.resume(); replacementFinish?.resume()
        }
        try await Task.sleep(for: .milliseconds(80))
        let refresh = try XCTUnwrap(controller.collection.refreshControl)
        refresh.beginRefreshing()
        controller.refreshHistory()
        let oldTask = try XCTUnwrap(controller.refreshTask)
        await fulfillment(of: [firstStarted], timeout: 2)
        controller.refreshHistory()
        XCTAssertEqual(firstCalls, 1, "Duplicate gestures retain a single owner")
        XCTAssertTrue(try XCTUnwrap(firstCurrent)())
        controller.update(nativeMotionInput(scope: "replacement-\(UUID())", initialID: "native-row-5",
            onRefresh: { isCurrent in
                replacementCurrent = isCurrent
                await withCheckedContinuation { continuation in
                    replacementFinish = continuation
                    replacementStarted.fulfill()
                }
            }))
        XCTAssertFalse(try XCTUnwrap(firstCurrent)())
        XCTAssertFalse(refresh.isRefreshing)
        refresh.beginRefreshing()
        controller.refreshHistory()
        let replacementTask = try XCTUnwrap(controller.refreshTask)
        await fulfillment(of: [replacementStarted], timeout: 2)
        firstFinish?.resume(); firstFinish = nil
        await oldTask.value
        XCTAssertNotNil(controller.refreshTask)
        XCTAssertTrue(refresh.isRefreshing, "Old completion must not dismiss the new spinner")
        XCTAssertTrue(try XCTUnwrap(replacementCurrent)())
        // Same-chat temporary coverage affects presentation, not refresh ownership.
        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        let covered = expectation(description: "Refresh viewport covered")
        controller.present(cover, animated: false) { covered.fulfill() }
        await fulfillment(of: [covered], timeout: 2)
        XCTAssertTrue(controller.presentationSuspended)
        XCTAssertNotNil(controller.refreshTask)
        XCTAssertTrue(try XCTUnwrap(replacementCurrent)())
        replacementFinish?.resume(); replacementFinish = nil
        await replacementTask.value
        XCTAssertNil(controller.refreshTask)
        XCTAssertFalse(refresh.isRefreshing)
        let resumed = expectation(description: "Refresh viewport returns")
        cover.dismiss(animated: false) { resumed.fulfill() }
        await fulfillment(of: [resumed], timeout: 2)
        XCTAssertTrue(controller.isPresentationActive)
    }

    func testMountedNativeSuspendedRefreshDoesNotRetainStoppedViewport() async throws {
        let started = expectation(description: "Backend refresh suspended")
        var finish: CheckedContinuation<Void, Never>?
        var isCurrent: (@MainActor () -> Bool)?
        var mounted: (ChatNativeTranscriptViewport.Controller, MountedWindowFixture)? = try mountNativeMotion(onRefresh: { current in
            isCurrent = current
            await withCheckedContinuation { continuation in
                finish = continuation
                started.fulfill()
            }
        })
        let fixture = try XCTUnwrap(mounted?.1)
        defer { mounted?.0.stop(); tearDown(fixture); finish?.resume() }
        try await Task.sleep(for: .milliseconds(80))
        weak var owner = mounted?.0
        mounted?.0.refreshHistory()
        let task = try XCTUnwrap(mounted?.0.refreshTask)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(try XCTUnwrap(isCurrent)())
        mounted?.0.stop()
        tearDown(fixture)
        mounted = nil
        // UIKit can defer the release of its detached root; backend work remains
        // suspended throughout this bounded observation.
        for _ in 0..<20 {
            if owner == nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(try XCTUnwrap(isCurrent)())
        XCTAssertNil(owner, "A suspended backend callback must not retain the stopped viewport")
        finish?.resume(); finish = nil
        await task.value
    }

    // Injected UIKit state models the ownership boundary; these tests do not
    // synthesize physical momentum or prove the real-gesture probe counter.
    private final class ModeledMomentumCollection: ChatNativeTranscriptViewport.Collection {
        var modeledDeceleration = false
        var modeledDragging = false
        var modeledTracking = false
        var stoppedMomentumAt: CGPoint?
        var onMomentumStopped: (() -> Void)?
        override var isDecelerating: Bool { modeledDeceleration }
        override var isDragging: Bool { modeledDragging }
        override var isTracking: Bool { modeledTracking }
        override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            if modeledDeceleration && !animated {
                stoppedMomentumAt = contentOffset
                modeledDeceleration = false
                onMomentumStopped?()
            }
            super.setContentOffset(contentOffset, animated: animated)
        }
    }

    func testMountedNativeModeledDecelerationLatestTakeoverRejectsStaleEndsAndEcho() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Animated ownership requires Reduce Motion off")
        let (controller, fixture) = try mountNativeMotion(makeCollection: {
            ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0)
        })
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
        let offset = collection.contentOffset
        collection.modeledDeceleration = true
        controller.jumpToLatest()
        let link = try XCTUnwrap(controller.motionLink)
        XCTAssertEqual(collection.stoppedMomentumAt, offset)
        XCTAssertEqual(controller.decelerationTakeovers, 1, "Injected state only; not physical gesture evidence")
        XCTAssertTrue(controller.probe.accessibilityValue?.contains("decelerationTakeovers=1") == true)
        controller.scrollViewDidEndDragging(collection, willDecelerate: false)
        controller.scrollViewDidEndDecelerating(collection)
        XCTAssertTrue(controller.motionLink === link)
        XCTAssertTrue(controller.follows)
        // A trailing deceleration observation is also not a new finger gesture.
        collection.modeledDeceleration = true
        controller.advanceMotion(link)
        XCTAssertTrue(controller.motionLink === link)
        XCTAssertEqual(controller.decelerationTakeovers, 1)
        collection.modeledDeceleration = false
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-1",
            cancellationToken: try XCTUnwrap(controller.latestEchoCancellationToken), following: true))
        XCTAssertTrue(controller.motionLink === link)
        XCTAssertTrue(controller.explicitLatestOwnsViewport)
        XCTAssertEqual(controller.decelerationTakeovers, 1)
        controller.scrollViewWillBeginDragging(collection)
        XCTAssertNil(controller.motionLink)
        XCTAssertFalse(controller.explicitLatestOwnsViewport)
        XCTAssertFalse(controller.follows)
    }

    func testMountedNativeModeledDecelerationExplicitEdgeTakeoverAndCancellation() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Animated ownership requires Reduce Motion off")
        let (controller, fixture) = try mountNativeMotion(makeCollection: {
            ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0)
        })
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
        collection.modeledDeceleration = true
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-1",
            explicitLatest: true))
        let link = try XCTUnwrap(controller.motionLink)
        controller.scrollViewDidEndDecelerating(collection)
        XCTAssertTrue(controller.motionLink === link)
        XCTAssertTrue(controller.follows)
        XCTAssertEqual(controller.decelerationTakeovers, 1)
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-1",
            cancellationToken: 1, explicitLatest: true))
        XCTAssertNil(controller.motionLink)
        XCTAssertFalse(controller.explicitLatestOwnsViewport)
        XCTAssertFalse(controller.follows)
    }

    func testMountedNativeModeledDirectTouchRejectsLatestAndExplicitEdge() async throws {
        for tracking in [true, false] {
            let (controller, fixture) = try mountNativeMotion(makeCollection: {
                ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0)
            })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(100))
            let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
            collection.modeledTracking = tracking
            collection.modeledDragging = !tracking
            collection.modeledDeceleration = true
            controller.jumpToLatest()
            controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-1",
                explicitLatest: true))
            XCTAssertNil(controller.motionLink)
            XCTAssertNil(controller.latestEchoCancellationToken)
            XCTAssertFalse(controller.explicitLatestOwnsViewport)
            XCTAssertFalse(controller.follows)
            XCTAssertEqual(controller.decelerationTakeovers, 0)
            XCTAssertNil(collection.stoppedMomentumAt)
        }
    }

    func testMountedNativeModeledDecelerationReduceMotionRetainsOwnershipUntilSuspension() async throws {
        let (controller, fixture) = try mountNativeMotion(reduceMotion: true, makeCollection: {
            ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0)
        })
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
        collection.modeledDeceleration = true
        controller.jumpToLatest()
        controller.scrollViewDidEndDragging(collection, willDecelerate: false)
        controller.scrollViewDidEndDecelerating(collection)
        XCTAssertNil(controller.motionLink)
        XCTAssertTrue(controller.follows)
        XCTAssertTrue(controller.explicitLatestOwnsViewport)
        XCTAssertEqual(controller.decelerationTakeovers, 1)
        for _ in 0..<20 {
            collection.layoutIfNeeded()
            if controller.realizedTailArrival { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(controller.realizedTailArrival)
        controller.suspendPresentation()
        XCTAssertFalse(controller.explicitLatestOwnsViewport)
        XCTAssertFalse(controller.follows)
        XCTAssertEqual(controller.decelerationTakeovers, 1, "Counter remains latched after cancellation")
    }

    func testMountedNativeMotionObservationBatchingAB() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "A/B requires animated display-link motion")
        var records: [[String: Any]] = []
        var endpoints: [ChatNativeTranscriptViewport.Controller.Published] = []
        var tailFrames: [CGRect] = []
        var rates: [(publish: Double, scan: Double)] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: [
                "scope": "Native work inside accepted CADisplayLink ticks only; not FPS or whole-chat smoothness",
                "runs": records
            ], options: [.sortedKeys, .prettyPrinted]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "r45-native-motion-observation-ab"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        for batched in [false, true] {
            let (controller, fixture) = try mountNativeMotion(batchesMotionObservations: batched)
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(controller.realizedTailArrival)
            controller.latest.sendActions(for: .touchUpInside)
            for _ in 0..<150 {
                if controller.motionLink == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            let ticks = controller.motionTicks
            let publications = controller.motionPublishComputations
            let scans = controller.motionDescendantScanPasses
            let publishRate = Double(publications) / Double(max(1, ticks))
            let scanRate = Double(scans) / Double(max(1, ticks))
            let tailPath = try XCTUnwrap(controller.dataSource.indexPath(for: .footer))
            let tail = try XCTUnwrap(controller.collection.cellForItem(at: tailPath))
            let tailFrame = tail.convert(tail.bounds, to: controller.view)
            records.append([
                "batched": batched, "accepted_motion_ticks": ticks,
                "scroll_callbacks": controller.motionSamples,
                "publish_computations": publications, "descendant_scan_passes": scans,
                "publishes_per_tick": publishRate, "scans_per_tick": scanRate,
                "completed": controller.motionCompleted, "cancelled": controller.motionCancelled,
                "arrived": controller.realizedTailArrival,
                "offset_y": Double(controller.collection.contentOffset.y),
                "bottom_offset_y": Double(controller.bottomOffset),
                "content_height": Double(controller.collection.contentSize.height),
                "visible_tail_frame": [Double(tailFrame.minX), Double(tailFrame.minY),
                                       Double(tailFrame.width), Double(tailFrame.height)]
            ])
            XCTAssertGreaterThan(ticks, 0)
            XCTAssertGreaterThan(controller.motionSamples, 0)
            XCTAssertNil(controller.motionLink)
            XCTAssertEqual(controller.motionCompleted, 1)
            XCTAssertEqual(controller.motionCancelled, 0)
            XCTAssertTrue(controller.realizedTailArrival)
            XCTAssertTrue(controller.follows)
            XCTAssertFalse(controller.batchingMotionObservations)
            XCTAssertEqual(controller.collection.contentOffset.y, controller.bottomOffset, accuracy: 1)
            endpoints.append(try XCTUnwrap(controller.lastPublished))
            tailFrames.append(tailFrame)
            rates.append((publishRate, scanRate))
            if batched {
                XCTAssertEqual(publications, ticks)
                XCTAssertLessThanOrEqual(scans, ticks)
            }
        }
        // Same terminal state: identity fields exactly; geometry at sub-pixel
        // tolerance, since a settled bottom can differ by one ULP (~9e-13 pt).
        XCTAssertEqual(endpoints[0].visible, endpoints[1].visible)
        XCTAssertEqual(endpoints[0].last, endpoints[1].last)
        XCTAssertEqual(endpoints[0].bottom, endpoints[1].bottom)
        XCTAssertEqual(endpoints[0].metrics.distanceFromBottom, endpoints[1].metrics.distanceFromBottom,
                       accuracy: 0.001, "Both modes must publish the same terminal state")
        XCTAssertEqual(endpoints[0].metrics.isUserInteracting, endpoints[1].metrics.isUserInteracting)
        XCTAssertEqual(endpoints[0].metrics.isDirectlyInteracting, endpoints[1].metrics.isDirectlyInteracting)
        XCTAssertEqual(endpoints[0].metrics.isDecelerating, endpoints[1].metrics.isDecelerating)
        // Unrealized cells retain estimates, so absolute offsets can differ even
        // at the same realized footer. Compare the actual viewport-space target.
        XCTAssertEqual(tailFrames[0].minX, tailFrames[1].minX, accuracy: 1)
        XCTAssertEqual(tailFrames[0].minY, tailFrames[1].minY, accuracy: 1)
        XCTAssertEqual(tailFrames[0].width, tailFrames[1].width, accuracy: 1)
        XCTAssertEqual(tailFrames[0].height, tailFrames[1].height, accuracy: 1)
        XCTAssertLessThan(rates[1].publish, rates[0].publish * 0.75)
        // A tick may request only one sweep already. Do not demand an invented
        // percentage improvement; batching must cap it without adding idle work.
        XCTAssertLessThanOrEqual(rates[1].scan, 1)
    }

    func testMountedNativeMotionObservationBatchClearsOnEarlyExit() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Cancellation requires animated motion")
        for directGesture in [false, true] {
            var reduceMotion = false
            let (controller, fixture) = try mountNativeMotion(
                reduceMotionOverride: { reduceMotion }, makeCollection: {
                    ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0)
                })
            defer { controller.stop(); tearDown(fixture) }
            try await startMountedNativeMotion(controller)
            let link = try XCTUnwrap(controller.motionLink)
            let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
            if directGesture { collection.modeledTracking = true } else { reduceMotion = true }
            let ticks = controller.motionTicks
            let scans = controller.descendantScanPasses
            controller.advanceMotion(link)
            XCTAssertEqual(controller.motionTicks, ticks + 1)
            XCTAssertEqual(controller.descendantScanPasses, scans,
                           "Early exits without layout must not invent a subtree scan")
            XCTAssertNil(controller.motionLink)
            XCTAssertFalse(controller.batchingMotionObservations)
            XCTAssertEqual(controller.motionCancelled, 1)
            XCTAssertEqual(controller.follows, !directGesture)
            if directGesture { controller.scrollViewWillBeginDragging(collection) }
            // Ordinary publication must compute and update lastPublished synchronously.
            controller.lastPublished = nil
            let before = controller.publishComputations
            controller.publish()
            XCTAssertEqual(controller.publishComputations, before + 1)
            XCTAssertNotNil(controller.lastPublished)
            controller.suspendPresentation()
            let suspendedCount = controller.publishComputations
            controller.advanceMotion(link)
            controller.publish()
            XCTAssertEqual(controller.publishComputations, suspendedCount)
            XCTAssertFalse(controller.batchingMotionObservations)
        }
    }

    func testMountedNativeMotionObservationBatchRejectsInvalidatedLayout() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Invalidation requires animated motion")
        for stop in [false, true] {
            let (controller, fixture) = try mountNativeMotion()
            defer { controller.stop(); tearDown(fixture) }
            try await startMountedNativeMotion(controller)
            let link = try XCTUnwrap(controller.motionLink)
            let publications = controller.publishComputations
            let offset = controller.collection.contentOffset
            var invalidated = false
            controller.collection.didLayout = { [weak controller] in
                guard let controller, !invalidated else { return }
                invalidated = true
                XCTAssertTrue(controller.batchingMotionObservations)
                if stop { controller.stop() } else { controller.suspendPresentation() }
            }
            controller.collection.setNeedsLayout()
            controller.advanceMotion(link)
            XCTAssertTrue(invalidated)
            XCTAssertFalse(controller.batchingMotionObservations)
            XCTAssertNil(controller.motionLink)
            XCTAssertEqual(controller.publishComputations, publications,
                           "An invalidated synchronous transaction must not publish a stale frame")
            XCTAssertEqual(controller.collection.contentOffset.y, offset.y, accuracy: 1)
        }
    }

    // Injected synchronous UIKit bursts, not physical gestures or FPS evidence.
    func testMountedNativeScrollObservationCoalescingAB() async throws {
        var records: [[String: Any]] = []
        var endpoints: [ChatNativeTranscriptViewport.Controller.Published] = []
        var work: [Int] = []
        for coalesced in [false, true] {
            var delivered: [ChatNativeTranscriptViewport.Controller.Published] = []
            let (controller, fixture) = try mountNativeMotion(
                coalescesScrollObservations: coalesced,
                onState: { delivered.append(.init(metrics: $0, visible: $1, last: $2, bottom: $3)) },
                makeCollection: { ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0) })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(controller.initialized)
            controller.ownership = .reading
            (controller.collection as? ModeledMomentumCollection)?.modeledDragging = true
            let start = controller.collection.contentOffset
            let before = controller.publishComputations
            delivered.removeAll()
            for step in 1...24 {
                controller.collection.setContentOffset(CGPoint(x: start.x, y: start.y + CGFloat(step)), animated: false)
                controller.scrollViewDidScroll(controller.collection)
            }
            await drainNativeScrollQueue()
            let count = controller.publishComputations - before
            let final = try XCTUnwrap(controller.lastPublished)
            XCTAssertEqual(delivered.last, final)
            XCTAssertEqual(final.metrics.distanceFromBottom,
                           max(0, controller.bottomOffset - controller.collection.contentOffset.y), accuracy: 0.01)
            XCTAssertEqual(controller.collection.contentOffset.y - start.y, 24, accuracy: 0.01)
            endpoints.append(final)
            work.append(count)
            records.append(["coalesced": coalesced, "injectedCallbacks": 24,
                            "publishComputations": count,
                            "distanceFromBottom": final.metrics.distanceFromBottom,
                            "offsetDelta": controller.collection.contentOffset.y - start.y])
        }
        XCTAssertEqual(endpoints[0], endpoints[1])
        XCTAssertLessThan(work[1], work[0])
        let data = try JSONSerialization.data(withJSONObject: [
            "scope": "Mounted injected synchronous offset/callback burst; actual publication computations, not FPS or physical gestures",
            "runs": records
        ], options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "r46-native-scroll-observation-ab"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMountedNativeScrollObservationEagerPublicationSupersedesDrain() async throws {
        var delivered: [ChatNativeTranscriptViewport.Controller.Published] = []
        let (controller, fixture) = try mountNativeMotion(
            onState: { delivered.append(.init(metrics: $0, visible: $1, last: $2, bottom: $3)) },
            makeCollection: { ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0) })
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        controller.ownership = .reading
        (controller.collection as? ModeledMomentumCollection)?.modeledDragging = true
        delivered.removeAll()
        let start = controller.collection.contentOffset
        controller.collection.setContentOffset(CGPoint(x: start.x, y: start.y + 12), animated: false)
        controller.scrollViewDidScroll(controller.collection)
        (controller.collection as? ModeledMomentumCollection)?.modeledDragging = false
        controller.scrollViewDidEndDragging(controller.collection, willDecelerate: false)
        let eager = try XCTUnwrap(controller.lastPublished)
        // A fresh scroll queue followed by an identical eager publication must
        // preserve the valid onState delivery already waiting on the main queue.
        controller.scrollViewDidScroll(controller.collection)
        controller.publish()
        // UIKit may legitimately publish a layout during the barrier; distinguish
        // that from executing the superseded queued scroll observation.
        let beforeDrain = controller.scrollObservationDrains
        await drainNativeScrollQueue()
        XCTAssertEqual(controller.scrollObservationDrains, beforeDrain)
        XCTAssertEqual(delivered, [eager])
        delivered.removeAll()
        (controller.collection as? ModeledMomentumCollection)?.modeledDragging = true
        controller.collection.setContentOffset(CGPoint(x: start.x, y: start.y + 24), animated: false)
        controller.publish()
        // An older onState and an obsolete drain both precede this newer queue.
        // Neither may deliver stale geometry or consume the replacement ticket.
        controller.collection.setContentOffset(CGPoint(x: start.x, y: start.y + 36), animated: false)
        controller.scrollViewDidScroll(controller.collection)
        await drainNativeScrollQueue()
        let final = try XCTUnwrap(controller.lastPublished)
        XCTAssertEqual(controller.collection.contentOffset.y - start.y, 36, accuracy: 0.01)
        XCTAssertNotEqual(final, eager)
        XCTAssertEqual(delivered, [final])
        XCTAssertEqual(final.metrics.distanceFromBottom,
                       max(0, controller.bottomOffset - controller.collection.contentOffset.y), accuracy: 0.01)
    }

    func testMountedNativeScrollObservationInvalidationAndReopening() async throws {
        for boundary in ["suspend", "scope", "stop"] {
            var replacementDelivered: [ChatNativeTranscriptViewport.Controller.Published] = []
            var delivered: [ChatNativeTranscriptViewport.Controller.Published] = []
            let (controller, fixture) = try mountNativeMotion(
                onState: { delivered.append(.init(metrics: $0, visible: $1, last: $2, bottom: $3)) },
                makeCollection: { ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0) })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(100))
            delivered.removeAll()
            controller.scrollViewDidScroll(controller.collection)
            switch boundary {
            case "suspend": controller.suspendPresentation()
            case "scope":
                controller.update(nativeMotionInput(scope: "r46-replacement-\(UUID())", initialID: "native-row-1",
                    onState: { replacementDelivered.append(.init(metrics: $0, visible: $1, last: $2, bottom: $3)) }))
            default: controller.stop()
            }
            let beforeDrain = controller.publishComputations
            await drainNativeScrollQueue()
            XCTAssertTrue(delivered.isEmpty, boundary)
            if boundary != "scope" { XCTAssertEqual(controller.publishComputations, beforeDrain, boundary) }
            if boundary == "stop" { continue }
            if boundary == "suspend" { controller.resumePresentation() }
            try await Task.sleep(for: .milliseconds(100))
            controller.ownership = .reading
            (controller.collection as? ModeledMomentumCollection)?.modeledDragging = true
            let beforeNewQueue = controller.publishComputations
            let start = controller.collection.contentOffset
            controller.collection.setContentOffset(CGPoint(x: start.x, y: start.y + 16), animated: false)
            controller.scrollViewDidScroll(controller.collection)
            await drainNativeScrollQueue()
            XCTAssertGreaterThan(controller.publishComputations, beforeNewQueue, boundary)
            let final = try XCTUnwrap(controller.lastPublished)
            XCTAssertEqual(final.metrics.distanceFromBottom,
                           max(0, controller.bottomOffset - controller.collection.contentOffset.y), accuracy: 0.01)
            if boundary == "suspend" { XCTAssertEqual(delivered.last, final) }
            if boundary == "scope" { XCTAssertEqual(replacementDelivered.last, final) }
        }
    }

    private func drainNativeScrollQueue() async {
        // First barrier runs after the observation; second after its onState.
        for _ in 0..<2 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    /// Appearance is run-loop driven: main-queue hops do not fire viewDidAppear.
    /// Rejoin/explicit commands gate on an active presentation, so the fixture
    /// window must reach it before those assertions.
    private func awaitPresentationActive(_ controller: ChatNativeTranscriptViewport.Controller) async throws {
        for _ in 0..<40 {
            if controller.isPresentationActive { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Mounted fixture never became presentation-active")
    }

    // R48: real mounted offsets with synthetic footer growth and live display links.
    // These are movement/ownership samples, not presentation or FPS measurements.
    func testR48MountedStreamingFollowRetargetsAndCompletesAtRealTail() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: nil, reduceMotionOverride: { false })
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.realizedTailArrival)
        let start = controller.collection.contentOffset.y
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            revision: 1, active: true, footerHeight: 230))
        controller.collection.layoutIfNeeded()
        let link = try XCTUnwrap(controller.followLink)
        var samples: [String] = []
        var intermediate = false
        defer {
            let attachment = XCTAttachment(string: samples.joined(separator: "\n"))
            attachment.name = "R48 mounted live-link offsets; synthetic footer growth; not FPS"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for tick in 0..<12 {
            try await Task.sleep(for: .milliseconds(15))
            let offset = controller.collection.contentOffset.y
            let target = controller.bottomOffset
            samples.append("sample=\(tick) offset=\(offset) liveBottom=\(target) followTicks=\(controller.followTicks)")
            intermediate = intermediate || (offset > start + 0.5 && offset < target - 0.5)
            XCTAssertTrue(controller.latest.isHidden)
            if tick == 2 {
                controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
                    revision: 2, active: true, footerHeight: 330))
                controller.collection.layoutIfNeeded()
                XCTAssertTrue(controller.followLink === link, "Growth retargets the same link")
            }
        }
        XCTAssertTrue(intermediate, "Observe actual movement before arrival")
        XCTAssertGreaterThan(controller.followTicks, 0)
        for tick in 0..<40 {
            try await Task.sleep(for: .milliseconds(15))
            samples.append("settle=\(tick) offset=\(controller.collection.contentOffset.y) liveBottom=\(controller.bottomOffset) followTicks=\(controller.followTicks) link=\(controller.followLink != nil) arrived=\(controller.realizedTailArrival)")
        }
        XCTAssertNil(controller.followLink, "A settled active stream retains no display link")
        XCTAssertTrue(controller.realizedTailArrival)
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            revision: 3, active: true, footerHeight: 350))
        controller.collection.layoutIfNeeded()
        let finalLink = try XCTUnwrap(controller.followLink)
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            revision: 4, active: false, footerHeight: 370))
        controller.collection.layoutIfNeeded()
        XCTAssertTrue(controller.followLink === finalLink, "Completion lets the existing glide settle instead of snapping")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(controller.followLink)
        XCTAssertTrue(controller.realizedTailArrival)
        XCTAssertEqual(controller.motionSamples, 0)
        XCTAssertEqual(controller.motionCompleted, 0)
    }

    func testNativeMountedExplicitSendRejoinsWhileCancellingRestore() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-5", reduceMotion: true)
        defer { controller.stop(); tearDown(fixture) }
        try await awaitPresentationActive(controller)
        await drainNativeScrollQueue()
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1,
                                                  target: .message(id: "native-row-5"))
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
            restoreRequest: request))
        controller.collection.layoutIfNeeded()
        XCTAssertFalse(controller.follows)
        // Actual prepareTranscriptForExplicitSend input: clear restore, increment
        // cancellation AND rejoin, set following in the same update.
        let send = nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
            cancellationToken: 1, following: true, latestToken: 1)
        controller.update(send)
        controller.collection.layoutIfNeeded()
        await drainNativeScrollQueue()
        controller.collection.layoutIfNeeded()
        XCTAssertTrue(controller.follows)
        XCTAssertTrue(controller.realizedTailArrival)
        XCTAssertEqual(controller.collection.contentOffset.y, controller.bottomOffset, accuracy: 1)
        controller.scrollViewWillBeginDragging(controller.collection)
        XCTAssertTrue(controller.align(.init(id: "native-row-5", delta: 0)))
        controller.anchor = controller.currentAnchor()
        let parked = controller.collection.contentOffset.y
        for _ in 0..<3 {
            controller.update(send)
            controller.collection.layoutIfNeeded()
            XCTAssertFalse(controller.follows, "Repeated send input cannot reclaim a newer drag")
            XCTAssertNil(controller.followLink)
            XCTAssertEqual(controller.collection.contentOffset.y, parked, accuracy: 1)
        }
    }

    func testNativeMountedCancellationAndActiveFingerDoNotRejoin() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-5", reduceMotion: true,
            makeCollection: { ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0) })
        defer { controller.stop(); tearDown(fixture) }
        try await awaitPresentationActive(controller)
        await drainNativeScrollQueue()
        let parked = controller.collection.contentOffset.y
        let cancellation = nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
            cancellationToken: 1, following: true)
        for _ in 0..<3 {
            controller.update(cancellation)
            controller.collection.layoutIfNeeded()
            XCTAssertFalse(controller.follows, "Ordinary cancellation plus stale following is not send")
            XCTAssertEqual(controller.collection.contentOffset.y, parked, accuracy: 1)
        }
        let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
        collection.modeledTracking = true
        controller.scrollViewWillBeginDragging(collection)
        let send = nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
            cancellationToken: 2, following: true, latestToken: 1)
        controller.update(send)
        controller.collection.layoutIfNeeded()
        XCTAssertFalse(controller.follows)
        XCTAssertEqual(controller.collection.contentOffset.y, parked, accuracy: 1)
        collection.modeledTracking = false
        controller.update(send)
        controller.collection.layoutIfNeeded()
        XCTAssertFalse(controller.follows, "A command consumed during tracking cannot replay after finger release")
        XCTAssertNil(controller.motionLink)
        XCTAssertNil(controller.followLink)
        collection.modeledDeceleration = true
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
            cancellationToken: 3, following: true, latestToken: 2))
        controller.collection.layoutIfNeeded()
        XCTAssertFalse(collection.isDecelerating, "A fresh send may replace inherited momentum")
        XCTAssertTrue(controller.follows)
        XCTAssertTrue(controller.realizedTailArrival)
        controller.scrollViewDidEndDecelerating(collection)
        XCTAssertTrue(controller.follows, "Late momentum callbacks cannot reclaim the fresh send")
    }

    func testR48MountedStreamingDragSynchronouslyParksSubsequentGrowth() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: nil, reduceMotionOverride: { false })
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(150))
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            active: true, footerHeight: 250))
        controller.collection.layoutIfNeeded()
        XCTAssertNotNil(controller.followLink)
        // Modeled delegate interruption; the collection and display link are real.
        controller.scrollViewWillBeginDragging(controller.collection)
        XCTAssertNil(controller.followLink)
        XCTAssertFalse(controller.follows)
        let parked = try XCTUnwrap(controller.currentAnchor())
        let offset = controller.collection.contentOffset.y
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            active: true, footerHeight: 350))
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertNil(controller.followLink)
        XCTAssertFalse(controller.follows)
        XCTAssertEqual(controller.currentAnchor()?.id, parked.id)
        XCTAssertEqual(controller.collection.contentOffset.y, offset, accuracy: 1)
    }

    func testR48MountedStreamingLifecycleScopeAndStopReleaseFollow() async throws {
        for transition in ["suspend", "scope", "stop"] {
            let (controller, fixture) = try mountNativeMotion(initialID: nil, reduceMotionOverride: { false })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(150))
            controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
                active: true, footerHeight: 250))
            controller.collection.layoutIfNeeded()
            XCTAssertNotNil(controller.followLink)
            switch transition {
            case "suspend": controller.suspendPresentation()
            case "scope":
                controller.update(nativeMotionInput(scope: "r48-new-\(UUID().uuidString)",
                    initialID: "native-row-5", active: true))
            default: controller.stop()
            }
            XCTAssertNil(controller.followLink)
            let ticks = controller.followTicks
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertNil(controller.followLink)
            XCTAssertEqual(controller.followTicks, ticks, "Suspension/scope/stop must synchronously release hidden work")
            if transition == "suspend" {
                XCTAssertTrue(controller.follows, "Ordinary follow intent survives suspension")
                controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
                    revision: 1, active: true, footerHeight: 350))
                controller.collection.layoutIfNeeded()
                XCTAssertNil(controller.followLink)
                XCTAssertEqual(controller.followTicks, ticks)
                controller.resumePresentation()
                // The existing glide has a bounded 0.5s settlement deadline.
                try await Task.sleep(for: .milliseconds(700))
                XCTAssertTrue(controller.follows)
                XCTAssertNil(controller.followLink)
                XCTAssertTrue(controller.realizedTailArrival)
                XCTAssertEqual(controller.collection.contentOffset.y, controller.bottomOffset, accuracy: 1)
            } else {
                XCTAssertFalse(controller.follows && transition != "stop")
            }
        }
    }

    func testR48MountedInitialRestoreReduceMotionAndResizeStayImmediate() async throws {
        var reduce = false
        let (controller, fixture) = try mountNativeMotion(initialID: nil, reduceMotionOverride: { reduce })
        defer { controller.stop(); tearDown(fixture) }
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil, active: true))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.realizedTailArrival)
        XCTAssertEqual(controller.followTicks, 0)
        reduce = true
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            active: true, footerHeight: 230))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.followLink)
        XCTAssertTrue(controller.realizedTailArrival)
        reduce = false
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            active: true, footerHeight: 330))
        controller.collection.layoutIfNeeded()
        XCTAssertNotNil(controller.followLink)
        controller.collection.contentInset.bottom = 80
        controller.collection.setNeedsLayout()
        controller.collection.layoutIfNeeded()
        XCTAssertNil(controller.followLink)
        XCTAssertTrue(controller.realizedTailArrival)
        let resizeTicks = controller.followTicks
        // Model a late self-sizing correction in the same semantic revision.
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            active: true, footerHeight: 370))
        controller.collection.layoutIfNeeded()
        await drainNativeScrollQueue()
        controller.collection.layoutIfNeeded()
        XCTAssertNil(controller.followLink, "Inset-only resize must not restart on late layout refinement")
        XCTAssertEqual(controller.followTicks, resizeTicks)
        XCTAssertTrue(controller.realizedTailArrival)
        controller.collection.bounds.size.height -= 40
        controller.collection.setNeedsLayout()
        controller.collection.layoutIfNeeded()
        XCTAssertNil(controller.followLink)
        XCTAssertTrue(controller.realizedTailArrival)
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            revision: 1, active: true, footerHeight: 470))
        controller.collection.layoutIfNeeded()
        XCTAssertNotNil(controller.followLink, "A new semantic revision may glide again")
        controller.update(nativeMotionInput(scope: "r48-restore-\(UUID().uuidString)",
            initialID: "native-row-5", active: true))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(controller.followLink)
        XCTAssertFalse(controller.follows)
        XCTAssertEqual(controller.currentAnchor()?.id, "native-row-5")
    }

    func testR51MountedStreamingFollowObservationBatchingAB() async throws {
        var records: [[String: Any]] = []
        var frames: [CGRect] = []
        var rates: [Double] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: records, options: [.sortedKeys, .prettyPrinted]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "R51 live follow AB; synthetic growth, unmodified layout callbacks; not FPS"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        for batched in [false, true] {
            let (controller, fixture) = try mountNativeMotion(initialID: nil,
                batchesMotionObservations: batched, reduceMotionOverride: { false })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(150))
            XCTAssertTrue(controller.realizedTailArrival)
            let start = controller.collection.contentOffset.y
            let publicationsBefore = controller.publishComputations
            let scansBefore = controller.descendantScanPasses
            let initialTailPath = try XCTUnwrap(controller.dataSource.indexPath(for: .footer))
            let initialTailHeight = try XCTUnwrap(controller.collection.cellForItem(at: initialTailPath)).bounds.height
            var samples: [[String: Any]] = []
            var moved = false
            for sample in 0..<60 {
                if sample == 0 || sample == 6 || sample == 12 {
                    controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
                        revision: sample + 1, active: sample != 12,
                        footerHeight: CGFloat(230 + sample * 10)))
                    controller.collection.layoutIfNeeded()
                }
                try await Task.sleep(for: .milliseconds(15))
                let offset = controller.collection.contentOffset.y
                moved = moved || offset > start + 1
                samples.append(["sample": sample, "offset": Double(offset),
                    "bottom": Double(controller.bottomOffset), "ticks": controller.followTicks,
                    "steps": controller.followObservationSteps,
                    "step_publications": controller.followPublishComputations,
                    "step_scans": controller.followDescendantScanPasses])
            }
            let steps = controller.followObservationSteps
            let publications = controller.followPublishComputations
            let scans = controller.followDescendantScanPasses
            let tailPath = try XCTUnwrap(controller.dataSource.indexPath(for: .footer))
            let tail = try XCTUnwrap(controller.collection.cellForItem(at: tailPath))
            let frame = tail.convert(tail.bounds, to: controller.view)
            let rate = Double(publications) / Double(max(1, steps))
            records.append(["batched": batched, "steps": steps, "live_ticks": controller.followTicks,
                "initial_footer_height": Double(initialTailHeight), "requested_final_footer_height": 350,
                "step_publications": publications, "step_scans": scans,
                "all_publications": controller.publishComputations - publicationsBefore,
                "all_scans": controller.descendantScanPasses - scansBefore,
                "publications_per_step": rate,
                "scans_per_step": Double(scans) / Double(max(1, steps)),
                "offset": Double(controller.collection.contentOffset.y),
                "bottom": Double(controller.bottomOffset),
                "tail_viewport_frame": [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)],
                "samples": samples])
            XCTAssertTrue(moved)
            XCTAssertGreaterThan(controller.followTicks, 0)
            XCTAssertEqual(steps, controller.followTicks, "Uninterrupted callbacks must advance the live glide")
            XCTAssertNil(controller.followLink)
            XCTAssertTrue(controller.realizedTailArrival)
            XCTAssertTrue(controller.follows)
            XCTAssertFalse(controller.batchingMotionObservations)
            XCTAssertEqual(controller.collection.contentOffset.y, controller.bottomOffset, accuracy: 1)
            if batched {
                XCTAssertEqual(publications, steps)
                XCTAssertLessThanOrEqual(scans, steps)
            }
            // Compare requested content growth; the same scene-hosted footer also
            // includes UIKit safe-area sizing, so its cell is not the bare 350pt body.
            XCTAssertEqual(frame.height - initialTailHeight, 350 - 30, accuracy: 1,
                "The realized footer must include the final requested growth, not only the first update")
            frames.append(frame)
            rates.append(rate)
        }
        XCTAssertLessThan(rates[1], rates[0], "Compare actual computations per callback, not unequal raw tick totals")
        XCTAssertEqual(frames[0].minX, frames[1].minX, accuracy: 1)
        XCTAssertEqual(frames[0].minY, frames[1].minY, accuracy: 1)
        XCTAssertEqual(frames[0].width, frames[1].width, accuracy: 1)
        XCTAssertEqual(frames[0].height, frames[1].height, accuracy: 1)
    }

    func testR51MountedFollowBatchEarlyExitReleasesOrdinaryPublication() async throws {
        var records: [String] = []
        defer {
            let attachment = XCTAttachment(string: records.joined(separator: "\n"))
            attachment.name = "R51 modeled early exits; not physical gestures"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for gesture in [false, true] {
            var reduce = false
            let (controller, fixture) = try mountNativeMotion(initialID: nil,
                reduceMotionOverride: { reduce }, makeCollection: {
                    ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0)
                })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(150))
            controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
                active: true, footerHeight: 250))
            controller.collection.layoutIfNeeded()
            let link = try XCTUnwrap(controller.followLink)
            let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
            // Deliberately modeled tracking/Reduce Motion, not a physical gesture.
            if gesture { collection.modeledTracking = true } else { reduce = true }
            let steps = controller.followObservationSteps
            let scans = controller.descendantScanPasses
            controller.advanceFollow(link)
            XCTAssertNil(controller.followLink)
            XCTAssertFalse(controller.batchingMotionObservations)
            XCTAssertEqual(controller.followObservationSteps, steps)
            XCTAssertEqual(controller.descendantScanPasses, scans)
            controller.lastPublished = nil
            let before = controller.publishComputations
            controller.publish()
            XCTAssertEqual(controller.publishComputations, before + 1)
            XCTAssertNotNil(controller.lastPublished)
            records.append("modeledGesture=\(gesture) steps=\(steps) scans=\(scans) publicationsBeforeOrdinary=\(before) after=\(controller.publishComputations)")
        }
    }

    func testR51MountedFollowBatchRejectsReentrantInvalidation() async throws {
        var records: [String] = []
        defer {
            let attachment = XCTAttachment(string: records.joined(separator: "\n"))
            attachment.name = "R51 injected layout invalidations and raw work counters"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for transition in ["scope", "suspend", "stop", "gesture", "reduce"] {
            var reduce = false
            let (controller, fixture) = try mountNativeMotion(initialID: nil,
                reduceMotionOverride: { reduce })
            defer { controller.stop(); tearDown(fixture) }
            try await Task.sleep(for: .milliseconds(150))
            controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
                active: true, footerHeight: 250))
            controller.collection.layoutIfNeeded()
            let link = try XCTUnwrap(controller.followLink)
            let publications = controller.publishComputations
            let scans = controller.descendantScanPasses
            let followPublications = controller.followPublishComputations
            let followScans = controller.followDescendantScanPasses
            let steps = controller.followObservationSteps
            let originalLayout = controller.collection.didLayout
            var invalidated = false
            controller.collection.didLayout = { [weak controller] in
                guard let controller, !invalidated else { return }
                invalidated = true
                XCTAssertTrue(controller.batchingMotionObservations)
                // Inject nested observation requests before invalidating this frame.
                controller.publish()
                controller.disableNestedScrollToTop(in: controller.collection)
                switch transition {
                case "scope": controller.update(self.nativeMotionInput(scope: "r51-\(UUID().uuidString)", initialID: "native-row-5"))
                case "suspend": controller.suspendPresentation()
                case "stop": controller.stop()
                case "gesture": controller.scrollViewWillBeginDragging(controller.collection)
                default: reduce = true; controller.advanceFollow(link)
                }
            }
            controller.collection.setNeedsLayout()
            controller.advanceFollow(link)
            XCTAssertTrue(invalidated)
            XCTAssertFalse(controller.batchingMotionObservations)
            XCTAssertNil(controller.followLink)
            XCTAssertEqual(controller.followObservationSteps, steps + 1)
            let expectedWork = transition == "reduce" ? 1 : 0
            XCTAssertEqual(controller.publishComputations - publications, expectedWork)
            XCTAssertEqual(controller.descendantScanPasses - scans, expectedWork)
            XCTAssertEqual(controller.followPublishComputations - followPublications, expectedWork)
            XCTAssertEqual(controller.followDescendantScanPasses - followScans, expectedWork)
            records.append("transition=\(transition) steps=\(controller.followObservationSteps - steps) publications=\(controller.publishComputations - publications) scans=\(controller.descendantScanPasses - scans)")
            if transition != "stop" {
                controller.collection.didLayout = originalLayout
                if transition == "suspend" { controller.resumePresentation() }
                controller.lastPublished = nil
                let before = controller.publishComputations
                controller.publish()
                XCTAssertEqual(controller.publishComputations, before + 1)
                XCTAssertNotNil(controller.lastPublished)
            }
        }
    }

    func testR50NativeMemoryChurnRetains32RecentPoints() throws {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        let previous = Controller.memory
        Controller.memory.removeAll()
        defer { Controller.memory = previous }
        var oldPolicy: [String: Controller.Memory] = [:]
        for index in 0..<34 {
            let point = Controller.Memory(anchor: .init(id: "row-\(index)", delta: 37), following: false)
            if oldPolicy.count > 32 { oldPolicy.removeAll() }
            oldPolicy["key-\(index)"] = point
            Controller.memory["key-\(index)"] = point
            XCTAssertLessThanOrEqual(Controller.memory.count, 32)
        }
        XCTAssertEqual(oldPolicy.count, 1)
        XCTAssertNil(oldPolicy["key-32"])
        XCTAssertEqual(Controller.memory.count, 32)
        XCTAssertNil(Controller.memory["key-0"])
        XCTAssertNil(Controller.memory["key-1"])
        XCTAssertEqual(try XCTUnwrap(Controller.memory["key-32"]).anchor.delta, 37)
        let evidence = XCTAttachment(string: "34 distinct saves: old policy retains 1; LRU retains 32; recent key-32 delta 37 survives only LRU. Bounded state comparison, not RSS/FPS.")
        evidence.name = "R50 bounded cache policy comparison"
        evidence.lifetime = .keepAlways
        add(evidence)
    }

    func testR50NativeMemoryAccessOverwriteMissAndRemovalRecency() throws {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        let previous = Controller.memory
        Controller.memory.removeAll()
        defer { Controller.memory = previous }
        let point = Controller.Memory(anchor: .init(id: "row", delta: 21), following: false)
        for index in 0..<32 { Controller.memory["key-\(index)"] = point }
        XCTAssertNotNil(Controller.memory["key-0"])
        Controller.memory["key-1"] = .init(anchor: .init(id: "updated", delta: 42), following: true)
        XCTAssertNil(Controller.memory["absent"])
        Controller.memory["key-32"] = point
        Controller.memory["key-33"] = point
        XCTAssertNil(Controller.memory["key-2"])
        XCTAssertNil(Controller.memory["key-3"])
        XCTAssertNotNil(Controller.memory["key-0"])
        let overwritten = try XCTUnwrap(Controller.memory["key-1"])
        XCTAssertEqual(overwritten.anchor.id, "updated")
        XCTAssertEqual(overwritten.anchor.delta, 42)
        XCTAssertTrue(overwritten.following)
        Controller.memory["key-0"] = nil
        Controller.memory["absent"] = nil
        XCTAssertEqual(Controller.memory.count, 31)
        Controller.memory["replacement"] = point
        Controller.memory["overflow"] = point
        XCTAssertNil(Controller.memory["key-4"])
        Controller.memory.removeAll()
        XCTAssertEqual(Controller.memory.count, 0)
        Controller.memory["fresh"] = point
        XCTAssertEqual(Controller.memory.count, 1)
        XCTAssertNotNil(Controller.memory["fresh"])
    }

    func testR50NativeMemoryKeyIsolationAndExplicitTargetPrecedence() async throws {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        let previous = Controller.memory
        Controller.memory.removeAll()
        defer { Controller.memory = previous }
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-5")
        defer { controller.stop(); tearDown(fixture) }
        try await Task.sleep(for: .milliseconds(100))
        controller.ownership = .reading
        XCTAssertTrue(controller.align(.init(id: "native-row-5", delta: 37)))
        controller.saveMemory(scope: controller.input.scope)
        let key = controller.memoryKey
        let saved = try XCTUnwrap(Controller.memory[key])
        XCTAssertEqual(saved.anchor.delta, 37, accuracy: 1)
        func assertRow(_ ownership: Controller.Ownership, id: String, delta: CGFloat) {
            guard case .restoring(let anchor) = ownership, let anchor else {
                return XCTFail("Expected a row restore")
            }
            XCTAssertEqual(anchor.id, id)
            XCTAssertEqual(anchor.delta, delta, accuracy: 1)
        }
        assertRow(controller.requestedOwnership(controller.input), id: "native-row-5", delta: 37)
        assertRow(controller.requestedOwnership(nativeMotionInput(scope: controller.input.scope + "-other",
            initialID: "native-row-5")), id: "native-row-5", delta: 0)
        Controller.memory[key] = nil
        let width = Int(controller.collection.bounds.width.rounded())
        Controller.memory["\(controller.input.scope)|\(width + 1)|\(controller.input.typeKey)"] = saved
        Controller.memory["\(controller.input.scope)|\(width)|other-type"] = saved
        assertRow(controller.requestedOwnership(controller.input), id: "native-row-5", delta: 0)
        Controller.memory[key] = saved
        assertRow(controller.requestedOwnership(nativeMotionInput(scope: controller.input.scope,
            initialID: "native-row-7")), id: "native-row-7", delta: 0)
        let request = ChatTranscriptRestoreRequest(scope: UUID(), generation: 1, target: .message(id: "native-row-8"))
        assertRow(controller.requestedOwnership(nativeMotionInput(scope: controller.input.scope,
            initialID: "native-row-5", restoreRequest: request)), id: "native-row-8", delta: 0)
        for input in [
            nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5", explicitLatest: true),
            nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
                restoreRequest: .init(scope: UUID(), generation: 2, target: .latest))
        ] {
            guard case .following = controller.requestedOwnership(input) else {
                XCTFail("Explicit latest must win over the saved reader point")
                continue
            }
        }
    }

    func testR50MountedNativeRecentReaderSurvivesPressureAndReopen() async throws {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        let previous = Controller.memory
        Controller.memory.removeAll()
        defer { Controller.memory = previous }
        let scope = "r50-reader-\(UUID().uuidString)"
        let (controller, fixture) = try mountNativeMotion(scope: scope, initialID: "native-row-5")
        var originalMounted = true
        defer { if originalMounted { controller.stop(); tearDown(fixture) } }
        try await Task.sleep(for: .milliseconds(100))
        controller.ownership = .reading
        XCTAssertTrue(controller.align(.init(id: "native-row-5", delta: 37)))
        controller.saveMemory(scope: scope)
        let saved = try XCTUnwrap(controller.currentAnchor())
        XCTAssertEqual(saved.id, "native-row-5")
        XCTAssertEqual(saved.delta, 37, accuracy: 1)
        let source = Array(try XCTUnwrap(controller.input.revisionAt(5).message.message.content).utf8)
        for index in 0..<31 { controller.saveMemory(scope: "\(scope)-pressure-\(index)") }
        guard case .restoring(let touched) = controller.requestedOwnership(controller.input) else {
            return XCTFail("Saved reader must be reusable before pressure")
        }
        XCTAssertEqual(try XCTUnwrap(touched).delta, saved.delta, accuracy: 1)
        for index in 31..<34 { controller.saveMemory(scope: "\(scope)-pressure-\(index)") }
        XCTAssertEqual(Controller.memory.count, 32)
        XCTAssertEqual(try XCTUnwrap(Controller.memory[controller.memoryKey]).anchor.delta, saved.delta, accuracy: 1)
        controller.stop()
        tearDown(fixture)
        originalMounted = false
        let (reopened, reopenedFixture) = try mountNativeMotion(scope: scope, initialID: saved.id)
        defer { reopened.stop(); tearDown(reopenedFixture) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(reopened.memoryKey, controller.memoryKey)
        let restored = try XCTUnwrap(reopened.currentAnchor())
        XCTAssertEqual(restored.id, saved.id)
        XCTAssertEqual(restored.delta, saved.delta, accuracy: 1)
        XCTAssertEqual(Array(try XCTUnwrap(reopened.input.revisionAt(5).message.message.content).utf8), source)
        XCTAssertFalse(reopened.follows)
        XCTAssertNil(reopened.motionLink)
        XCTAssertNil(reopened.followLink)
        let offset = reopened.collection.contentOffset.y
        reopened.collection.setNeedsLayout()
        try await Task.sleep(for: .milliseconds(1050))
        XCTAssertEqual(reopened.collection.contentOffset.y, offset, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(reopened.currentAnchor()).delta, saved.delta, accuracy: 1)
        XCTAssertNil(reopened.motionLink)
        XCTAssertNil(reopened.followLink)
        XCTAssertEqual(reopened.motionSamples, 0)
        XCTAssertEqual(reopened.followTicks, 0)
    }

    private func startMountedNativeMotion(_ controller: ChatNativeTranscriptViewport.Controller) async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "Animated lifecycle gate requires system Reduce Motion off")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(controller.view.window)
        XCTAssertTrue(controller.initialized)
        XCTAssertFalse(controller.realizedTailArrival)
        let offset = controller.collection.contentOffset.y
        controller.latest.sendActions(for: .touchUpInside)
        for _ in 0..<20 {
            if controller.motionSamples > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(controller.motionLink, "Cancellation must interrupt an actual live CADisplayLink")
        XCTAssertGreaterThan(controller.motionSamples, 0)
        XCTAssertGreaterThan(controller.collection.contentOffset.y, offset)
    }

    private func assertNativeReaderRemains(_ controller: ChatNativeTranscriptViewport.Controller,
                                          id: String, delta: CGFloat, offset: CGFloat,
                                          completed: Int) async throws {
        // Longer than the production 0.9s expiry: an expired link cannot resume
        // and silently settle at latest on a subsequent layout or parent update.
        let echoToken = try XCTUnwrap(controller.latestEchoCancellationToken)
        controller.update(nativeMotionInput(scope: controller.input.scope,
            initialID: try XCTUnwrap(controller.input.initialID),
            cancellationToken: echoToken, following: true))
        XCTAssertNil(controller.latestEchoCancellationToken)
        controller.collection.setNeedsLayout()
        try await Task.sleep(for: .milliseconds(1050))
        let current = try XCTUnwrap(controller.currentAnchor())
        XCTAssertEqual(current.id, id)
        XCTAssertEqual(current.delta, delta, accuracy: 1)
        XCTAssertEqual(controller.collection.contentOffset.y, offset, accuracy: 1)
        XCTAssertNil(controller.motionLink)
        XCTAssertFalse(controller.follows)
        XCTAssertFalse(controller.realizedTailArrival)
        XCTAssertEqual(controller.motionCompleted, completed)
        // Consuming the stale echo must not permanently disable the next explicit tap.
        controller.latest.sendActions(for: .touchUpInside)
        XCTAssertNotNil(controller.motionLink)
        controller.cancelMotion()
    }

    func testR65MountedWarmEstimatesRemainCorrectableByUIKit() async throws {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        let scope = "r65-warm-\(UUID())"
        let (first, fixture) = try mountNativeMotion(scope: scope, initialID: nil, ids: [])
        await drainNativeScrollQueue()
        first.collection.layoutIfNeeded()
        let layout = try XCTUnwrap(first.collection.collectionViewLayout as? Controller.ColumnLayout)
        XCTAssertTrue(layout.measured.contains(.footer))
        let key = Controller.EstimateKey(scope: scope, width: first.collection.bounds.width,
                                        type: first.input.typeKey, padding: first.input.horizontalPadding)
        first.stop(); tearDown(fixture)
        // Deliberately poison the scalar hint. The mounted factory still owns 30pt.
        Controller.estimates.put(900, item: .footer, key: key)
        let (second, secondFixture) = try mountNativeMotion(scope: scope, initialID: nil, ids: [])
        defer { second.stop(); tearDown(secondFixture) }
        await drainNativeScrollQueue()
        second.collection.layoutIfNeeded()
        let warm = try XCTUnwrap(second.collection.collectionViewLayout as? Controller.ColumnLayout)
        XCTAssertGreaterThan(warm.warmHits, 0)
        XCTAssertTrue(warm.measured.contains(.footer))
        XCTAssertEqual(try nativeBoundaryFrames(second)[1].height, 30, accuracy: 1)
    }

    func testR65PreparedRowDisplayRefreshesHostAndFittingReceipt() async throws {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-6")
        defer { controller.stop(); tearDown(fixture) }
        await drainNativeScrollQueue()
        let item = Controller.Item.row("native-row-6")
        let path = try XCTUnwrap(controller.dataSource.indexPath(for: item))
        // A real scene-attached host outside the collection's visible set models
        // UIKit's retained prepared-cell callback; it is not a physical-scroll test.
        let prepared = Controller.Cell(frame: CGRect(x: 0, y: 10_000, width: 378, height: 160))
        controller.view.addSubview(prepared)
        defer { prepared.removeFromSuperview() }
        controller.configure(prepared, item: item)
        let stale = try XCTUnwrap(prepared.rowStamp)
        let text = String(repeating: "Prepared rows must refresh their complete content.\n", count: 60)
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-6",
            revision: 1, liveText: text, typeKey: "changed-type", horizontalPadding: 70))
        await drainNativeScrollQueue()
        XCTAssertEqual(prepared.rowStamp, stale, "The hidden host must reach the delegate with stale inputs")
        let expected = try XCTUnwrap(controller.rowStamp(for: "native-row-6"))
        XCTAssertNotEqual(stale, expected)
        controller.collectionView(controller.collection, willDisplay: prepared, forItemAt: path)
        XCTAssertEqual(prepared.rowStamp, expected)
        let layout = try XCTUnwrap(controller.collection.collectionViewLayout as? Controller.ColumnLayout)
        layout.needsFit(item)
        XCTAssertFalse(layout.measured.contains(item))
        let original = try XCTUnwrap(layout.layoutAttributesForItem(at: path))
        let fitted = prepared.preferredLayoutAttributesFitting(original)
        XCTAssertTrue(layout.measured.contains(item), "Fresh callback must accept the new exact key")
        XCTAssertEqual(fitted.size.width, controller.collection.bounds.width - 140, accuracy: 0.01)
        XCTAssertGreaterThan(fitted.size.height, 1_000, "Full multiline source must be laid out, not its stale estimate")
    }

    func testR65EstimateStoreBoundsAndExactWidthIsolation() {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        var store = Controller.EstimateStore()
        for scope in 0...Controller.EstimateStore.scopeLimit {
            let key = Controller.EstimateKey(scope: "scope-\(scope)", width: 390.25, type: "large", padding: 12)
            for row in 0...Controller.EstimateStore.rowLimit {
                store.put(CGFloat(row), item: .row("\(row)"), key: key)
            }
        }
        XCTAssertEqual(store.values.count, Controller.EstimateStore.scopeLimit)
        XCTAssertTrue(store.values.values.allSatisfy { $0.count == Controller.EstimateStore.rowLimit })
        let otherWidth = Controller.EstimateKey(scope: "scope-16", width: 390.5, type: "large", padding: 12)
        XCTAssertTrue(store.heights(for: otherWidth).isEmpty)
        let otherType = Controller.EstimateKey(scope: "scope-16", width: 390.25, type: "small", padding: 12)
        XCTAssertTrue(store.heights(for: otherType).isEmpty)
    }

    func testR65MountedWidthAndDynamicContentRefit() async throws {
        typealias Controller = ChatNativeTranscriptViewport.Controller
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-5")
        defer { controller.stop(); tearDown(fixture) }
        await drainNativeScrollQueue()
        let before = controller.collection.bounds.width
        controller.view.frame.size.width -= 40
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
            revision: 1, liveText: String(repeating: "New multiline content grows.\n", count: 100),
            typeKey: "r65-new-type"))
        await drainNativeScrollQueue()
        controller.collection.layoutIfNeeded()
        XCTAssertEqual(controller.collection.bounds.width, before - 40, accuracy: 1)
        let path = try XCTUnwrap(controller.dataSource.indexPath(for: .row("native-row-6")))
        _ = controller.align(.init(id: "native-row-6", delta: 0))
        controller.collection.layoutIfNeeded()
        await drainNativeScrollQueue()
        let frame = try XCTUnwrap(controller.collection.layoutAttributesForItem(at: path)?.frame)
        let cell = try XCTUnwrap(controller.collection.cellForItem(at: path))
        XCTAssertGreaterThan(frame.height, 1_000, "The 100-line body must not remain at the 160pt estimate")
        XCTAssertEqual(cell.frame.height, frame.height, accuracy: 1)
        XCTAssertEqual(cell.contentView.bounds.height, frame.height, accuracy: 1)
        XCTAssertEqual(frame.width, controller.collection.bounds.width - 24, accuracy: 0.01)
        let layout = try XCTUnwrap(controller.collection.collectionViewLayout as? Controller.ColumnLayout)
        XCTAssertTrue(layout.measured.contains(.row("native-row-6")))
        let priorHeight = frame.height
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-6",
            revision: 1, liveText: String(repeating: "New multiline content grows.\n", count: 100),
            typeKey: "r65-new-type", horizontalPadding: 100))
        await drainNativeScrollQueue()
        controller.collection.layoutIfNeeded()
        let padded = try XCTUnwrap(controller.collection.layoutAttributesForItem(at: path))
        let fitted = cell.preferredLayoutAttributesFitting(padded)
        XCTAssertEqual(padded.size.width, controller.collection.bounds.width - 200, accuracy: 0.01)
        XCTAssertEqual(fitted.size.height, padded.size.height, accuracy: 1,
                       "Mounted hosted content and layout must agree after a padding-only change")
        XCTAssertGreaterThan(padded.size.height, priorHeight, "Narrower wrapping must grow the real multiline body")
    }

    func testNativeOrdinaryFollowingSurvivesSuspendedGrowth() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: nil, reduceMotion: true)
        defer { controller.stop(); tearDown(fixture) }
        try await awaitPresentationActive(controller)
        await drainNativeScrollQueue()
        XCTAssertTrue(controller.follows)
        XCTAssertFalse(controller.explicitLatestOwnsViewport)
        controller.applicationActive = false
        controller.suspendPresentation()
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: nil,
            revision: 1, footerHeight: 500, following: true))
        XCTAssertTrue(controller.follows, "Suspension must retain ordinary follow intent")
        controller.applicationActive = true
        controller.resumePresentation()
        await drainNativeScrollQueue()
        controller.collection.layoutIfNeeded()
        XCTAssertTrue(controller.follows)
        XCTAssertTrue(controller.realizedTailArrival)
        XCTAssertEqual(controller.collection.contentOffset.y, controller.bottomOffset, accuracy: 1)
    }

    func testNativeOrdinaryRejoinAndSendSurviveSuspendedGrowthAfterMomentumHandoff() async throws {
        for cancellationToken in [0, 1] {
            let (controller, fixture) = try mountNativeMotion(initialID: "native-row-5", reduceMotion: true,
                makeCollection: { ModeledMomentumCollection(frame: .zero, collectionViewLayout: $0) })
            defer { controller.stop(); tearDown(fixture) }
            try await awaitPresentationActive(controller)
            await drainNativeScrollQueue()
            let collection = try XCTUnwrap(controller.collection as? ModeledMomentumCollection)
            XCTAssertFalse(controller.follows)
            XCTAssertFalse(controller.realizedTailArrival)
            let parked = collection.contentOffset
            var synchronousEnds = 0
            collection.onMomentumStopped = { [weak controller, weak collection] in
                guard let controller, let collection else { return }
                synchronousEnds += 1
                // Callback before geometry reaches the tail must not turn rejoin
                // into reading, even though native deceleration has ended.
                XCTAssertFalse(controller.realizedTailArrival)
                controller.scrollViewDidEndDragging(collection, willDecelerate: false)
                controller.scrollViewDidEndDecelerating(collection)
                XCTAssertTrue(controller.follows)
                XCTAssertFalse(controller.explicitLatestOwnsViewport)
            }
            collection.modeledDeceleration = true
            controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
                cancellationToken: cancellationToken, following: true, latestToken: 1))
            XCTAssertEqual(synchronousEnds, 1)
            XCTAssertEqual(collection.stoppedMomentumAt, parked)
            XCTAssertEqual(controller.decelerationTakeovers, 1)
            collection.onMomentumStopped = nil
            // The stop callback can also arrive after update, before tail layout.
            XCTAssertFalse(controller.realizedTailArrival)
            controller.scrollViewDidEndDecelerating(collection)
            XCTAssertTrue(controller.follows)
            collection.layoutIfNeeded()
            await drainNativeScrollQueue()
            collection.layoutIfNeeded()
            XCTAssertTrue(controller.follows)
            XCTAssertTrue(controller.realizedTailArrival)
            XCTAssertFalse(controller.explicitLatestOwnsViewport)
            controller.scrollViewDidEndDecelerating(collection)
            XCTAssertTrue(controller.follows)

            controller.applicationActive = false
            controller.suspendPresentation()
            let hiddenOffset = collection.contentOffset.y
            controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5",
                revision: 1, footerHeight: 500, cancellationToken: cancellationToken,
                following: true, latestToken: 1))
            collection.layoutIfNeeded()
            await drainNativeScrollQueue()
            XCTAssertTrue(controller.follows, "Consumed ordinary rejoin/send intent survives suspension")
            XCTAssertEqual(collection.contentOffset.y, hiddenOffset, accuracy: 1)
            controller.applicationActive = true
            controller.resumePresentation()
            await drainNativeScrollQueue()
            collection.layoutIfNeeded()
            XCTAssertTrue(controller.follows)
            XCTAssertTrue(controller.realizedTailArrival)
            XCTAssertEqual(collection.contentOffset.y, controller.bottomOffset, accuracy: 1)
        }
    }

    func testMeasuredProductionHistoryCrossingKeepsReaderIDAndRowRelativeY() async throws {
        let scope = "https://example.invalid|profile-production|history-\(UUID())"
        let original = (0..<59).map { "history-id-\($0)" }
        let target = original[20]
        let (controller, fixture) = try mountNativeMotion(scope: scope, initialID: target, ids: original)
        defer { controller.stop(); tearDown(fixture) }
        await drainNativeScrollQueue()
        controller.collection.layoutIfNeeded()
        let saved = try XCTUnwrap(controller.currentAnchor())
        XCTAssertEqual(saved.id, target)
        let nextSources = [original + (59..<140).map { "history-id-\($0)" },
                           ["older-a", "older-b"] + original + (59..<140).map { "history-id-\($0)" },
                           ["older-b"] + original + ["history-id-139"]]
        for (index, ids) in nextSources.enumerated() {
            controller.update(nativeMotionInput(scope: scope, initialID: target, ids: ids, revision: index + 1))
            controller.collection.layoutIfNeeded()
            await drainNativeScrollQueue()
            let reader = try XCTUnwrap(controller.currentAnchor())
            XCTAssertEqual(reader.id, saved.id)
            XCTAssertEqual(reader.delta, saved.delta, accuracy: 1)
            XCTAssertEqual(controller.lastSourceMutation, [.append, .prepend, .reconcile][index])
            XCTAssertLessThan(controller.collection.visibleCells.count, 20,
                              "History crossing must not create a full-source rich host")
            XCTAssertFalse(controller.realizedTailArrival, "Parked source growth must not follow the tail")
            let cell = try XCTUnwrap(controller.collection.cellForItem(at: try XCTUnwrap(controller.dataSource.indexPath(for: .row(target)))),
                                     "The actual visible reader cell must survive each source handoff")
            XCTAssertNotNil(cell.contentConfiguration, "A surviving ID with a discarded host is a blank frame")
            XCTAssertGreaterThan(cell.bounds.height, 0)
            XCTAssertTrue(cell.frame.intersects(controller.collection.bounds), "The reader must occupy the presented viewport")
        }
    }

    func testMeasuredHandoffRejectsNewTouchCancellationWidthAndSource() async throws {
        let modeled = ModeledMomentumCollection(frame: .zero, collectionViewLayout: UICollectionViewFlowLayout())
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-10", makeCollection: { layout in
            modeled.setCollectionViewLayout(layout, animated: false)
            return modeled
        })
        defer { controller.stop(); tearDown(fixture) }
        await drainNativeScrollQueue()
        let reader = try XCTUnwrap(controller.currentAnchor())
        let offset = controller.collection.contentOffset
        let sample = ChatNativeTranscriptViewport.Controller.ReaderHandoff(anchor: .init(id: "native-row-20", delta: reader.delta),
            scope: controller.input.scope, width: controller.collection.bounds.width,
            revision: controller.input.revision, cancellation: controller.input.cancellationToken,
            generation: controller.generation, presentation: controller.presentationEpoch)
        modeled.modeledTracking = true
        controller.commitReaderHandoff(sample)
        XCTAssertEqual(controller.collection.contentOffset, offset)
        modeled.modeledTracking = false
        let wrongWidth = ChatNativeTranscriptViewport.Controller.ReaderHandoff(anchor: sample.anchor,
            scope: sample.scope, width: sample.width + 1, revision: sample.revision,
            cancellation: sample.cancellation, generation: sample.generation, presentation: sample.presentation)
        controller.commitReaderHandoff(wrongWidth)
        XCTAssertEqual(controller.collection.contentOffset, offset)
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: reader.id, cancellationToken: 1))
        let cancelledOffset = controller.collection.contentOffset
        controller.commitReaderHandoff(sample)
        XCTAssertEqual(controller.collection.contentOffset, cancelledOffset)
        controller.update(nativeMotionInput(scope: "replacement-production-scope", initialID: "native-row-5"))
        let replacedOffset = controller.collection.contentOffset
        controller.commitReaderHandoff(sample)
        XCTAssertEqual(controller.collection.contentOffset, replacedOffset)
        XCTAssertNil(controller.motionLink)
    }

    func testMeasuredViewportBackFlushIsFreshAndSuspendsMotionBeforeReturn() async throws {
        var lastID: String?
        let publication = ChatScrollMetricPublication()
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-10", onState: { _, id, _, _ in lastID = id })
        defer { controller.stop(); tearDown(fixture) }
        try await awaitPresentationActive(controller)
        await drainNativeScrollQueue()
        var input = controller.input
        input.metricPublication = publication
        controller.update(input)
        controller.collection.setContentOffset(CGPoint(x: 0, y: controller.collection.contentOffset.y + 180), animated: false)
        controller.collection.layoutIfNeeded()
        let expected = try XCTUnwrap(controller.currentAnchor()).id
        lastID = nil
        publication.flush()
        XCTAssertEqual(lastID, expected, "Back must synchronously drain the current source ID without waiting for the queue")
        controller.latest.sendActions(for: .touchUpInside)
        XCTAssertNotNil(controller.motionLink)
        publication.suspend()
        XCTAssertNil(controller.motionLink, "The delivered Back boundary must cancel motion before returning")
        XCTAssertTrue(controller.presentationSuspended)
        await drainNativeScrollQueue()
        XCTAssertNil(controller.motionLink)
    }

    func testMeasuredLayoutBoundsMeasurementsAndRejectsRemovedSourceReceipt() async throws {
        typealias Owner = ChatNativeTranscriptViewport.Controller
        let ids = (0..<2300).map { "bounded-production-id-\($0)" }
        let (controller, fixture) = try mountNativeMotion(initialID: ids[20], ids: ids)
        defer { controller.stop(); tearDown(fixture) }
        await drainNativeScrollQueue()
        let layout = try XCTUnwrap(controller.collection.collectionViewLayout as? Owner.ColumnLayout)
        let key = try XCTUnwrap(layout.key)
        for index in ids.indices {
            let attributes = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: index + 1, section: 0))
            attributes.frame = CGRect(x: key.padding, y: CGFloat(index * 160), width: key.width - 2 * key.padding, height: 140)
            layout.didFit(attributes, item: .row(ids[index]), key: key)
        }
        XCTAssertLessThanOrEqual(layout.retainedMeasurementCount, Owner.EstimateStore.rowLimit)
        XCTAssertLessThanOrEqual(layout.measured.count, Owner.EstimateStore.rowLimit)
        let removed = UICollectionViewLayoutAttributes(forCellWith: IndexPath(item: 21, section: 0))
        removed.frame = CGRect(x: key.padding, y: 0, width: key.width - 2 * key.padding, height: 999)
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "replacement", ids: ["replacement"]))
        layout.didFit(removed, item: .row(ids[20]), key: key)
        XCTAssertFalse(layout.measured.contains(.row(ids[20])), "An old index must not measure a replacement ID")
        XCTAssertEqual(controller.lastSourceMutation, .replacement)
        XCTAssertEqual(controller.input.ids, ["replacement"])
    }

    func testMeasuredWarmMountRetainsSavedIDAndIntraRowOffsetWithoutTailReplacement() async throws {
        let scope = "production-warm-\(UUID())"
        let id = "native-row-12"
        let (first, firstFixture) = try mountNativeMotion(scope: scope, initialID: id)
        await drainNativeScrollQueue()
        first.ownership = .reading
        first.anchor = .init(id: id, delta: 37)
        _ = first.align(try XCTUnwrap(first.anchor))
        first.collection.layoutIfNeeded()
        let before = try XCTUnwrap(first.currentAnchor())
        XCTAssertEqual(before.id, id)
        first.saveMemory(scope: scope)
        first.stop(); tearDown(firstFixture)
        let (second, secondFixture) = try mountNativeMotion(scope: scope, initialID: id)
        defer { second.stop(); tearDown(secondFixture) }
        // Judge the first layout returned by mounting, before any queue drain.
        let after = try XCTUnwrap(second.currentAnchor())
        XCTAssertEqual(after.id, id)
        XCTAssertEqual(after.delta, before.delta, accuracy: 1)
        let cell = try XCTUnwrap(second.collection.cellForItem(at: try XCTUnwrap(second.dataSource.indexPath(for: .row(id)))))
        XCTAssertNotNil(cell.contentConfiguration)
        XCTAssertTrue(cell.frame.intersects(second.collection.bounds))
        XCTAssertFalse(second.realizedTailArrival)
    }

    func testMeasuredRetiredContentFitCannotMutateCurrentRowGeometry() async throws {
        let (controller, fixture) = try mountNativeMotion(initialID: "native-row-5")
        defer { controller.stop(); tearDown(fixture) }
        await drainNativeScrollQueue()
        let path = try XCTUnwrap(controller.dataSource.indexPath(for: .row("native-row-6")))
        let cell = try XCTUnwrap(controller.collection.cellForItem(at: path) as? ChatNativeTranscriptViewport.Controller.Cell)
        let staleFit = try XCTUnwrap(cell.didFit)
        controller.update(nativeMotionInput(scope: controller.input.scope, initialID: "native-row-5", revision: 1, liveText: "new canonical content"))
        controller.collection.layoutIfNeeded()
        let before = try XCTUnwrap(controller.collection.layoutAttributesForItem(at: path)).frame
        let oldAttributes = UICollectionViewLayoutAttributes(forCellWith: path)
        oldAttributes.frame = CGRect(x: before.minX, y: before.minY, width: before.width, height: 999)
        staleFit(oldAttributes)
        controller.collection.layoutIfNeeded()
        let after = try XCTUnwrap(controller.collection.layoutAttributesForItem(at: path)).frame
        XCTAssertEqual(after.height, before.height, accuracy: 1)
        XCTAssertEqual(controller.revisions["native-row-6"]?.message.message.content, "new canonical content")
    }

    private func mountNativeMotion(scope: String = "native-motion-\(UUID().uuidString)",
                                   initialID: String? = "native-row-1", reduceMotion: Bool = false,
                                   ids: [String]? = nil, reusesIdentitySnapshot: Bool = true,
                                   batchesMotionObservations: Bool = true,
                                   coalescesScrollObservations: Bool = true,
                                   onState: @escaping (ChatScrollMetrics, String?, Bool, Bool) -> Void = { _, _, _, _ in },
                                   reduceMotionOverride: (() -> Bool)? = nil,
                                   makeCollection: @escaping @MainActor (UICollectionViewLayout) -> ChatNativeTranscriptViewport.Collection = {
                                       ChatNativeTranscriptViewport.Collection(frame: .zero, collectionViewLayout: $0)
                                   },
                                   onRefresh: @escaping @MainActor (@escaping @MainActor () -> Bool) async -> Void = { _ in }) throws
        -> (ChatNativeTranscriptViewport.Controller, MountedWindowFixture) {
        let input = nativeMotionInput(scope: scope, initialID: initialID, ids: ids, onState: onState, onRefresh: onRefresh)
        let controller = ChatNativeTranscriptViewport.Controller(input: input,
            reduceMotionEnabled: { reduceMotionOverride?() ?? (reduceMotion || UIAccessibility.isReduceMotionEnabled) },
            reusesIdentitySnapshot: reusesIdentitySnapshot,
            batchesMotionObservations: batchesMotionObservations,
            coalescesScrollObservations: coalescesScrollObservations, makeCollection: makeCollection)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        return (controller, MountedWindowFixture(window: window, previousKeyWindow: previous))
    }

    private func nativeMotionInput(scope: String, initialID: String?, ids suppliedIDs: [String]? = nil,
                                   revision: Int = 0, liveText: String = "", active: Bool = false, footerHeight: CGFloat = 30,
                                   cancellationToken: Int = 0, following: Bool = false, explicitLatest: Bool = false,
                                   latestToken: Int = 0,
                                   restoreRequest: ChatTranscriptRestoreRequest? = nil,
                                   typeKey: String = "mounted-native-motion", headerHeight: CGFloat = 1, horizontalPadding: CGFloat = 12,
                                   rowContentPrefix: String = "Mounted source row ",
                                   onState: @escaping (ChatScrollMetrics, String?, Bool, Bool) -> Void = { _, _, _, _ in },
                                   onRefresh: @escaping @MainActor (@escaping @MainActor () -> Bool) async -> Void = { _ in })
        -> ChatNativeTranscriptViewport {
        let ids = suppliedIDs ?? (0..<40).map { "native-row-\($0)" }
        let environment = EnvironmentValues()
        return ChatNativeTranscriptViewport(ids: ids, revisionAt: { index in
            let message = ChatMessage(role: "assistant",
                                      content: index == 6 ? liveText : "\(rowContentPrefix)\(index)",
                                      timestamp: Double(index), messageId: ids[index])
            return StableViewportRowRevision(
                message: TranscriptMessage(loadedIndex: index, renderID: ids[index],
                                           anchorID: ids[index], message: message),
                outgoingInsertionEvent: nil,
                allowsOutgoingMotion: false, reasoningGroups: [], toolCallGroups: [],
                liveReasoningText: "", liveToolCalls: [],
                streamingAssistantMessageID: active ? ids[6] : nil,
                liveTokensPerSecond: nil, localAttachmentPreviews: nil,
                compressionReferenceCard: nil, listeningMessageID: nil,
                showsThinkingAndToolCards: false, isViewingCachedData: false,
                hasActiveStream: active, isRegeneratingMessage: false,
                isEditingMessage: false, isForkingMessage: false,
                transcriptMediaCacheNamespace: scope)
        }, revision: revision, typeKey: typeKey, scope: scope,
           initialID: initialID, restoreRequest: restoreRequest, cancellationToken: cancellationToken,
           latestToken: latestToken, explicitLatest: explicitLatest, following: following, isStreaming: active,
           horizontalPadding: horizontalPadding, spacing: 12, bottomInset: 0, environment: environment,
           makeRow: { index in
               AnyView(Text(index == 6 ? liveText : "\(rowContentPrefix)\(index)")
                   .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading))
           }, makeHeader: { AnyView(Color.clear.frame(height: headerHeight)) },
           makeFooter: { AnyView(Text("Mounted terminal").frame(height: footerHeight)) },
           onLatest: {}, onState: onState, onRestore: { _, _ in }, onRefresh: onRefresh)
    }
    #endif

    // Separate fixture: the original raw first-frame mount helper stays intact.
    private func makeLegacyCompatibilityTranscript(
        onRestoreMessage: @escaping (String, Bool) -> Void
    ) -> ChatTranscriptView {
        let messages = (0..<40).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Restored transcript message \(index)",
                timestamp: Double(index),
                messageId: "message-\(index)"
            )
        }
        let transcriptMessages = messages.enumerated().map { index, message in
            TranscriptMessage(
                loadedIndex: index,
                renderID: message.id,
                anchorID: message.id,
                message: message
            )
        }

        return ChatTranscriptView(
            isLoading: false,
            errorMessage: nil,
            messages: messages,
            displayedTranscriptMessages: transcriptMessages,
            compressionReferenceCard: nil,
            reasoningGroupsForAnchor: { _ in [] },
            completedToolCallGroupsForAnchor: { _ in [] },
            liveReasoningText: "",
            reasoningAnchorMessageID: nil,
            liveToolCalls: [],
            toolCallAnchorMessageID: nil,
            streamingAssistantMessageID: nil,
            liveTokensPerSecond: nil,
            activeStreamRecoveryState: .idle,
            clarificationPrompt: nil,
            isRespondingToClarification: false,
            clarificationErrorMessage: nil,
            hidesRunStatusAccessibility: false,
            showsThinkingAndToolCards: true,
            showsAssistantTypingIndicator: false,
            showsScrollToBottomButton: false,
            shouldFollowLatestMessage: false,
            latestTranscriptMessageRole: "assistant",
            isScrolledNearBottom: false,
            activeStreamID: nil,
            streamingScrollTrigger: 0,
            cacheFirstReconcileScrollToken: 0,
            bottomAnchorID: "transcript-bottom",
            transcriptMessageSpacing: 12,
            transcriptBlockSpacing: 8,
            transcriptBottomInsetHeight: 0,
            scrollToBottomButtonBottomPadding: 0,
            localAttachmentPreviews: [:],
            listeningMessageID: nil,
            isViewingCachedData: false,
            hasOlderMessages: false,
            isLoadingOlderMessages: false,
            isRegeneratingMessage: false,
            isEditingMessage: false,
            isForkingMessage: false,
            loadAttachmentImage: { _ in nil },
            loadAttachmentData: { _ in nil },
            loadTranscriptMediaImage: { _ in nil },
            loadTranscriptMediaData: { _ in nil },
            transcriptMediaCacheNamespace: "restore-regression",
            actionContext: { _, _ in nil },
            shouldRenderMessageRow: { _ in true },
            onLoadMessages: {},
            onLoadOlderMessages: { _, _ in .noProgress },
            onUpdateScrollMetrics: { _ in },
            onDismissKeyboard: {},
            onScrollToBottom: { _, _, _, _ in },
            onScrollToLatestTranscriptMessage: { _ in },
            onScrollToLatestContent: { _, _ in
                XCTFail("A saved legacy target must never request Latest")
            },
            onScrollToTranscriptMessage: { _, id, animated in
                onRestoreMessage(id, animated)
            },
            onVisibleTranscriptRowIDChange: { _ in },
            onPreviewAttachment: { _, _ in },
            onPreviewTranscriptMedia: { _ in },
            onToggleListening: { _ in },
            onSubmitClarification: { _, _ in },
            onCancelClarification: { _ in },
            onSelectText: { _ in },
            onRegenerate: { _ in },
            onEdit: { _ in },
            onFork: { _ in },
            onCopy: { _ in },
            restoreScrollToken: 1,
            restoreTarget: .message(id: "legacy-missing")
        )
    }

    private func mountLegacyCompatibilityTranscript(_ transcript: ChatTranscriptView)
        throws -> (UIHostingController<LegacyCompatibilityRoot>, MountedWindowFixture) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: LegacyCompatibilityRoot(transcript: transcript))
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        return (host, MountedWindowFixture(window: window, previousKeyWindow: previous))
    }

    private func findLegacyCompatibilityViewport(in parent: UIViewController)
        -> ChatNativeTranscriptViewport.Controller? {
        if let native = parent as? ChatNativeTranscriptViewport.Controller { return native }
        return parent.children.lazy.compactMap { self.findLegacyCompatibilityViewport(in: $0) }.first
    }

    private func mountTranscript(
        restoreScrollToken: Int,
        restoreTarget: ChatTranscriptRestoreTarget,
        onAppear: @escaping () -> Void,
        onRestoreLatest: @escaping (Bool) -> Void,
        onRestoreMessage: @escaping (String, Bool) -> Void,
        onVisibleRowIDChange: @escaping (String?) -> Void = { _ in },
        restoreProbe: ChatTranscriptRestoreProbe? = nil,
        onDisplayLinkTick: @escaping (UIWindow?, Int, CFTimeInterval, CFTimeInterval) -> Void = { _, _, _, _ in }
    ) throws -> MountedWindowFixture {
        let messages = (0..<40).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Restored transcript message \(index)",
                timestamp: Double(index),
                messageId: "message-\(index)"
            )
        }
        let transcriptMessages = messages.enumerated().map { index, message in
            TranscriptMessage(
                loadedIndex: index,
                renderID: message.id,
                anchorID: message.id,
                message: message
            )
        }

        let view = ChatTranscriptView(
            isLoading: false,
            errorMessage: nil,
            messages: messages,
            displayedTranscriptMessages: transcriptMessages,
            compressionReferenceCard: nil,
            reasoningGroupsForAnchor: { _ in [] },
            completedToolCallGroupsForAnchor: { _ in [] },
            liveReasoningText: "",
            reasoningAnchorMessageID: nil,
            liveToolCalls: [],
            toolCallAnchorMessageID: nil,
            streamingAssistantMessageID: nil,
            liveTokensPerSecond: nil,
            activeStreamRecoveryState: .idle,
            clarificationPrompt: nil,
            isRespondingToClarification: false,
            clarificationErrorMessage: nil,
            hidesRunStatusAccessibility: false,
            showsThinkingAndToolCards: true,
            showsAssistantTypingIndicator: false,
            showsScrollToBottomButton: false,
            shouldFollowLatestMessage: restoreTarget == .latest,
            latestTranscriptMessageRole: "assistant",
            isScrolledNearBottom: false,
            activeStreamID: nil,
            streamingScrollTrigger: 0,
            cacheFirstReconcileScrollToken: 0,
            bottomAnchorID: "transcript-bottom",
            transcriptMessageSpacing: 12,
            transcriptBlockSpacing: 8,
            transcriptBottomInsetHeight: 0,
            scrollToBottomButtonBottomPadding: 0,
            localAttachmentPreviews: [:],
            listeningMessageID: nil,
            isViewingCachedData: false,
            hasOlderMessages: false,
            isLoadingOlderMessages: false,
            isRegeneratingMessage: false,
            isEditingMessage: false,
            isForkingMessage: false,
            loadAttachmentImage: { _ in nil },
            loadAttachmentData: { _ in nil },
            loadTranscriptMediaImage: { _ in nil },
            loadTranscriptMediaData: { _ in nil },
            transcriptMediaCacheNamespace: "restore-regression",
            actionContext: { _, _ in nil },
            shouldRenderMessageRow: { _ in true },
            onLoadMessages: {},
            onLoadOlderMessages: { _, _ in .noProgress },
            onUpdateScrollMetrics: { _ in },
            onDismissKeyboard: {},
            onScrollToBottom: { _, _, _, _ in },
            onScrollToLatestTranscriptMessage: { _ in },
            onScrollToLatestContent: { _, animated in
                onRestoreLatest(animated)
            },
            onScrollToTranscriptMessage: { _, id, animated in
                onRestoreMessage(id, animated)
            },
            onVisibleTranscriptRowIDChange: onVisibleRowIDChange,
            onPreviewAttachment: { _, _ in },
            onPreviewTranscriptMedia: { _ in },
            onToggleListening: { _ in },
            onSubmitClarification: { _, _ in },
            onCancelClarification: { _ in },
            onSelectText: { _ in },
            onRegenerate: { _ in },
            onEdit: { _ in },
            onFork: { _ in },
            onCopy: { _ in },
            restoreScrollToken: restoreScrollToken,
            restoreTarget: restoreTarget
        )

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windowScene = try XCTUnwrap(
            scenes.first(where: { $0.activationState == .foregroundActive }),
            "A foreground UIWindowScene is required to exercise the active mounted SwiftUI lifecycle."
        )
        let hostingController = UIHostingController(
            rootView: MountedChatTranscriptRoot(
                transcript: view,
                onAppear: onAppear,
                onDisplayLinkTick: onDisplayLinkTick
            )
            .environment(\.chatTranscriptRestoreProbe, restoreProbe)
            // Standalone UIHostingController does not receive the app Scene's
            // environment. Match the required real foreground scene explicitly.
            .environment(\.scenePhase, .active)
        )
        let window = UIWindow(windowScene: windowScene)
        let previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)
        // Match the real scene; a fixed smaller window invents an attachment reflow.
        window.frame = windowScene.coordinateSpace.bounds
        window.rootViewController = hostingController
        restoreProbe?.record("mount.makeKeyAndVisible.begin")
        window.makeKeyAndVisible()
        restoreProbe?.record("mount.makeKeyAndVisible.end")
        hostingController.view.frame = window.bounds
        restoreProbe?.record("mount.layoutIfNeeded.begin")
        hostingController.view.layoutIfNeeded()
        restoreProbe?.record("mount.layoutIfNeeded.end")
        return MountedWindowFixture(window: window, previousKeyWindow: previousKeyWindow)
    }

    private func tearDown(_ fixture: MountedWindowFixture) {
        fixture.window.isHidden = true
        fixture.window.rootViewController = nil
        fixture.previousKeyWindow?.makeKey()
    }
}

private struct PlainReaderShellRoot: View {
    @ObservedObject var route: ReaderShellRoute
    let capture: ReaderShellCapture
    let navigates: Bool

    private var label: some View {
        Text("Restored transcript message 10")
            .font(.body).foregroundStyle(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.white)
            .background {
                WindowAttachmentDisplayLinkProbe { window, tick, _, _ in
                    capture.record(window: window, tick: tick)
                }
            }
    }

    var body: some View {
        Group {
            if navigates {
                NavigationStack {
                    Color.clear
                        .background(NavigationAppearanceCompletionObserver {
                            capture.neutralRootAppearanceCompleted = true
                        })
                        .navigationDestination(isPresented: $route.chatPresented) { label }
                }
            } else { label }
        }
        .environment(\.scenePhase, .active)
    }
}

private struct ReaderShellRoot: View {
    @ObservedObject var route: ReaderShellRoute
    let session: SessionSummary
    let server: URL
    let model: ChatViewModel
    let capture: ReaderShellCapture

    var body: some View {
        NavigationStack {
            Color.clear
                .background(NavigationAppearanceCompletionObserver {
                    capture.neutralRootAppearanceCompleted = true
                })
                .navigationDestination(isPresented: $route.chatPresented) {
                    ChatView(session: session, server: server, onAPIError: { _ in },
                             loadsInitialMessages: false, retainedViewModel: model,
                             disablesExternalLifecycle: true)
                    .background {
                        WindowAttachmentDisplayLinkProbe { window, tick, _, _ in
                            capture.record(window: window, tick: tick)
                        }
                    }
                }
        }
        .environment(\.scenePhase, .active)
        .environment(\.chatTranscriptRestoreProbe, capture.probe)
    }
}

@MainActor
private final class ReaderShellRoute: ObservableObject {
    @Published var chatPresented = false
}

private struct ReaderShellSample {
    let tick: Int
    let image: UIImage?
    let geometry: String
    // presentedImage is the judged first-tick frame: the render-server state
    // the screen shows at this tick. The raw layer-tree image stays attached as
    // supplementary evidence; forcedDiagnostic is a diagnostic-only upper bound.
    let presentedImage: UIImage?
    let forcedDiagnostic: UIImage?
}

@MainActor
private final class ReaderShellCapture {
    var neutralRootAppearanceCompleted = false
    let probe = ChatTranscriptRestoreProbe()
    private(set) var samples: [ReaderShellSample] = []
    private var completed: XCTestExpectation?

    func beginVisit() -> XCTestExpectation {
        samples = []
        let expectation = XCTestExpectation(description: "four raw production shell attachment ticks")
        completed = expectation
        return expectation
    }

    func record(window: UIWindow?, tick: Int) {
        guard completed != nil else { return }
        let captureBegan = CACurrentMediaTime()
        let preCaptureWindow = window.map {
            "window.bounds=\($0.bounds) keyWindow=\($0.isKeyWindow) hidden=\($0.isHidden)"
        } ?? "window=nil"
        let image = window.map { window in
            UIGraphicsImageRenderer(bounds: window.bounds).image { context in
                // Supplementary raw layer-tree capture, not the judged frame:
                // display-list-backed transcript content does not render through
                // CALayer.render (same-tick blank vs readable proved in
                // daily-driver-firsttick-instrument-01).
                window.layer.render(in: context.cgContext)
            }
        }
        // Parallel instruments, taken strictly after the raw image. presented =
        // last render-server state (what the screen shows at this tick) and is
        // the judged first-tick frame; forced = upper bound after a forced
        // commit (diagnostic only). The forced commit may advance later ticks'
        // raw frames; that tradeoff is evidence-only and cannot change tick one,
        // which is captured before these run.
        var presentedSucceeded: Bool?
        let presentedImage = window.map { window in
            UIGraphicsImageRenderer(bounds: window.bounds).image { context in
                presentedSucceeded = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
        }
        let presentedFinished = CACurrentMediaTime()
        var forcedSucceeded: Bool?
        let forcedDiagnostic = window.map { window in
            UIGraphicsImageRenderer(bounds: window.bounds).image { context in
                forcedSucceeded = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }
        let forcedFinished = CACurrentMediaTime()
        let captureStatus = "preCapture: \(preCaptureWindow)"
            + "\npresentedSucceeded=\(String(describing: presentedSucceeded))"
            + " forcedSucceeded=\(String(describing: forcedSucceeded))"
            + " rawAndPresentedMs=\((presentedFinished - captureBegan) * 1000)"
            + " forcedMs=\((forcedFinished - presentedFinished) * 1000)"
            + " callbackBegan=\(captureBegan)"
        // Geometry is observed after the capture; it cannot force a later
        // hierarchy repaint into the image or replace tick one with tick four.
        // Split into locals: one concatenation chain here exceeds the type
        // checker's budget in this test target.
        let geometry: String
        if let window {
            let boundsLine = "window.bounds=\(window.bounds) safeArea=\(window.safeAreaInsets) scale=\(window.screen.scale)"
            let scrollLine = attachedScrollDescription(in: window)
            let layerLine = attachedLayerDescription(in: window)
            let censusLine = diagnosticScrollLayerSummary(in: window)
            geometry = captureStatus + "\n" + boundsLine + "\n" + scrollLine + "\n" + layerLine + "\n" + censusLine
        } else {
            geometry = captureStatus
        }
        samples.append(ReaderShellSample(tick: tick, image: image, geometry: geometry,
                                         presentedImage: presentedImage,
                                         forcedDiagnostic: forcedDiagnostic))
        if tick == 4 {
            completed?.fulfill()
            completed = nil
        }
    }
}

private struct MountedWindowFixture {
    let window: UIWindow
    let previousKeyWindow: UIWindow?
}

private enum MountedActivityMode: Equatable, CustomStringConvertible {
    case retainedAndLive
    case loose

    var description: String {
        switch self {
        case .retainedAndLive: "retained + live"
        case .loose: "loose retained"
        }
    }
}

@MainActor
private final class MountedActivityModel: ObservableObject {
    @Published var liveText = "Continuing to inspect the source."
}

private struct MountedActivityTranscriptRoot: View {
    @ObservedObject var model: MountedActivityModel
    let mode: MountedActivityMode

    private var messages: [ChatMessage] {
        [
            ChatMessage(role: "user", content: "Inspect the source", timestamp: 1, messageId: "activity-user"),
            ChatMessage(role: "assistant", content: "Work in progress", timestamp: 2, messageId: "activity-assistant")
        ]
    }

    var body: some View {
        ChatTranscriptView(
            isLoading: false, errorMessage: nil,
            messages: messages,
            displayedTranscriptMessages: messages.enumerated().map { index, message in
                TranscriptMessage(loadedIndex: index, renderID: message.id,
                                  anchorID: message.id, message: message)
            },
            compressionReferenceCard: nil,
            reasoningGroupsForAnchor: { anchor in
                let expectedAnchor: String? = mode == .loose ? nil : "activity-assistant"
                guard anchor == expectedAnchor else { return [] }
                return [ReasoningGroup(id: "activity-reasoning", anchorMessageID: expectedAnchor,
                                       text: "Retained source analysis.")]
            },
            completedToolCallGroupsForAnchor: { anchor in
                guard anchor == "activity-assistant" else { return [] }
                return [ToolCallGroup(anchorMessageID: anchor, toolCalls: [
                    ToolCall(name: "read_file", preview: "Synthetic source content",
                             args: ["path": .string("fixtures/example.md")], isCompleted: true)
                ])]
            },
            liveReasoningText: mode == .retainedAndLive ? model.liveText : "",
            reasoningAnchorMessageID: mode == .retainedAndLive ? "activity-assistant" : nil,
            liveToolCalls: [], toolCallAnchorMessageID: nil,
            streamingAssistantMessageID: nil, liveTokensPerSecond: nil,
            activeStreamRecoveryState: .idle, clarificationPrompt: nil,
            isRespondingToClarification: false, clarificationErrorMessage: nil,
            hidesRunStatusAccessibility: false, showsThinkingAndToolCards: true,
            showsAssistantTypingIndicator: mode == .loose,
            showsScrollToBottomButton: false, shouldFollowLatestMessage: true,
            latestTranscriptMessageRole: "assistant", isScrolledNearBottom: true,
            activeStreamID: "synthetic-active-stream", streamingScrollTrigger: 0,
            cacheFirstReconcileScrollToken: 0, bottomAnchorID: "activity-bottom",
            transcriptMessageSpacing: 12, transcriptBlockSpacing: 8,
            transcriptBottomInsetHeight: 0, scrollToBottomButtonBottomPadding: 0,
            localAttachmentPreviews: [:], listeningMessageID: nil,
            isViewingCachedData: false, hasOlderMessages: false, isLoadingOlderMessages: false,
            isRegeneratingMessage: false, isEditingMessage: false, isForkingMessage: false,
            loadAttachmentImage: { _ in nil }, loadAttachmentData: { _ in nil },
            loadTranscriptMediaImage: { _ in nil }, loadTranscriptMediaData: { _ in nil },
            transcriptMediaCacheNamespace: "activity-synthetic",
            actionContext: { _, _ in nil }, shouldRenderMessageRow: { _ in true },
            onLoadMessages: {}, onLoadOlderMessages: { _, _ in .noProgress },
            onUpdateScrollMetrics: { _ in }, onDismissKeyboard: {},
            onScrollToBottom: { _, _, _, _ in }, onScrollToLatestTranscriptMessage: { _ in },
            onScrollToLatestContent: { _, _ in },
            onPreviewAttachment: { _, _ in }, onPreviewTranscriptMedia: { _ in },
            onToggleListening: { _ in }, onSubmitClarification: { _, _ in },
            onCancelClarification: { _ in }, onSelectText: { _ in },
            onRegenerate: { _ in }, onEdit: { _ in }, onFork: { _ in }, onCopy: { _ in }
        )
        .environment(\.colorScheme, .dark)
    }
}

private struct LegacyCompatibilityRoot: View {
    let transcript: ChatTranscriptView
    var isVisible = true
    var scenePhase: ScenePhase = .active

    var body: some View {
        Group {
            if isVisible { transcript }
        }
        .environment(\.scenePhase, scenePhase)
    }
}

private struct MountedChatTranscriptRoot: View {
    let transcript: ChatTranscriptView
    let onAppear: () -> Void
    let onDisplayLinkTick: (UIWindow?, Int, CFTimeInterval, CFTimeInterval) -> Void

    var body: some View {
        transcript
            .background {
                WindowAttachmentDisplayLinkProbe(onDisplayLinkTick: onDisplayLinkTick)
            }
            .onAppear(perform: onAppear)
    }
}

private struct WindowAttachmentDisplayLinkProbe: UIViewRepresentable {
    @Environment(\.chatTranscriptRestoreProbe) private var restoreProbe
    let onDisplayLinkTick: (UIWindow?, Int, CFTimeInterval, CFTimeInterval) -> Void

    func makeUIView(context: Context) -> WindowAttachmentDisplayLinkProbeView {
        let view = WindowAttachmentDisplayLinkProbeView()
        view.onDisplayLinkTick = onDisplayLinkTick
        view.restoreProbe = restoreProbe
        return view
    }

    func updateUIView(_ uiView: WindowAttachmentDisplayLinkProbeView, context: Context) {
        uiView.onDisplayLinkTick = onDisplayLinkTick
    }

    static func dismantleUIView(_ uiView: WindowAttachmentDisplayLinkProbeView, coordinator: ()) {
        uiView.stop()
    }
}

private final class WindowAttachmentDisplayLinkProbeView: UIView {
    var onDisplayLinkTick: ((UIWindow?, Int, CFTimeInterval, CFTimeInterval) -> Void)?
    private var displayLink: CADisplayLink?
    var restoreProbe: ChatTranscriptRestoreProbe?
    private var tick = 0

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            stop()
            return
        }
        guard displayLink == nil, tick < 4 else { return }
        restoreProbe?.record("probe.didMoveToWindow")

        let displayLink = CADisplayLink(target: self, selector: #selector(displayLinkDidTick(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    @objc private func displayLinkDidTick(_ displayLink: CADisplayLink) {
        tick += 1
        onDisplayLinkTick?(window, tick, displayLink.timestamp, displayLink.targetTimestamp)
        if tick == 4 {
            stop()
            onDisplayLinkTick = nil
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

/// Public UIKit geometry only; querying it does not force layout/commit. All
/// descendant scroll views are reported to expose an absent or wrong attachment.
@MainActor
private func attachedScrollDescription(in window: UIWindow?) -> String {
    guard let window else { return "native.tick window=nil" }
    var samples: [String] = []
    func visit(_ view: UIView) {
        if let scroll = view as? UIScrollView {
            samples.append("id=\(scroll.accessibilityIdentifier ?? "nil") attached=\(scroll.window === window) offset=\(scroll.contentOffset) size=\(scroll.contentSize) bounds=\(scroll.bounds) inset=\(scroll.adjustedContentInset) presentationBounds=\(String(describing: scroll.layer.presentation()?.bounds)) dragging=\(scroll.isDragging) tracking=\(scroll.isTracking)")
        }
        view.subviews.forEach(visit)
    }
    visit(window)
    return "native.tick count=\(samples.count) " + samples.joined(separator: " | ")
}

/// Diagnostic-only deep census of the transcript scroll view's layer subtree.
/// Separates "cells exist but layer.render cannot see render-server content"
/// from "no content layers exist yet", without forcing layout or commit.
@MainActor
private func diagnosticScrollLayerSummary(in window: UIWindow) -> String {
    func findScroll(_ view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.accessibilityIdentifier == "chat-transcript-scroll" { return scroll }
        for sub in view.subviews {
            if let found = findScroll(sub) { return found }
        }
        return nil
    }
    guard let scroll = findScroll(window) else { return "diagnostic: transcript scroll view absent" }
    var total = 0
    var withContents = 0
    var rows: [String] = []
    func walk(_ layer: CALayer, depth: Int) {
        total += 1
        if layer.contents != nil { withContents += 1 }
        if rows.count < 16 {
            rows.append("d\(depth) \(String(describing: type(of: layer))) frame=\(layer.frame) contents=\(layer.contents != nil) sublayers=\(layer.sublayers?.count ?? 0)")
        }
        for sub in layer.sublayers ?? [] { walk(sub, depth: depth + 1) }
    }
    walk(scroll.layer, depth: 0)
    return "diagnostic: scroll layers total=\(total) withContents=\(withContents)\n" + rows.joined(separator: "\n")
}

/// Observed only after the unchanged raw image. Model and presentation-layer
/// visibility separate a covered/navigation-transition host from missing pixels
/// in layer.render, without forcing layout or substituting another capture.
@MainActor
private func attachedLayerDescription(in window: UIWindow) -> String {
    var rows: [String] = []
    func visit(_ view: UIView, depth: Int) {
        guard depth < 9, rows.count < 80 else { return }
        let layer = view.layer
        rows.append("depth=\(depth) type=\(type(of: view)) frame=\(view.convert(view.bounds, to: window)) alpha=\(view.alpha) hidden=\(view.isHidden) opacity=\(layer.opacity) presentedOpacity=\(String(describing: layer.presentation()?.opacity)) mask=\(layer.mask != nil) contents=\(layer.contents != nil) sublayers=\(layer.sublayers?.count ?? 0)")
        view.subviews.forEach { visit($0, depth: depth + 1) }
    }
    visit(window, depth: 0)
    return "afterRawCapture.layers\n" + rows.joined(separator: "\n")
}

/// Observation-only candidates, all expressed in hosting-view coordinates.
/// UIView.convert(_:to:) accounts for the scroll bounds' contentOffset origin;
/// frame is in the superview's coordinates and must not be compared directly.
/// Safe areas and adjusted content insets describe layout, not opaque occlusion.
/// None of these candidates asserts which pixels the real app makes visible.
@MainActor
private func firstTickViewportDescription(in window: UIWindow?) -> String {
    guard let window, let hosting = window.rootViewController?.viewIfLoaded else {
        return "viewport.tick1 windowOrLoadedHosting=nil"
    }
    let hostBounds = hosting.bounds
    let hostSafe = hosting.safeAreaLayoutGuide.layoutFrame
    let windowInHost = window.convert(window.bounds, to: hosting)
    let rawCaptureInHost = hostBounds.intersection(windowInHost)
    var samples = [
        "viewport.tick1 units=points candidateSpace=hosting capture=UIWindow.layer phase=afterRawCapture",
        "hosting.bounds=\(hostBounds) frameInSuperview=\(hosting.frame) safeAreaInsets=\(hosting.safeAreaInsets) safeAreaLayoutFrame=\(hostSafe)",
        "window.bounds=\(window.bounds) frame=\(window.frame) safeAreaInsets=\(window.safeAreaInsets) boundsInHosting=\(windowInHost) screenScale=\(window.screen.scale)"
    ]
    var scrollIndex = 0
    func visit(_ view: UIView) {
        if let scroll = view as? UIScrollView {
            let index = scrollIndex
            scrollIndex += 1
            let nativeInHost = scroll.convert(scroll.bounds, to: hosting)
            let adjustedBounds = scroll.bounds.inset(by: scroll.adjustedContentInset)
            let adjustedInHost = scroll.convert(adjustedBounds, to: hosting)
            let nativeSafeInHost = scroll.convert(scroll.safeAreaLayoutGuide.layoutFrame, to: hosting)
            let raw = nativeInHost.intersection(rawCaptureInHost)
            // Intersect actual clipping ancestors separately from safe areas.
            // Safe-area membership alone does not imply a layer clips there.
            var ancestorClipped = raw
            var ancestor = scroll.superview
            var ancestorIndex = 0
            while let current = ancestor {
                let rect = current.convert(current.bounds, to: hosting)
                if current.clipsToBounds {
                    ancestorClipped = ancestorClipped.intersection(rect)
                }
                samples.append("scroll[\(index)].ancestor[\(ancestorIndex)] type=\(String(describing: type(of: current))) boundsInHosting=\(rect) clipsToBounds=\(current.clipsToBounds)")
                if current === window { break }
                ancestor = current.superview
                ancestorIndex += 1
            }
            samples.append("scroll[\(index)] type=\(String(describing: type(of: scroll))) id=\(scroll.accessibilityIdentifier ?? "nil") attached=\(scroll.window === window) bounds=\(scroll.bounds) frameInSuperview=\(scroll.frame) contentOffset=\(scroll.contentOffset) contentInset=\(scroll.contentInset) adjustedContentInset=\(scroll.adjustedContentInset) safeAreaInsets=\(scroll.safeAreaInsets) safeAreaLayoutFrame=\(scroll.safeAreaLayoutGuide.layoutFrame) clipsToBounds=\(scroll.clipsToBounds)")
            samples.append("scroll[\(index)].converted nativeBounds=\(nativeInHost) adjustedBounds=\(adjustedInHost) nativeSafeArea=\(nativeSafeInHost)")
            // Names encode the entire formula; no fixed status-bar offset.
            samples.append("scroll[\(index)].candidate.rawCaptureIntersection=\(raw)")
            samples.append("scroll[\(index)].candidate.ancestorClipped=\(ancestorClipped)")
            samples.append("scroll[\(index)].candidate.ancestorClipped_hostSafe=\(ancestorClipped.intersection(hostSafe))")
            samples.append("scroll[\(index)].candidate.ancestorClipped_nativeSafe=\(ancestorClipped.intersection(nativeSafeInHost))")
            samples.append("scroll[\(index)].candidate.ancestorClipped_adjustedInsets=\(ancestorClipped.intersection(adjustedInHost))")
        }
        view.subviews.forEach(visit)
    }
    visit(hosting)
    samples.append("viewport.tick1 scrollCount=\(scrollIndex)")
    return samples.joined(separator: "\n")
}

final class BackRestoreSnapshotTests: XCTestCase {
    func testUninitializedAndUnresolvedRestoreDoNotReplaceDurableTarget() {
        XCTAssertNil(ChatTranscriptRestoreSnapshot.capture(preservesDurableTarget: false,
            didRequestRestore: false, didInteract: false, followingLatest: true, visibleMessageID: nil))
        XCTAssertNil(ChatTranscriptRestoreSnapshot.capture(preservesDurableTarget: true,
            didRequestRestore: true, didInteract: false, followingLatest: false, visibleMessageID: "estimated"))
    }

    func testBackSnapshotAndWarmOffsetSurviveLaterTeardownCapture() throws {
        let snapshot = try XCTUnwrap(ChatTranscriptRestoreSnapshot.capture(preservesDurableTarget: false,
            didRequestRestore: true, didInteract: true, followingLatest: false, visibleMessageID: "reader"))
        let memory = ChatWarmReaderMemory()
        let point = ChatWarmReaderMemory.Point(messageID: "reader", minY: -145, viewportWidth: 402)
        memory.capture(point)
        memory.suspendCapture()
        memory.capture(.init(messageID: "tail", minY: 0, viewportWidth: 402))
        XCTAssertEqual(memory.point, point)
        XCTAssertEqual(snapshot.visibleMessageID, "reader")
        XCTAssertFalse(snapshot.followingLatest)
        memory.resumeCapture()
        memory.capture(.init(messageID: "reopened", minY: -30, viewportWidth: 402))
        XCTAssertEqual(memory.point?.messageID, "reopened")
    }

    func testFollowingLatestSnapshotClearsOldReaderIdentity() throws {
        let snapshot = try XCTUnwrap(ChatTranscriptRestoreSnapshot.capture(preservesDurableTarget: false,
            didRequestRestore: false, didInteract: true, followingLatest: true, visibleMessageID: "old-reader"))
        XCTAssertNil(snapshot.visibleMessageID)
        XCTAssertTrue(snapshot.followingLatest)
    }
}

final class TranscriptEdgeGeometryTests: XCTestCase {
    func testBottomFadeStartsAfterReservedLastLineEdgeAndStaysBounded() {
        for height: CGFloat in [1, 240, 800] {
            for inset: CGFloat in [0, 96, 220, 1_000] {
                let edge = ChatTranscriptEdgeGeometry(height: height, bottomInset: inset)
                XCTAssertGreaterThanOrEqual(edge.topEnd, 0)
                XCTAssertLessThanOrEqual(edge.topEnd, edge.bottomStart)
                XCTAssertLessThanOrEqual(edge.bottomStart, edge.bottomEnd)
                XCTAssertLessThanOrEqual(edge.bottomEnd, 1)
                XCTAssertGreaterThanOrEqual(edge.bottomStart * height, max(0, height - inset))
            }
        }
    }
}

@MainActor
private final class MetricPublicationTestScrollView: UIScrollView {
    var directTouch = false
    override var isTracking: Bool { directTouch }
}

// Every RPC response below is a controlled mock. The barrier suspends exactly
// session.steer; no real socket, provider, credentials or server is involved.
@MainActor
private enum MountedReadinessWait {
    // The final resumed predicate is authoritative for fixture readiness, not a
    // startup-latency measurement. Never schedule another sleep after the budget.
    static func poll(
        condition: () -> Bool,
        now: () -> ContinuousClock.Instant = { ContinuousClock().now },
        suspend: () async throws -> Void = { try await Task.sleep(for: .milliseconds(10)) }
    ) async throws -> Bool {
        let deadline = now().advanced(by: .seconds(3))
        while true {
            if condition() { return true }
            if now() >= deadline { return false }
            try await suspend()
        }
    }
}

private enum MountedSteerResponse: Sendable {
    case accepted, rejected, transportFailure
}

private actor MountedSteerTransport: HermesGatewayTransport {
    struct Call: Sendable {
        let method: String
        let params: JSONValue?
    }
    let storedID: String
    let runtimeID: String
    private var connected = false
    private var running = false
    private var recorded: [Call] = []
    private var pending: CheckedContinuation<JSONValue?, Error>?
    struct ConnectionProgress: Sendable {
        let enteredAtUptime: Double?
        let returnedAtUptime: Double?
        let identifierReadCount: Int
        let firstIdentifierReadAtUptime: Double?
        let lastIdentifierReadAtUptime: Double?
        let isConnected: Bool
    }
    private var connectEnteredAtUptime: Double?
    private var connectReturnedAtUptime: Double?
    private var identifierReadCount = 0
    private var firstIdentifierReadAtUptime: Double?
    private var lastIdentifierReadAtUptime: Double?

    init(storedID: String, runtimeID: String) {
        self.storedID = storedID
        self.runtimeID = runtimeID
    }
    func connect() async throws {
        connectEnteredAtUptime = ProcessInfo.processInfo.systemUptime
        connected = true
        connectReturnedAtUptime = ProcessInfo.processInfo.systemUptime
    }
    func close() async { connected = false; resolve(.transportFailure) }
    func connectionIdentifier() async -> Int? {
        let uptime = ProcessInfo.processInfo.systemUptime
        identifierReadCount += 1
        if firstIdentifierReadAtUptime == nil { firstIdentifierReadAtUptime = uptime }
        lastIdentifierReadAtUptime = uptime
        return connected ? 1 : nil
    }
    func calls() -> [Call] { recorded }
    func connectionProgress() -> ConnectionProgress {
        ConnectionProgress(enteredAtUptime: connectEnteredAtUptime,
                           returnedAtUptime: connectReturnedAtUptime,
                           identifierReadCount: identifierReadCount,
                           firstIdentifierReadAtUptime: firstIdentifierReadAtUptime,
                           lastIdentifierReadAtUptime: lastIdentifierReadAtUptime,
                           isConnected: connected)
    }
    var isWaiting: Bool { pending != nil }

    func resolve(_ response: MountedSteerResponse) {
        let continuation = pending
        pending = nil
        switch response {
        case .accepted: continuation?.resume(returning: .object(["status": .string("accepted")]))
        case .rejected: continuation?.resume(returning: .object(["status": .string("rejected")]))
        case .transportFailure: continuation?.resume(throwing: HermesGatewayError.transport("controlled fixture failure"))
        }
    }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        recorded.append(Call(method: method, params: params))
        switch method {
        case "session.resume", "session.info":
            return .object(["session_id": .string(runtimeID), "session_key": .string(storedID),
                "running": .bool(running), "info": .object(["profile": .string("work")])])
        case "prompt.submit":
            running = true
            return .object(["status": .string("streaming")])
        case "session.steer":
            guard pending == nil else { throw DirectSessionError.invalidResponse }
            return try await withCheckedThrowingContinuation { pending = $0 }
        case "session.status":
            return .object(["output": .string(running ? "Agent Running: Yes" : "Agent Running: No")])
        case "session.usage": return .object([:])
        case "approval.pending": return .object(["approvals": .array([])])
        default:
            XCTFail("Unexpected controlled gateway method: \(method)")
            throw DirectSessionError.invalidResponse
        }
    }
}

private final class MountedSteerURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host?.hasSuffix(".invalid") == true,
              request.httpMethod == "GET", url.path.hasPrefix("/api/sessions/"),
              url.path.hasSuffix("/messages"),
              let sessionID = url.path.split(separator: "/").dropLast().last.map(String.init) else {
            XCTFail("Unexpected REST request in mounted steer fixture")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let json: [String: Any] = ["session_id": sessionID, "messages": [],
            "pagination": ["limit": 120, "offset": 0, "order": "latest", "returned": 0]]
        do {
            let data = try JSONSerialization.data(withJSONObject: json)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@MainActor
private final class MountedSteerNoopActivity: AgentLiveActivityManaging {
    func start(sessionID: String, sessionTitle: String, streamID: String?) {}
    func update(_ event: AgentLiveActivityEvent) {}
    func markStale() {}
    func end(status: AgentRunActivityStatus, activity: String, errorSummary: String?) {}
}

@MainActor
private final class MountedSteerRoute: ObservableObject {
    @Published var presented = false
    @Published var initialDraft = "running"
    @Published var visit = 0
    var backCount = 0
}

private struct MountedSteerRoot: View {
    @ObservedObject var route: MountedSteerRoute
    let session: SessionSummary
    let server: URL
    let model: ChatViewModel
    var body: some View {
        NavigationStack {
            Color.clear.navigationDestination(isPresented: $route.presented) {
                ChatView(session: session, server: server, onAPIError: { _ in },
                    onParentBack: { route.backCount += 1; route.presented = false },
                    initialDraft: route.initialDraft, loadsInitialMessages: false,
                    retainedViewModel: model, disablesExternalLifecycle: true)
                    .id(route.visit)
            }
        }
        .environment(\.scenePhase, .active)
    }
}

@MainActor
private final class MountedSteerFixture {
    let scope: String
    let server: URL
    let session: SessionSummary
    let model: ChatViewModel
    let transport: MountedSteerTransport
    let runtime: HermesServerRuntime
    let defaults: UserDefaults
    let urlSession: URLSession
    let markerRoot: URL
    let route = MountedSteerRoute()
    let window: UIWindow
    let previousKeyWindow: UIWindow?
    private var closed = false

    init() throws {
        scope = "mounted-steer-" + UUID().uuidString.lowercased()
        server = try XCTUnwrap(URL(string: "https://" + scope + ".invalid"))
        session = SessionSummary(sessionId: scope, title: "Controlled steer fixture", profile: "work")
        defaults = try XCTUnwrap(UserDefaults(suiteName: scope))
        defaults.set(StreamingSendBehavior.steer.rawValue, forKey: StreamingSendBehavior.storageKey)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MountedSteerURLProtocol.self]
        urlSession = URLSession(configuration: config)
        let client = APIClient(baseURL: server, session: urlSession, publicMediaSession: urlSession,
                               customHeaderProvider: { [] })
        transport = MountedSteerTransport(storedID: scope, runtimeID: "runtime-" + scope)
        let controlledTransport = transport
        runtime = try HermesServerRuntime(origin: server) { _ in controlledTransport }
        let controlledRuntime = runtime
        markerRoot = FileManager.default.temporaryDirectory.appendingPathComponent(scope, isDirectory: true)
        model = ChatViewModel(session: session, server: server, client: client,
            liveActivityManager: MountedSteerNoopActivity(), userDefaults: defaults,
            gatewayRuntimeProvider: { _ in controlledRuntime },
            directAttachmentRecoveryMarkerStore: DirectGatewayAttachmentRecoveryMarkerStore(rootURL: markerRoot),
            promptUncertaintyStore: InMemoryDirectPromptDeliveryUncertaintyStore())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }), "A foreground scene is required")
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let schema = Schema([CachedSession.self, CachedMessage.self, CachedSessionPreviewRecord.self])
        let container = try ModelContainer(for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        window.rootViewController = UIHostingController(rootView:
            MountedSteerRoot(route: route, session: session, server: server, model: model)
                .modelContainer(container).defaultAppStorage(defaults))
    }

    var persistedDraft: String { ComposerDraftStore.shared.load(server: server, sessionID: scope) }

    func waitForPersistedDraft(_ expected: String) async throws {
        try await wait { self.persistedDraft == expected }
    }

    func start() async throws {
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        route.presented = true
        try await wait({ self.find("chat-composer-input", in: self.window) is UITextView },
                       phase: "startup: composer mounted")
        try await keyboardSend()
        try await wait({ self.model.activeStreamID != nil && !self.model.isStartingChat },
                       phase: "startup: initial prompt running")
        try await wait({ (try? self.composer().text) == "" },
                       phase: "startup: initial draft cleared")
        let calls = await transport.calls()
        XCTAssertEqual(calls.filter { $0.method == "prompt.submit" }.count, 1)
    }

    func composer() throws -> UITextView {
        try XCTUnwrap(find("chat-composer-input", in: window) as? UITextView)
    }

    func edit(_ text: String) throws {
        let input = try composer()
        XCTAssertTrue(input.isEditable)
        XCTAssertTrue(input.becomeFirstResponder())
        input.selectedRange = NSRange(location: 0, length: (input.text as NSString).length)
        if text.isEmpty { input.deleteBackward() } else { input.insertText(text) }
        XCTAssertEqual(input.text, text, "Edit the native UITextView, through its production delegate binding")
    }

    func keyboardSend() async throws {
        try await wait({
            guard let input = try? self.composer(),
                  let command = input.keyCommands?.first(where: { $0.action == NSSelectorFromString("sendMessageFromKeyboard") }),
                  let action = command.action else { return false }
            return input.canPerformAction(action, withSender: command)
        }, phase: "keyboard Send enabled")
        let input = try composer()
        let command = try XCTUnwrap(input.keyCommands?.first(where: { $0.action == NSSelectorFromString("sendMessageFromKeyboard") }))
        XCTAssertTrue(input.becomeFirstResponder())
        // Invoke the actual registered UIKit key command, which calls the
        // production actionButtonTapped -> onSend -> ChatView.sendDraftMessage.
        input.perform(command.action, with: command)
    }

    func submit(_ text: String) async throws {
        try edit(text)
        await drain()
        try await keyboardSend()
        let deadline = Date().addingTimeInterval(3)
        while !(await transport.isWaiting), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiting = await transport.isWaiting
        XCTAssertTrue(waiting, "The actual mounted Send must reach the controlled session.steer barrier")
        guard waiting else { throw DirectSessionError.invalidResponse }
    }

    func resolve(_ response: MountedSteerResponse) async { await transport.resolve(response) }

    func waitForResult(_ response: MountedSteerResponse) async throws {
        try await wait {
            switch response {
            case .accepted: return self.model.pinnedLocalNotices.contains("Steering hint delivered.")
            case .rejected: return self.model.sendErrorMessage == "Hermes rejected this steering hint; the current response was not interrupted."
            case .transportFailure: return self.model.sendErrorMessage == "Could not deliver the steering hint. The message was not resent."
            }
        }
        await drain()
    }

    func back() async throws {
        let button = try XCTUnwrap(find("chat-back", in: window) as? UIButton)
        let before = route.backCount
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(route.backCount, before + 1, "Use the production Back action")
        try await wait { self.find("chat-composer-input", in: self.window) == nil }
        await drain()
    }

    func reopen() async throws {
        route.initialDraft = ""
        route.visit += 1
        route.presented = true
        try await wait { self.find("chat-composer-input", in: self.window) is UITextView }
        await drain()
    }

    func assertOnlySteer(text: String) async {
        let calls = await transport.calls()
        let hints = calls.filter { $0.method == "session.steer" }
        XCTAssertEqual(hints.count, 1)
        XCTAssertEqual(hints.first?.params?.gatewayFields["text"], .string(text))
        XCTAssertEqual(hints.first?.params?.gatewayFields["session_id"], .string("runtime-" + scope))
        XCTAssertEqual(hints.first?.params?.gatewayFields["profile"], .string("work"))
        XCTAssertEqual(calls.filter { $0.method == "prompt.submit" }.count, 1)
        XCTAssertFalse(calls.contains { $0.method == "session.interrupt" })
        XCTAssertNotNil(model.activeStreamID, "Steering never terminates the original response")
    }

    func drain() async {
        for _ in 0..<3 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
            }
            window.layoutIfNeeded()
        }
    }

    private func wait(_ condition: () -> Bool, phase: String = "mounted composer") async throws {
        let waitStartedAtUptime = ProcessInfo.processInfo.systemUptime
        let tracesStartup = phase == "startup: initial prompt running"
        let token = UUID().uuidString
        let markerBeginWritten = tracesStartup && writeStartupMarker(token: token, active: true)
        var markerEnded = false
        defer { if tracesStartup && !markerEnded { writeStartupMarker(token: token, active: false) } }
        var pollCount = 0
        var previousPoll = waitStartedAtUptime
        var maximumPollGap = 0.0
        var transitions: [[String: Any]] = []
        var previousState: String?
        let satisfied = try await MountedReadinessWait.poll(condition: {
            if tracesStartup {
                let uptime = ProcessInfo.processInfo.systemUptime
                pollCount += 1
                maximumPollGap = max(maximumPollGap, uptime - previousPoll)
                previousPoll = uptime
                let state = String(describing: self.runtime.state)
                if state != previousState, transitions.count < 16 {
                    transitions.append(["uptime": uptime, "runtimeState": state,
                        "starting": self.model.isStartingChat, "activeRun": self.model.activeStreamID != nil])
                    previousState = state
                }
            }
            return condition()
        })
        let finalPollState: [String: Any] = ["uptime": previousPoll,
            "runtimeState": String(describing: runtime.state),
            "starting": model.isStartingChat, "activeRun": model.activeStreamID != nil]
        // End the external sample window before failure attachment/actor hops.
        let markerEndWritten = tracesStartup && writeStartupMarker(token: token, active: false)
        markerEnded = markerEndWritten || !tracesStartup
        if satisfied { return }
        let failureMessage = "Mounted composer condition did not settle (\(phase)); "
            + "keyWindow=\(window.isKeyWindow), scene=\(String(describing: window.windowScene?.activationState)), "
            + "composerMounted=\(find("chat-composer-input", in: window) is UITextView), "
            + "starting=\(model.isStartingChat), activeRun=\(model.activeStreamID != nil), "
            + "sendError=\(model.sendErrorMessage ?? "nil")"
        await attachWaitFailureDiagnostic(phase: phase, waitStartedAtUptime: waitStartedAtUptime,
            readinessProgress: tracesStartup ? ["pollCount": pollCount,
                "maximumPollGapSeconds": maximumPollGap, "runtimeTransitions": transitions,
                "finalPollState": finalPollState, "markerBeginWritten": markerBeginWritten,
                "markerEndWritten": markerEndWritten] : nil)
        XCTFail(failureMessage)
        throw DirectSessionError.invalidResponse
    }

    @discardableResult
    private func writeStartupMarker(token: String, active: Bool) -> Bool {
        // Test-only, fixed-schema metadata for the bounded CI watchdog. No text,
        // scope/session/server identifiers, parameters or error strings are written.
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1, "phase": "initial-prompt-running", "token": token,
                "active": active, "pid": ProcessInfo.processInfo.processIdentifier,
                "uptime": ProcessInfo.processInfo.systemUptime], options: [.sortedKeys]) else { return false }
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try data.write(to: cache.appendingPathComponent("semreh-mounted-startup.json"), options: .atomic)
            return true
        } catch { return false }
    }

    private func attachWaitFailureDiagnostic(phase: String, waitStartedAtUptime: Double,
                                             readinessProgress: [String: Any]?) async {
        // Capture UI/model state before hopping to the controlled transport actor.
        // No transcript, identifiers, request parameters or error text is attached.
        let stateCapturedAtUptime = ProcessInfo.processInfo.systemUptime
        let allowedPhases = ["mounted composer", "startup: composer mounted",
                             "startup: initial prompt running", "startup: initial draft cleared",
                             "keyboard Send enabled"]
        func frameJSON(_ frame: CGRect) -> Any {
            let values = [Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)]
            return values.allSatisfy { $0.isFinite } ? values as Any : NSNull()
        }
        func editors(in view: UIView) -> [UITextView] {
            let current = (view as? UITextView).map {
                $0.accessibilityIdentifier == "chat-composer-input" ? [$0] : []
            } ?? []
            return current + view.subviews.flatMap { editors(in: $0) }
        }
        let mountedEditors = editors(in: window)
        let runtimeState: String
        switch runtime.state {
        case .disconnected: runtimeState = "disconnected"
        case .connecting: runtimeState = "connecting"
        case .ready: runtimeState = "ready"
        case .stopped: runtimeState = "stopped"
        }
        var receipt: [String: Any] = [
            "schemaVersion": 3,
            "phase": allowedPhases.contains(phase) ? phase : "other",
            "readinessWaitStartedAtUptime": waitStartedAtUptime,
            "readinessElapsedSeconds": stateCapturedAtUptime - waitStartedAtUptime,
            "stateCapturedAtUptime": stateCapturedAtUptime,
            "applicationState": UIApplication.shared.applicationState.rawValue,
            "sceneActivationState": window.windowScene.map { $0.activationState.rawValue as Any } ?? NSNull(),
            "windowIsKey": window.isKeyWindow,
            "windowIsHidden": window.isHidden,
            "windowFrame": frameJSON(window.frame),
            "routePresented": route.presented,
            "editorCount": mountedEditors.count,
            "editors": mountedEditors.prefix(2).map { editor -> [String: Any] in
                ["attachedToOwnedWindow": editor.window === window,
                 "frameInOwnedWindow": frameJSON(editor.convert(editor.bounds, to: window)),
                 "isFirstResponder": editor.isFirstResponder,
                 "isEditable": editor.isEditable,
                 "isSelectable": editor.isSelectable,
                 "isHidden": editor.isHidden,
                 "isUserInteractionEnabled": editor.isUserInteractionEnabled]
            },
            "model": ["isStartingChat": model.isStartingChat,
                      "hasActiveRun": model.activeStreamID != nil,
                      "hasSendError": model.sendErrorMessage != nil,
                      "isEstablishingConnection": model.isEstablishingConnection,
                      "hasPromptDeliveryUncertainty": model.directConversationHasPromptDeliveryUncertainty,
                      "hasConfirmedAcceptance": model.directPromptDeliveryHasConfirmedAcceptance],
            "runtime": ["state": runtimeState, "connectionGeneration": runtime.connectionGeneration]
        ]
        receipt["readinessProgress"] = readinessProgress ?? [:]
        let allowedMethods = ["session.resume", "session.info", "prompt.submit", "session.steer",
                              "session.status", "session.usage", "approval.pending"]
        let calls = await transport.calls()
        let connection = await transport.connectionProgress()
        receipt["mockConnectionProgress"] = [
            "enteredAtUptime": connection.enteredAtUptime.map { $0 as Any } ?? NSNull(),
            "returnedAtUptime": connection.returnedAtUptime.map { $0 as Any } ?? NSNull(),
            "identifierReadCount": connection.identifierReadCount,
            "firstIdentifierReadAtUptime": connection.firstIdentifierReadAtUptime.map { $0 as Any } ?? NSNull(),
            "lastIdentifierReadAtUptime": connection.lastIdentifierReadAtUptime.map { $0 as Any } ?? NSNull(),
            "isConnected": connection.isConnected
        ]
        receipt["rpcMethodCounts"] = Dictionary(uniqueKeysWithValues: allowedMethods.map { method in
            (method, calls.filter { $0.method == method }.count)
        })
        receipt["unlistedMethodCount"] = calls.filter { !allowedMethods.contains($0.method) }.count
        receipt["steerResponsePending"] = await transport.isWaiting
        let transportSampledAtUptime = ProcessInfo.processInfo.systemUptime
        receipt["transportSampledAtUptime"] = transportSampledAtUptime
        receipt["transportSnapshotLagSeconds"] = transportSampledAtUptime - stateCapturedAtUptime
        let data = (try? JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]))
            ?? Data("{\"schemaVersion\":3,\"serializationFailed\":true}".utf8)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "mounted-steer-readiness-failure"
        attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: "Mounted steer readiness failure") { $0.add(attachment) }
    }

    private func find(_ identifier: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == identifier { return view }
        for child in view.subviews {
            if let found = find(identifier, in: child) { return found }
        }
        return nil
    }

    func close() async {
        guard !closed else { return }
        closed = true
        // Release a blocked production send even on assertion/throw paths.
        let wasWaiting = await transport.isWaiting
        await transport.resolve(.transportFailure)
        if wasWaiting { try? await waitForResult(.transportFailure) }
        try? await wait { !self.model.isStartingChat }
        route.presented = false
        try? await wait { self.find("chat-composer-input", in: self.window) == nil }
        await drain()
        window.isHidden = true
        window.rootViewController = nil
        await drain()
        await model.disposeDirectConversation()
        await runtime.stop()
        urlSession.invalidateAndCancel()
        previousKeyWindow?.makeKey()
        defaults.removePersistentDomain(forName: scope)
        // Only this generated origin/identity; never reset the shared stores.
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(scope) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        if FileManager.default.fileExists(atPath: markerRoot.path) {
            try? FileManager.default.removeItem(at: markerRoot)
        }
    }
}
