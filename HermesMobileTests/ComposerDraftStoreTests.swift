import XCTest
import SwiftUI
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

@MainActor
final class ComposerDraftStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: ComposerDraftStore!
    private let server = URL(string: "https://semreh.example")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ComposerDraftStoreTests.\(UUID().uuidString)")
        store = ComposerDraftStore(defaults: defaults)
    }

    override func tearDown() {
        store.resetForTesting()
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.contains("suite") ? "" : "")
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testLeaveAndReopenRestoresTypedDraft() {
        store.save("half-written thought", server: server, sessionID: "session-a")

        XCTAssertEqual(
            store.load(server: server, sessionID: "session-a"),
            "half-written thought"
        )
    }

    func testDraftsAreIsolatedPerSession() {
        store.save("for A", server: server, sessionID: "session-a")
        store.save("for B", server: server, sessionID: "session-b")

        XCTAssertEqual(store.load(server: server, sessionID: "session-a"), "for A")
        XCTAssertEqual(store.load(server: server, sessionID: "session-b"), "for B")
    }

    func testDraftSurvivesANewStoreInstanceLikeAnAppRestart() {
        store.save("still here after relaunch", server: server, sessionID: "session-a")

        let relaunched = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a"),
            "still here after relaunch"
        )
    }

    func testClearingOrSendingRemovesTheDraft() {
        store.save("do not keep after send", server: server, sessionID: "session-a")
        store.clear(server: server, sessionID: "session-a")

        XCTAssertEqual(store.load(server: server, sessionID: "session-a"), "")
    }

    func testPreAwaitClearRemovesSubmittedDraftWithoutTouchingAnotherSession() {
        // Store-level coverage for the write sequence used before a gated
        // send. This does not prove production call order or process-death
        // durability.
        store.save("A", server: server, sessionID: "session-a")
        store.save("B", server: server, sessionID: "session-b")

        store.save("", server: server, sessionID: "session-a")

        let freshStore = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(freshStore.load(server: server, sessionID: "session-a"), "")
        XCTAssertEqual(freshStore.load(server: server, sessionID: "session-b"), "B")
    }

    func testDefiniteFailureCanRestoreDraftAfterPreAwaitClear() {
        store.save("A", server: server, sessionID: "session-a")

        // Model the direct-send sequence: clear before the await, then
        // restore the submitted draft when the operation definitely fails.
        store.save("", server: server, sessionID: "session-a")
        store.save("A", server: server, sessionID: "session-a")

        XCTAssertEqual(store.load(server: server, sessionID: "session-a"), "A")
    }

    func testEmptyOrWhitespaceOnlyDraftIsNotRestored() {
        store.save("   \n\t  ", server: server, sessionID: "session-a")

        XCTAssertEqual(store.load(server: server, sessionID: "session-a"), "")
    }

    func testShareSheetDraftWinsOverAnEmptyStoredDraft() {
        XCTAssertEqual(
            ComposerDraftStore.resolvedDraft(initialDraft: "from share", storedDraft: ""),
            "from share"
        )
    }

    func testStoredDraftWinsWhenTheComposerWouldOtherwiseBeEmpty() {
        XCTAssertEqual(
            ComposerDraftStore.resolvedDraft(initialDraft: "", storedDraft: "cached"),
            "cached"
        )
    }

    func testLocalDraftRegistrationIsInvisibleUntilNonemptySaveAndSurvivesReconstruction() throws {
        let session = SessionSummary(localDraftID: "local-draft-a", title: "New Chat", createdAt: 1, profile: "default")
        store.registerLocalDraft(session, server: server)
        XCTAssertTrue(store.reachableLocalDrafts(server: server, profile: "default").isEmpty)
        store.save("  preserved 👩🏽‍💻\n", server: server, sessionID: session.id)

        let reconstructed = ComposerDraftStore(defaults: defaults)
        let restored = try XCTUnwrap(reconstructed.reachableLocalDrafts(server: server, profile: "default").first)
        XCTAssertEqual(restored.id, session.id)
        XCTAssertNil(restored.sessionId)
        XCTAssertEqual(restored.createdAt, session.createdAt)
        XCTAssertEqual(restored.profile, session.profile)
        XCTAssertEqual(reconstructed.load(server: server, sessionID: restored.id), "  preserved 👩🏽‍💻\n")
    }

    func testLocalConfigurationAndTextReconstructFromOnePayloadWithExactValues() throws {
        let session = SessionSummary(localDraftID: "local-draft-config", workspace: "/work/Project 👩🏽‍💻",
            model: "Vendor/Model:Preview", modelProvider: "Provider-A", reasoningEffort: "xhigh",
            createdAt: 1, profile: "work")
        store.registerLocalDraft(session, server: server)
        store.save("  unfinished\n", server: server, sessionID: session.id)
        // The indexed payload must restore both text and configuration without
        // relying on the legacy per-session text copy.
        defaults.removeObject(forKey: ComposerDraftStore.visibilityKeyPrefix + server.absoluteString + "|" + session.id)
        let restarted = ComposerDraftStore(defaults: defaults)
        let restored = try XCTUnwrap(restarted.reachableLocalDrafts(server: server, profile: "work").first)
        XCTAssertEqual(restored.id, session.id)
        XCTAssertNil(restored.sessionId)
        XCTAssertEqual(restored.model, session.model)
        XCTAssertEqual(restored.modelProvider, session.modelProvider)
        XCTAssertEqual(restored.workspace, session.workspace)
        XCTAssertEqual(restored.reasoningEffort, session.reasoningEffort)
        XCTAssertEqual(restored.createdAt, session.createdAt)
        XCTAssertEqual(restarted.load(server: server, sessionID: restored.id), "  unfinished\n")
        XCTAssertTrue(restarted.reachableLocalDrafts(server: server, profile: "default").isEmpty)
        XCTAssertTrue(restarted.reachableLocalDrafts(server: server, profile: "Work").isEmpty)
    }

    func testConfigurationOnlySaveReplacesChoicesAndExplicitNilWithoutClearingText() throws {
        let original = SessionSummary(localDraftID: "local-draft-config", workspace: "/old",
            model: "old-model", modelProvider: "old-provider", reasoningEffort: "high", profile: "default")
        store.registerLocalDraft(original, server: server)
        store.save("unchanged text", server: server, sessionID: original.id)
        let changed = SessionSummary(localDraftID: original.id, workspace: "/new",
            model: "new-model", modelProvider: "new-provider", reasoningEffort: "low", profile: "default")
        store.registerLocalDraft(changed, server: server)
        store.save("unchanged text", server: server, sessionID: original.id)
        let restarted = ComposerDraftStore(defaults: defaults)
        let updated = try XCTUnwrap(restarted.reachableLocalDrafts(server: server, profile: "default").first)
        XCTAssertEqual(updated.model, "new-model")
        XCTAssertEqual(updated.modelProvider, "new-provider")
        XCTAssertEqual(updated.workspace, "/new")
        XCTAssertEqual(updated.reasoningEffort, "low")
        XCTAssertEqual(restarted.load(server: server, sessionID: original.id), "unchanged text")

        // Explicit nil must replace old metadata, including the raw reasoning
        // override. It must never be serialized as the effective profile effort.
        restarted.registerLocalDraft(SessionSummary(localDraftID: original.id,
            model: "new-model", profile: "default"), server: server)
        restarted.save("unchanged text", server: server, sessionID: original.id)
        let afterInherit = ComposerDraftStore(defaults: defaults)
        let inherited = try XCTUnwrap(afterInherit.reachableLocalDrafts(server: server, profile: "default").first)
        XCTAssertEqual(inherited.id, original.id)
        XCTAssertEqual(inherited.model, "new-model")
        XCTAssertNil(inherited.modelProvider)
        XCTAssertNil(inherited.workspace)
        XCTAssertNil(inherited.reasoningEffort)
        XCTAssertEqual(afterInherit.load(server: server, sessionID: inherited.id), "unchanged text")
    }

    func testConfiguredDraftsKeepExactServerAndProfileScopes() throws {
        let otherServer = URL(string: "https://semreh.example:8443")!
        let scopes: [(String, URL, String, String, String?)] = [
            ("local-draft-same-id", server, "default", "default-model", "high"),
            ("local-draft-work", server, "work", "work-model", nil),
            ("local-draft-same-id", otherServer, "default", "other-model", "low")
        ]
        for (id, origin, profile, model, effort) in scopes {
            store.registerLocalDraft(SessionSummary(localDraftID: id, workspace: "/" + model,
                model: model, modelProvider: model + "-provider", reasoningEffort: effort,
                profile: profile), server: origin)
            store.save(model + " text", server: origin, sessionID: id)
        }
        let restarted = ComposerDraftStore(defaults: defaults)
        for (id, origin, profile, model, effort) in scopes {
            let rows = restarted.reachableLocalDrafts(server: origin, profile: profile)
            XCTAssertEqual(rows.count, 1)
            let restored = try XCTUnwrap(rows.first)
            XCTAssertEqual(restored.id, id)
            XCTAssertEqual(restored.profile, profile)
            XCTAssertEqual(restored.model, model)
            XCTAssertEqual(restored.modelProvider, model + "-provider")
            XCTAssertEqual(restored.workspace, "/" + model)
            XCTAssertEqual(restored.reasoningEffort, effort)
            XCTAssertEqual(restarted.load(server: origin, sessionID: id), model + " text")
        }
        XCTAssertTrue(restarted.reachableLocalDrafts(server: server, profile: "Work").isEmpty)
    }

    func testLegacyLocalPayloadWithMissingConfigurationAndUnknownFieldsRemainsReachable() throws {
        let data = Data(#"[{"id":"local-draft-legacy","profile":"default","text":"legacy text","createdAt":1,"future_field":{"enabled":true}}]"#.utf8)
        defaults.set(data, forKey: "semreh.localComposerDrafts." + server.absoluteString)
        let restarted = ComposerDraftStore(defaults: defaults)
        let legacy = try XCTUnwrap(restarted.reachableLocalDrafts(server: server, profile: "default").first)
        XCTAssertEqual(legacy.id, "local-draft-legacy")
        XCTAssertNil(legacy.model)
        XCTAssertNil(legacy.modelProvider)
        XCTAssertNil(legacy.workspace)
        XCTAssertNil(legacy.reasoningEffort)
        XCTAssertEqual(restarted.load(server: server, sessionID: legacy.id), "legacy text")
        restarted.registerLocalDraft(legacy, server: server)
        restarted.save("edited legacy text", server: server, sessionID: legacy.id)
        let afterEdit = ComposerDraftStore(defaults: defaults)
        XCTAssertNil(afterEdit.reachableLocalDrafts(server: server, profile: "default").first?.reasoningEffort)
        XCTAssertEqual(afterEdit.load(server: server, sessionID: legacy.id), "edited legacy text")
    }

    func testConfiguredDraftRetainsChoicesAfterPreAwaitClearAndDefiniteFailure() throws {
        let session = SessionSummary(localDraftID: "local-draft-failed", workspace: "/workspace",
            model: "model", modelProvider: "provider", reasoningEffort: "high", profile: "default")
        store.registerLocalDraft(session, server: server)
        store.save("submitted", server: server, sessionID: session.id)
        let reopenedStore = ComposerDraftStore(defaults: defaults)
        let reopened = try XCTUnwrap(reopenedStore.reachableLocalDrafts(server: server, profile: "default").first)
        reopenedStore.registerLocalDraft(reopened, server: server)
        reopenedStore.clear(server: server, sessionID: reopened.id)
        XCTAssertTrue(reopenedStore.reachableLocalDrafts(server: server, profile: "default").isEmpty)
        reopenedStore.save("submitted", server: server, sessionID: reopened.id)
        let restarted = ComposerDraftStore(defaults: defaults)
        let restored = try XCTUnwrap(restarted.reachableLocalDrafts(server: server, profile: "default").first)
        XCTAssertEqual(restored.model, session.model)
        XCTAssertEqual(restored.modelProvider, session.modelProvider)
        XCTAssertEqual(restored.workspace, session.workspace)
        XCTAssertEqual(restored.reasoningEffort, session.reasoningEffort)
        XCTAssertEqual(restarted.load(server: server, sessionID: restored.id), "submitted")
    }

    func testConfigurationSaveAfterRetirementCannotResurrectLocalRowOrChangeCanonicalRouting() {
        let local = SessionSummary(localDraftID: "local-draft-consumed-config", workspace: "/workspace",
            model: "model", modelProvider: "provider", reasoningEffort: "high", profile: "default")
        store.registerLocalDraft(local, server: server)
        store.save("submitted", server: server, sessionID: local.id)
        store.clear(server: server, sessionID: local.id)
        store.retireLocalDraft(server: server, sessionID: local.id, canonicalSessionID: "Canonical:Exact-ID")
        store.registerLocalDraft(SessionSummary(localDraftID: local.id, workspace: "/changed",
            model: "changed", profile: "work"), server: server)
        store.save("next composer text", server: server, sessionID: local.id)
        let restarted = ComposerDraftStore(defaults: defaults)
        XCTAssertTrue(restarted.reachableLocalDrafts(server: server, profile: "default").isEmpty)
        XCTAssertTrue(restarted.reachableLocalDrafts(server: server, profile: "work").isEmpty)
        XCTAssertEqual(restarted.load(server: server, sessionID: local.id), "")
        XCTAssertEqual(restarted.load(server: server, sessionID: "Canonical:Exact-ID"), "next composer text")
    }

    func testReachableDraftsUseExactOriginAndProfileWithoutIncludingServerComposers() {
        let other = URL(string: "https://other.example:8443")!
        let sameHostOtherPort = URL(string: "https://semreh.example:8443")!
        for (id, origin, profile) in [
            ("local-draft-a", server, "default"),
            ("local-draft-work", server, "work"),
            ("local-draft-other", other, "default"),
            ("local-draft-port", sameHostOtherPort, "default")
        ] {
            let session = SessionSummary(localDraftID: id, title: "New Chat", profile: profile)
            store.registerLocalDraft(session, server: origin)
            store.save(id, server: origin, sessionID: id)
        }
        store.save("existing server composer", server: server, sessionID: "durable-1")
        let reconstructed = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(reconstructed.reachableLocalDrafts(server: server, profile: "default").map(\.id), ["local-draft-a"])
        XCTAssertEqual(reconstructed.reachableLocalDrafts(server: server, profile: "work").map(\.id), ["local-draft-work"])
        XCTAssertEqual(reconstructed.reachableLocalDrafts(server: other, profile: "default").map(\.id), ["local-draft-other"])
        XCTAssertEqual(reconstructed.reachableLocalDrafts(server: sameHostOtherPort, profile: "default").map(\.id), ["local-draft-port"])
        XCTAssertTrue(reconstructed.reachableLocalDrafts(server: server, profile: "Work").isEmpty)
        XCTAssertEqual(reconstructed.load(server: server, sessionID: "durable-1"), "existing server composer")
    }

    func testLocalClearSendAndWhitespaceRemoveReachabilityWithoutLosingOtherDrafts() {
        for id in ["local-draft-clear", "local-draft-send", "local-draft-empty", "local-draft-keep"] {
            store.registerLocalDraft(SessionSummary(localDraftID: id, profile: "default"), server: server)
            store.save(id, server: server, sessionID: id)
        }
        store.clear(server: server, sessionID: "local-draft-clear")
        // ChatView's direct-send path saves an empty composer before awaiting.
        store.save("", server: server, sessionID: "local-draft-send")
        store.save(" \n\t", server: server, sessionID: "local-draft-empty")
        let reconstructed = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(reconstructed.reachableLocalDrafts(server: server, profile: "default").map(\.id), ["local-draft-keep"])
        for id in ["local-draft-clear", "local-draft-send", "local-draft-empty"] {
            XCTAssertEqual(reconstructed.load(server: server, sessionID: id), "")
        }
        XCTAssertEqual(reconstructed.load(server: server, sessionID: "local-draft-keep"), "local-draft-keep")
    }

    func testReopenedLocalDraftCanRestoreAfterDefiniteSendFailure() throws {
        let session = SessionSummary(localDraftID: "local-draft-a", profile: "default")
        store.registerLocalDraft(session, server: server)
        store.save("submitted", server: server, sessionID: session.id)
        let reconstructed = ComposerDraftStore(defaults: defaults)
        let reopened = try XCTUnwrap(reconstructed.reachableLocalDrafts(server: server, profile: "default").first)
        reconstructed.registerLocalDraft(reopened, server: server)
        reconstructed.save("", server: server, sessionID: reopened.id)
        XCTAssertTrue(reconstructed.reachableLocalDrafts(server: server, profile: "default").isEmpty)
        reconstructed.save("submitted", server: server, sessionID: reopened.id)
        let afterFailure = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(afterFailure.reachableLocalDrafts(server: server, profile: "default").map(\.id), [session.id])
        XCTAssertEqual(afterFailure.load(server: server, sessionID: session.id), "submitted")
    }

    func testSuccessfulFirstSendRekeysLaterComposerTextToCanonicalIdentityAcrossReconstruction() {
        let local = SessionSummary(localDraftID: "local-draft-consumed", profile: "default")
        let otherServer = URL(string: "https://other.example")!
        store.registerLocalDraft(local, server: server)
        store.registerLocalDraft(local, server: otherServer)
        store.save("submitted", server: server, sessionID: local.id)
        store.save("other origin text", server: otherServer, sessionID: local.id)
        store.save("", server: server, sessionID: local.id)
        store.save("typed while awaiting acceptance", server: server, sessionID: local.id)
        store.retireLocalDraft(server: server, sessionID: local.id, canonicalSessionID: "canonical-accepted")
        XCTAssertEqual(store.load(server: server, sessionID: "canonical-accepted"), "typed while awaiting acceptance")
        store.registerLocalDraft(local, server: server)
        store.save("next unsent message", server: server, sessionID: local.id)

        let restarted = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(restarted.load(server: server, sessionID: "canonical-accepted"), "next unsent message")
        XCTAssertEqual(restarted.load(server: server, sessionID: local.id), "")
        XCTAssertTrue(restarted.reachableLocalDrafts(server: server, profile: "default").isEmpty)
        XCTAssertEqual(restarted.load(server: otherServer, sessionID: local.id), "other origin text")
        XCTAssertEqual(restarted.reachableLocalDrafts(server: otherServer, profile: "default").map(\.id), [local.id])
    }

    func testProfileChoiceSaveMovesReachableScopeWithoutChangingLocalIdentity() {
        let original = SessionSummary(localDraftID: "local-draft-profile-choice", profile: "default")
        store.registerLocalDraft(original, server: server)
        store.save("unfinished", server: server, sessionID: original.id)
        store.registerLocalDraft(SessionSummary(localDraftID: original.id, profile: "work"), server: server)
        store.save("unfinished", server: server, sessionID: original.id)
        let restarted = ComposerDraftStore(defaults: defaults)
        XCTAssertTrue(restarted.reachableLocalDrafts(server: server, profile: "default").isEmpty)
        XCTAssertEqual(restarted.reachableLocalDrafts(server: server, profile: "work").map(\.id), [original.id])
        XCTAssertEqual(restarted.load(server: server, sessionID: original.id), "unfinished")
    }

    func testFailureNotificationDoesNotResurrectAnotherChatsPendingClear() throws {
        let a = SessionSummary(localDraftID: "local-draft-failure-a", profile: "work")
        let b = SessionSummary(localDraftID: "local-draft-clear-b", profile: "work")
        let wa = store.claimWriter(server: server, sessionID: a.id, owner: UUID())
        store.save("", configuration: a, server: server, sessionID: a.id, writer: wa)
        let checkpoint = try XCTUnwrap(store.submissionCheckpoint(server: server, sessionID: a.id, writer: wa))
        let wb = store.claimWriter(server: server, sessionID: b.id, owner: UUID())
        store.save("B draft before clear", configuration: b, server: server, sessionID: b.id, writer: wb)
        let before = store.failureRestorationRevision(server: server, sessionID: b.id)
        store.noteWriterEdit("", writer: wb, server: server, sessionID: b.id)
        XCTAssertTrue(store.restoreFailedSubmission("rejected A", checkpoint: checkpoint, server: server, sessionID: a.id))
        XCTAssertEqual(store.failureRestorationRevision(server: server, sessionID: b.id), before)
        XCTAssertNil(store.failureRestorationDraft(server: server, sessionID: b.id, writer: wb))
        XCTAssertEqual(store.load(server: server, sessionID: b.id), "B draft before clear", "The deliberate clear is still pending, reproducing the observer's exact unsafe window.")
        XCTAssertEqual(store.failureRestorationDraft(server: server, sessionID: a.id, writer: wa), "rejected A")
    }

    func testFailureNotificationCannotUndoLaterSameChatPendingClear() throws {
        let a = SessionSummary(localDraftID: "local-draft-later-clear", profile: "work")
        let writer = store.claimWriter(server: server, sessionID: a.id, owner: UUID())
        store.save("", configuration: a, server: server, sessionID: a.id, writer: writer)
        let checkpoint = try XCTUnwrap(store.submissionCheckpoint(server: server, sessionID: a.id, writer: writer))
        XCTAssertTrue(store.restoreFailedSubmission("rejected A", checkpoint: checkpoint, server: server, sessionID: a.id))
        store.noteWriterEdit("", writer: writer, server: server, sessionID: a.id)
        XCTAssertNil(store.failureRestorationDraft(server: server, sessionID: a.id, writer: writer))
        XCTAssertEqual(store.load(server: server, sessionID: a.id), "rejected A")
    }

    func testFailureNotificationIsIsolatedFromSameIDOnAnotherOrigin() throws {
        let id = "local-draft-origin"
        let other = URL(string: "https://other-origin.example")!
        let config = SessionSummary(localDraftID: id, profile: "work")
        let writer = store.claimWriter(server: server, sessionID: id, owner: UUID())
        store.save("", configuration: config, server: server, sessionID: id, writer: writer)
        let checkpoint = try XCTUnwrap(store.submissionCheckpoint(server: server, sessionID: id, writer: writer))
        let otherWriter = store.claimWriter(server: other, sessionID: id, owner: UUID())
        store.save("other origin text", configuration: config, server: other, sessionID: id, writer: otherWriter)
        XCTAssertTrue(store.restoreFailedSubmission("rejected A", checkpoint: checkpoint, server: server, sessionID: id))
        XCTAssertEqual(store.failureRestorationRevision(server: other, sessionID: id), 0)
        XCTAssertNil(store.failureRestorationDraft(server: other, sessionID: id, writer: otherWriter))
        XCTAssertEqual(store.load(server: other, sessionID: id), "other origin text")
    }

    func testDefiniteFailureRestoresUntouchedTextAcrossConfigurationOnlyRefresh() throws {
        let local = SessionSummary(localDraftID: "local-draft-loading-settings", profile: "work")
        let writer = store.claimWriter(server: server, sessionID: local.id, owner: UUID())
        store.save("", configuration: local, server: server, sessionID: local.id, writer: writer)
        let checkpoint = try XCTUnwrap(store.submissionCheckpoint(server: server, sessionID: local.id, writer: writer))
        let loaded = SessionSummary(localDraftID: local.id, workspace: "/latest workspace",
            model: "InheritedDefault", modelProvider: "inherited-provider", reasoningEffort: nil, profile: "work")
        XCTAssertTrue(store.save("", configuration: loaded, server: server, sessionID: local.id, writer: writer))
        let submitted = "  definitely rejected text 👩🏽‍💻\n"
        XCTAssertTrue(store.restoreFailedSubmission(submitted, checkpoint: checkpoint, server: server, sessionID: local.id))
        let restarted = ComposerDraftStore(defaults: defaults)
        let route = try XCTUnwrap(restarted.reachableLocalDrafts(server: server, profile: "work").first)
        XCTAssertEqual(restarted.load(server: server, sessionID: route.id), submitted)
        XCTAssertEqual(route.model, loaded.model)
        XCTAssertEqual(route.modelProvider, loaded.modelProvider)
        XCTAssertEqual(route.workspace, loaded.workspace)
        XCTAssertNil(route.reasoningEffort)
    }

    func testNewWriterPayloadAndLeaseSurviveOldFirstSendCompletionAndReconstruction() throws {
        let local = SessionSummary(localDraftID: "local-draft-pending", workspace: "/old",
            model: "old", modelProvider: "old-provider", reasoningEffort: "high", profile: "work")
        let old = store.claimWriter(server: server, sessionID: local.id, owner: UUID())
        store.save("submitted", configuration: local, server: server, sessionID: local.id, writer: old)
        store.save("", configuration: local, server: server, sessionID: local.id, writer: old)
        let checkpoint = try XCTUnwrap(store.submissionCheckpoint(server: server, sessionID: local.id, writer: old))
        store.releaseWriter(old, server: server, sessionID: local.id)
        let current = store.claimWriter(server: server, sessionID: local.id, owner: UUID())
        let changed = SessionSummary(localDraftID: local.id, workspace: "/new 👩🏽‍💻",
            model: "Vendor/Model:Exact", modelProvider: "Provider:Exact", reasoningEffort: nil, profile: "work")
        let pending = "  next message 👩🏽‍💻\n"
        XCTAssertTrue(store.save(pending, configuration: changed, server: server, sessionID: local.id, writer: current))

        // The accepted old send migrates the CURRENT owner, not its captured lease.
        store.retireLocalDraft(server: server, sessionID: local.id, canonicalSessionID: "Canonical:Exact-ID")
        XCTAssertFalse(store.save("stale text", configuration: local, server: server, sessionID: local.id, writer: old))
        store.releaseWriter(old, server: server, sessionID: local.id)
        XCTAssertTrue(store.ownsWriter(current, server: server, sessionID: local.id))
        XCTAssertTrue(store.ownsWriter(current, server: server, sessionID: "Canonical:Exact-ID"))
        XCTAssertFalse(store.restoreFailedSubmission("submitted", checkpoint: checkpoint, server: server, sessionID: local.id))
        // Repeated retirement and even a conflicting late callback cannot retarget identity.
        store.retireLocalDraft(server: server, sessionID: local.id, canonicalSessionID: "Wrong-ID")
        let restarted = ComposerDraftStore(defaults: defaults)
        XCTAssertTrue(restarted.reachableLocalDrafts(server: server, profile: "work").isEmpty)
        XCTAssertEqual(restarted.load(server: server, sessionID: "Canonical:Exact-ID"), pending)
        XCTAssertEqual(restarted.load(server: server, sessionID: "Wrong-ID"), "")
        defaults.removeObject(forKey: ComposerDraftStore.visibilityKeyPrefix + server.absoluteString + "|Canonical:Exact-ID")
        XCTAssertEqual(restarted.load(server: server, sessionID: "Canonical:Exact-ID"), pending,
            "Canonical text and configuration must reconstruct from one payload")
        let restored = try XCTUnwrap(restarted.savedConfiguration(server: server, sessionID: "Canonical:Exact-ID"))
        XCTAssertEqual(restored.sessionId, "Canonical:Exact-ID")
        XCTAssertEqual(restored.profile, "work")
        XCTAssertEqual(restored.model, changed.model)
        XCTAssertEqual(restored.modelProvider, changed.modelProvider)
        XCTAssertEqual(restored.workspace, changed.workspace)
        XCTAssertNil(restored.reasoningEffort, "Raw inherit must survive, independent of effective profile effort")
        // Pending debounce on the replacement view writes through the alias.
        XCTAssertTrue(store.save("later", configuration: changed, server: server, sessionID: local.id, writer: current))
        XCTAssertEqual(restarted.load(server: server, sessionID: "Canonical:Exact-ID"), "later")
    }

    func testOldDisappearanceCannotReleaseNewClaimBeforeOrAfterRetirement() {
        for retire in [false, true] {
            let id = retire ? "local-draft-retired-owner" : "local-draft-owner"
            let owner = UUID()
            let old = store.claimWriter(server: server, sessionID: id, owner: owner)
            let current = store.claimWriter(server: server, sessionID: id, owner: UUID())
            if retire { store.retireLocalDraft(server: server, sessionID: id, canonicalSessionID: "canonical-owner") }
            store.releaseWriter(old, server: server, sessionID: id)
            XCTAssertTrue(store.ownsWriter(current, server: server, sessionID: id))
            XCTAssertFalse(store.ownsWriter(old, server: server, sessionID: id))
            store.releaseWriter(current, server: server, sessionID: id)
            let reappeared = store.claimWriter(server: server, sessionID: id, owner: owner)
            XCTAssertNotEqual(reappeared, old, "The same view's new presentation must invalidate its old await")
        }
    }

    func testFailureRestoresUntouchedComposerAfterBackWithoutReclaimingWriter() throws {
        let local = SessionSummary(localDraftID: "local-draft-failure-owner", workspace: "/exact",
            model: "Exact", reasoningEffort: nil, profile: "work")
        let old = store.claimWriter(server: server, sessionID: local.id, owner: UUID())
        store.save("submitted", configuration: local, server: server, sessionID: local.id, writer: old)
        store.save("", configuration: local, server: server, sessionID: local.id, writer: old)
        let checkpoint = try XCTUnwrap(store.submissionCheckpoint(server: server, sessionID: local.id, writer: old))
        // A redundant debounce/disappearance flush must not invalidate restoration.
        store.noteWriterEdit("", writer: old, server: server, sessionID: local.id)
        store.save("", configuration: local, server: server, sessionID: local.id, writer: old)
        store.releaseWriter(old, server: server, sessionID: local.id)
        XCTAssertTrue(store.restoreFailedSubmission("submitted", checkpoint: checkpoint, server: server, sessionID: local.id))
        XCTAssertFalse(store.ownsWriter(old, server: server, sessionID: local.id))
        let restarted = ComposerDraftStore(defaults: defaults)
        let restored = try XCTUnwrap(restarted.reachableLocalDrafts(server: server, profile: "work").first)
        XCTAssertEqual(restored.id, local.id)
        XCTAssertEqual(restored.workspace, local.workspace)
        XCTAssertNil(restored.reasoningEffort)
        XCTAssertEqual(restarted.load(server: server, sessionID: local.id), "submitted")
    }

    func testFailureDoesNotEraseReplacementEditsEvenBeforeDebounceOrAfterUserClear() throws {
        for clearAfterTyping in [false, true] {
            let id = clearAfterTyping ? "local-draft-user-clear" : "local-draft-debounce"
            let local = SessionSummary(localDraftID: id, profile: "default")
            let old = store.claimWriter(server: server, sessionID: id, owner: UUID())
            store.save("", configuration: local, server: server, sessionID: id, writer: old)
            let checkpoint = try XCTUnwrap(store.submissionCheckpoint(server: server, sessionID: id, writer: old))
            let current = store.claimWriter(server: server, sessionID: id, owner: UUID())
            store.noteWriterEdit("new edit", writer: current, server: server, sessionID: id)
            if clearAfterTyping { store.noteWriterEdit("", writer: current, server: server, sessionID: id) }
            XCTAssertFalse(store.restoreFailedSubmission("submitted", checkpoint: checkpoint, server: server, sessionID: id))
            XCTAssertFalse(store.save("submitted", configuration: local, server: server, sessionID: id, writer: old))
            let latest = clearAfterTyping ? "" : "new edit"
            XCTAssertTrue(store.save(latest, configuration: local, server: server, sessionID: id, writer: current))
            XCTAssertEqual(ComposerDraftStore(defaults: defaults).load(server: server, sessionID: id), latest)
        }
    }

    func testCanonicalWriterClaimBeforeOldAcceptanceKeepsItsPayloadAndLease() throws {
        let local = SessionSummary(localDraftID: "local-draft-before-canonical", profile: "work")
        let old = store.claimWriter(server: server, sessionID: local.id, owner: UUID())
        store.save("old pending", configuration: local, server: server, sessionID: local.id, writer: old)
        let canonical = SessionSummary(sessionId: "Canonical:Existing", workspace: "/new", model: "New",
            modelProvider: "New-provider", reasoningEffort: nil, profile: "work")
        let current = store.claimWriter(server: server, sessionID: canonical.id, owner: UUID())
        store.save("canonical pending", configuration: canonical, server: server, sessionID: canonical.id, writer: current)
        store.retireLocalDraft(server: server, sessionID: local.id, canonicalSessionID: canonical.id)
        store.releaseWriter(old, server: server, sessionID: local.id)
        XCTAssertTrue(store.ownsWriter(current, server: server, sessionID: canonical.id))
        XCTAssertFalse(store.save("old", configuration: local, server: server, sessionID: local.id, writer: old))
        let restarted = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(restarted.load(server: server, sessionID: canonical.id), "canonical pending")
        XCTAssertEqual(restarted.savedConfiguration(server: server, sessionID: canonical.id)?.model, "New")
        XCTAssertNil(restarted.savedConfiguration(server: server, sessionID: canonical.id)?.reasoningEffort)
    }

    func testRetirementWithoutCanonicalIDCanLaterMigrateExactConfiguration() {
        let local = SessionSummary(localDraftID: "local-draft-late-identity", workspace: "/exact",
            model: "Exact", reasoningEffort: nil, profile: "work")
        let current = store.claimWriter(server: server, sessionID: local.id, owner: UUID())
        store.save("pending", configuration: local, server: server, sessionID: local.id, writer: current)
        store.retireLocalDraft(server: server, sessionID: local.id)
        store.retireLocalDraft(server: server, sessionID: local.id, canonicalSessionID: "Canonical:Late")
        let restarted = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(restarted.load(server: server, sessionID: "Canonical:Late"), "pending")
        XCTAssertEqual(restarted.savedConfiguration(server: server, sessionID: "Canonical:Late")?.workspace, "/exact")
        XCTAssertNil(restarted.savedConfiguration(server: server, sessionID: "Canonical:Late")?.reasoningEffort)
        XCTAssertTrue(store.ownsWriter(current, server: server, sessionID: "Canonical:Late"))
    }

    func testWriterOwnershipIsOriginAndConversationScoped() {
        let other = URL(string: "https://semreh.example:8443")!
        let first = store.claimWriter(server: server, sessionID: "local-draft-same", owner: UUID())
        let second = store.claimWriter(server: other, sessionID: "local-draft-same", owner: UUID())
        let third = store.claimWriter(server: server, sessionID: "local-draft-work", owner: UUID())
        XCTAssertTrue(store.ownsWriter(first, server: server, sessionID: "local-draft-same"))
        XCTAssertTrue(store.ownsWriter(second, server: other, sessionID: "local-draft-same"))
        XCTAssertTrue(store.ownsWriter(third, server: server, sessionID: "local-draft-work"))
        XCTAssertFalse(store.ownsWriter(first, server: other, sessionID: "local-draft-same"))
    }

    // These exercise the begin/settle seam called by ChatView's streaming path.
    // The interval between them models the suspended submission, without a backend.
    func testStreamingAcceptedUntouchedDraftClearsDurableText() throws {
        let session = SessionSummary(sessionId: "stream-accepted", model: "Exact", profile: "work")
        let writer = store.claimWriter(server: server, sessionID: session.id, owner: UUID())
        let text = "  submitted 👩🏽‍💻\n"
        let submission = try XCTUnwrap(store.beginStreamingSubmission(text, configuration: session,
            server: server, sessionID: session.id, writer: writer))
        XCTAssertEqual(ComposerDraftStore(defaults: defaults).load(server: server, sessionID: session.id), text,
            "The submitted composer must remain durable during the await")

        XCTAssertTrue(store.settleStreamingSubmission(submission, accepted: true, currentText: text,
            configuration: session, server: server, sessionID: session.id))
        XCTAssertEqual(store.load(server: server, sessionID: session.id), "")
        XCTAssertEqual(ComposerDraftStore(defaults: defaults).load(server: server, sessionID: session.id), "")
        XCTAssertEqual(store.savedConfiguration(server: server, sessionID: session.id)?.model, "Exact")
    }

    func testStreamingAcceptancePreservesDraftAfterUnobservedConfigurationRollback() throws {
        let session = SessionSummary(sessionId: "stream-config-rollback", profile: "default")
        let writer = store.claimWriter(server: server, sessionID: session.id, owner: UUID())
        let submission = try XCTUnwrap(store.beginStreamingSubmission("submitted", configuration: session,
            server: server, sessionID: session.id, writer: writer, configurationMutation: 7))
        // Optimistic edits can roll back to the same values before onChange.
        // The model-owned synchronous mutation token must still prevent clearing.
        XCTAssertFalse(store.settleStreamingSubmission(submission, accepted: true, currentText: "submitted",
            configuration: session, server: server, sessionID: session.id, configurationMutation: 8))
        XCTAssertEqual(ComposerDraftStore(defaults: defaults).load(server: server, sessionID: session.id), "submitted")
    }

    func testStreamingRejectionOrErrorPreservesSubmittedTextAcrossReconstruction() throws {
        // Rejection and caught transport errors both map to accepted == false.
        let session = SessionSummary(sessionId: "stream-rejected", profile: "default")
        let writer = store.claimWriter(server: server, sessionID: session.id, owner: UUID())
        let text = "unaccepted text"
        let submission = try XCTUnwrap(store.beginStreamingSubmission(text, configuration: session,
            server: server, sessionID: session.id, writer: writer))
        XCTAssertFalse(store.settleStreamingSubmission(submission, accepted: false, currentText: text,
            configuration: session, server: server, sessionID: session.id))
        XCTAssertEqual(ComposerDraftStore(defaults: defaults).load(server: server, sessionID: session.id), text)
    }

    func testStreamingDelayedAcceptanceOrRejectionPersistsPendingEditBeforeDebounce() throws {
        for accepted in [true, false] {
            let session = SessionSummary(sessionId: "stream-edit-\(accepted)", profile: "default")
            let writer = store.claimWriter(server: server, sessionID: session.id, owner: UUID())
            let submission = try XCTUnwrap(store.beginStreamingSubmission("submitted", configuration: session,
                server: server, sessionID: session.id, writer: writer))
            // Input has changed, but its 300 ms persistence task has not fired.
            store.noteWriterEdit("newer composer", writer: writer, server: server, sessionID: session.id)
            XCTAssertEqual(store.load(server: server, sessionID: session.id), "submitted")
            XCTAssertFalse(store.settleStreamingSubmission(submission, accepted: accepted,
                currentText: "newer composer", configuration: session, server: server, sessionID: session.id))
            XCTAssertEqual(ComposerDraftStore(defaults: defaults).load(server: server, sessionID: session.id),
                "newer composer")
        }
    }

    func testStreamingAcceptanceDetectsEditBeforeObservationCallback() throws {
        let session = SessionSummary(sessionId: "stream-unobserved-edit", profile: "default")
        let writer = store.claimWriter(server: server, sessionID: session.id, owner: UUID())
        let submission = try XCTUnwrap(store.beginStreamingSubmission("submitted", configuration: session,
            server: server, sessionID: session.id, writer: writer))
        XCTAssertFalse(store.settleStreamingSubmission(submission, accepted: true,
            currentText: "edited before observation", configuration: session, server: server, sessionID: session.id))
        XCTAssertEqual(store.load(server: server, sessionID: session.id), "edited before observation")
    }

    func testStreamingAcceptedClearAndRetypeOfIdenticalTextSurvives() throws {
        let session = SessionSummary(sessionId: "stream-retyped", profile: "default")
        let writer = store.claimWriter(server: server, sessionID: session.id, owner: UUID())
        let text = "same bytes"
        let submission = try XCTUnwrap(store.beginStreamingSubmission(text, configuration: session,
            server: server, sessionID: session.id, writer: writer))
        // Matches the synchronous composer binding, even within one render.
        store.noteWriterEdit("", writer: writer, server: server, sessionID: session.id)
        store.noteWriterEdit(text, writer: writer, server: server, sessionID: session.id)
        XCTAssertFalse(store.settleStreamingSubmission(submission, accepted: true, currentText: text,
            configuration: session, server: server, sessionID: session.id))
        XCTAssertEqual(ComposerDraftStore(defaults: defaults).load(server: server, sessionID: session.id), text)
    }

    func testStreamingOldWriterCannotSettleAfterBackAndReopen() throws {
        for accepted in [true, false] {
            for sameOwner in [true, false] {
                let session = SessionSummary(sessionId: "stream-reopen-\(accepted)-\(sameOwner)", profile: "default")
                let owner = UUID()
                let old = store.claimWriter(server: server, sessionID: session.id, owner: owner)
                let submission = try XCTUnwrap(store.beginStreamingSubmission("submitted", configuration: session,
                    server: server, sessionID: session.id, writer: old))
                store.releaseWriter(old, server: server, sessionID: session.id)
                let current = store.claimWriter(server: server, sessionID: session.id,
                    owner: sameOwner ? owner : UUID())
                // The unchanged text and revision still belong to a new lease.
                XCTAssertFalse(store.settleStreamingSubmission(submission, accepted: accepted,
                    currentText: "submitted", configuration: session, server: server, sessionID: session.id))
                XCTAssertTrue(store.ownsWriter(current, server: server, sessionID: session.id))
                store.save("replacement draft", configuration: session, server: server,
                    sessionID: session.id, writer: current)
                XCTAssertFalse(store.settleStreamingSubmission(submission, accepted: accepted,
                    currentText: "stale old view", configuration: session, server: server, sessionID: session.id))
                XCTAssertEqual(ComposerDraftStore(defaults: defaults).load(server: server, sessionID: session.id),
                    "replacement draft")
            }
        }
    }

    func testStreamingDispatchRequiresCurrentWriter() {
        let session = SessionSummary(sessionId: "stream-stale-dispatch", profile: "default")
        let old = store.claimWriter(server: server, sessionID: session.id, owner: UUID())
        let current = store.claimWriter(server: server, sessionID: session.id, owner: UUID())
        store.save("current", configuration: session, server: server, sessionID: session.id, writer: current)
        XCTAssertNil(store.beginStreamingSubmission("stale", configuration: session,
            server: server, sessionID: session.id, writer: old))
        XCTAssertEqual(store.load(server: server, sessionID: session.id), "current")
    }

    func testStreamingStaleCompletionCannotOverwriteReplacementPendingEdit() throws {
        for accepted in [true, false] {
            let session = SessionSummary(sessionId: "stream-pending-replacement-\(accepted)", profile: "default")
            let old = store.claimWriter(server: server, sessionID: session.id, owner: UUID())
            let submission = try XCTUnwrap(store.beginStreamingSubmission("submitted", configuration: session,
                server: server, sessionID: session.id, writer: old))
            store.releaseWriter(old, server: server, sessionID: session.id)
            let current = store.claimWriter(server: server, sessionID: session.id, owner: UUID())
            store.noteWriterEdit("replacement pending edit", writer: current, server: server, sessionID: session.id)
            XCTAssertFalse(store.settleStreamingSubmission(submission, accepted: accepted,
                currentText: "stale view text", configuration: session, server: server, sessionID: session.id))
            XCTAssertEqual(store.load(server: server, sessionID: session.id), "submitted",
                "An old completion must not flush its stale text while the new owner is awaiting debounce")
            XCTAssertTrue(store.save("replacement pending edit", configuration: session,
                server: server, sessionID: session.id, writer: current))
            XCTAssertEqual(ComposerDraftStore(defaults: defaults).load(server: server, sessionID: session.id),
                "replacement pending edit")
        }
    }

    func testStreamingAcceptedLocalDraftCannotResurrectFromIndexedPayload() throws {
        let session = SessionSummary(localDraftID: "local-draft-stream-accepted", model: "Exact", profile: "work")
        let writer = store.claimWriter(server: server, sessionID: session.id, owner: UUID())
        let submission = try XCTUnwrap(store.beginStreamingSubmission("submitted", configuration: session,
            server: server, sessionID: session.id, writer: writer))
        XCTAssertEqual(ComposerDraftStore(defaults: defaults).reachableLocalDrafts(server: server, profile: "work").count, 1)
        XCTAssertTrue(store.settleStreamingSubmission(submission, accepted: true, currentText: "submitted",
            configuration: session, server: server, sessionID: session.id))
        let restarted = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(restarted.load(server: server, sessionID: session.id), "")
        XCTAssertTrue(restarted.reachableLocalDrafts(server: server, profile: "work").isEmpty)
    }

    func testStreamingSettlementCannotCrossServerOrSession() throws {
        let session = SessionSummary(sessionId: "stream-scope", profile: "default")
        let otherSession = SessionSummary(sessionId: "stream-other", profile: "default")
        let otherServer = URL(string: "https://other.example")!
        let writer = store.claimWriter(server: server, sessionID: session.id, owner: UUID())
        let submission = try XCTUnwrap(store.beginStreamingSubmission("submitted", configuration: session,
            server: server, sessionID: session.id, writer: writer))
        let otherWriter = store.claimWriter(server: otherServer, sessionID: session.id, owner: UUID())
        let otherSessionWriter = store.claimWriter(server: server, sessionID: otherSession.id, owner: UUID())
        store.save("other server", configuration: session, server: otherServer, sessionID: session.id, writer: otherWriter)
        store.save("other session", configuration: otherSession, server: server,
            sessionID: otherSession.id, writer: otherSessionWriter)
        for accepted in [true, false] {
            XCTAssertFalse(store.settleStreamingSubmission(submission, accepted: accepted, currentText: "submitted",
                configuration: session, server: otherServer, sessionID: session.id))
            XCTAssertFalse(store.settleStreamingSubmission(submission, accepted: accepted, currentText: "submitted",
                configuration: otherSession, server: server, sessionID: otherSession.id))
        }
        XCTAssertTrue(store.settleStreamingSubmission(submission, accepted: true, currentText: "submitted",
            configuration: session, server: server, sessionID: session.id))
        let restarted = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(restarted.load(server: server, sessionID: session.id), "")
        XCTAssertEqual(restarted.load(server: otherServer, sessionID: session.id), "other server")
        XCTAssertEqual(restarted.load(server: server, sessionID: otherSession.id), "other session")
    }

    func testStreamingAcceptancePreservesChangedConfigurationAndSameText() throws {
        let original = SessionSummary(localDraftID: "local-draft-stream-config", workspace: "/old",
            model: "old", reasoningEffort: "high", profile: "default")
        let writer = store.claimWriter(server: server, sessionID: original.id, owner: UUID())
        let submission = try XCTUnwrap(store.beginStreamingSubmission("same text", configuration: original,
            server: server, sessionID: original.id, writer: writer))
        let changed = SessionSummary(localDraftID: original.id, workspace: "/new",
            model: "new", reasoningEffort: nil, profile: "work")
        store.noteWriterConfigurationEdit(writer: writer, server: server, sessionID: original.id)
        store.save("same text", configuration: changed, server: server, sessionID: original.id, writer: writer)
        XCTAssertFalse(store.settleStreamingSubmission(submission, accepted: true, currentText: "same text",
            configuration: changed, server: server, sessionID: original.id))
        let restarted = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(restarted.load(server: server, sessionID: original.id), "same text")
        let restored = try XCTUnwrap(restarted.savedConfiguration(server: server, sessionID: original.id))
        XCTAssertEqual(restored.workspace, "/new")
        XCTAssertEqual(restored.model, "new")
        XCTAssertEqual(restored.profile, "work")
        XCTAssertNil(restored.reasoningEffort)
        // Returning to the original options also must not make this await current.
        store.noteWriterConfigurationEdit(writer: writer, server: server, sessionID: original.id)
        store.save("same text", configuration: original, server: server, sessionID: original.id, writer: writer)
        XCTAssertFalse(store.settleStreamingSubmission(submission, accepted: true, currentText: "same text",
            configuration: original, server: server, sessionID: original.id))
    }

    func testRetiredSentLocalIdentityCannotReappearWhenComposerReceivesMoreText() {
        let session = SessionSummary(localDraftID: "local-draft-sent", profile: "default")
        let unrelated = SessionSummary(localDraftID: "local-draft-keep", profile: "default")
        for draft in [session, unrelated] {
            store.registerLocalDraft(draft, server: server)
            store.save("first message", server: server, sessionID: draft.id)
        }
        store.save("", server: server, sessionID: session.id)
        // Required integration seam: consume local identity on didStart == true,
        // not on the pre-await empty write (a definite failure must restore it).
        store.retireLocalDraft(server: server, sessionID: session.id)
        store.save("next composer text", server: server, sessionID: session.id)
        let reconstructed = ComposerDraftStore(defaults: defaults)
        XCTAssertEqual(reconstructed.reachableLocalDrafts(server: server, profile: "default").map(\.id), [unrelated.id])
        XCTAssertEqual(reconstructed.load(server: server, sessionID: session.id), "next composer text")
        XCTAssertEqual(reconstructed.load(server: server, sessionID: unrelated.id), "first message")
    }
}

@MainActor
final class TranscriptRestoreStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: TranscriptRestoreStore!
    private let server = URL(string: "https://semreh.example")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "TranscriptRestoreStoreTests.\(UUID().uuidString)")
        store = TranscriptRestoreStore(defaults: defaults)
    }

    override func tearDown() {
        store.resetForTesting()
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testLeaveWhileReadingOlderSurvivesAppRestart() {
        store.save(
            TranscriptRestorePoint(followingLatest: false, visibleMessageID: "msg-where-i-left"),
            server: server,
            sessionID: "session-a"
        )

        let relaunched = TranscriptRestoreStore(defaults: defaults)
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a"),
            TranscriptRestorePoint(followingLatest: false, visibleMessageID: "msg-where-i-left")
        )
    }

    func testFollowingLatestDoesNotKeepAStaleMessageID() {
        store.save(
            TranscriptRestorePoint(followingLatest: true, visibleMessageID: "msg-mid"),
            server: server,
            sessionID: "session-a"
        )

        XCTAssertEqual(
            ChatTranscriptRestorePolicy.target(
                wasFollowingLatest: store.load(server: server, sessionID: "session-a").followingLatest,
                lastVisibleMessageID: store.load(server: server, sessionID: "session-a").visibleMessageID
            ),
            .latest
        )
    }
}

#if DEBUG
@MainActor
final class ChatP09DiagnosticRestoreBootstrapTests: XCTestCase {
    func testCalibrationOneShotRejectsDuplicateAndWrongScopeRelease() {
        var state = ChatP09CalibrationState()
        let scope = UUID()
        XCTAssertFalse(state.finish(scope: scope, released: true))
        XCTAssertTrue(state.begin(scope: scope))
        XCTAssertFalse(state.begin(scope: scope))
        XCTAssertFalse(state.finish(scope: UUID(), released: true))
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertTrue(state.finish(scope: scope, released: true))
        XCTAssertEqual(state.phase, .released)
        XCTAssertFalse(state.finish(scope: scope, released: true))
        XCTAssertFalse(state.begin(scope: scope))
    }

    func testCalibrationTimeoutAndCancellationAbortRatherThanRelease() {
        for _ in ["timeout", "scope_or_user_cancellation"] {
            var state = ChatP09CalibrationState()
            let scope = UUID()
            XCTAssertTrue(state.begin(scope: scope))
            XCTAssertTrue(state.finish(scope: scope, released: false))
            XCTAssertEqual(state.phase, .aborted)
            XCTAssertFalse(state.finish(scope: scope, released: true))
            XCTAssertFalse(state.begin(scope: scope))
        }
    }

    func testCalibrationNonceRequiresExactSeedFixture() {
        let nonce = UUID().uuidString
        let key = "SEMREH_P09_CALIBRATION_NONCE"
        let arguments = ["--chat-p09-seed-restore",
                         "--chat-p09-restore-server=https://semreh-slice1-test.tailda8427.ts.net",
                         "--chat-p09-restore-session=p09-test", "--chat-p09-restore-message=123"]
        XCTAssertEqual(ChatP09CalibrationState.nonce(arguments: arguments, environment: [key: nonce]), nonce)
        let server = URL(string: "https://semreh-slice1-test.tailda8427.ts.net")!
        XCTAssertTrue(ChatP09CalibrationState.matchesFixture(arguments: arguments, server: server, sessionID: "p09-test"))
        XCTAssertFalse(ChatP09CalibrationState.matchesFixture(arguments: arguments, server: server, sessionID: "other-session"))
        XCTAssertFalse(ChatP09CalibrationState.matchesFixture(arguments: arguments, server: URL(string: "https://outside.example")!, sessionID: "p09-test"))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: [], environment: [key: nonce]))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: arguments, environment: [:]))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: arguments, environment: [key: "malformed"]))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: arguments.map { $0.replacingOccurrences(of: "semreh-slice1-test.tailda8427.ts.net", with: "outside.example") }, environment: [key: nonce]))
        XCTAssertNil(ChatP09CalibrationState.nonce(arguments: arguments.map { $0.replacingOccurrences(of: "--chat-p09-seed-restore", with: "--chat-p09-cleanup-restore") }, environment: [key: nonce]))
    }

    private var defaults: UserDefaults!
    private var suiteName: String!
    private let server = URL(string: "https://semreh-slice1-test.tailda8427.ts.net")!
    private let sessionID = "p09-session-123"
    private let oldMessageID = "old-message-456"
    private let seededMessageID = "seed-message-789"

    override func setUp() {
        super.setUp()
        suiteName = "ChatP09DiagnosticRestoreBootstrapTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testSeedRequestRequiresApprovedOriginAndCompleteCanonicalScope() {
        let valid = seedArguments()
        let request = ChatP09DiagnosticRestoreRequest.parse(arguments: valid)
        XCTAssertEqual(request?.operation, .seed)
        XCTAssertEqual(request?.server, server)
        XCTAssertEqual(request?.sessionID, sessionID)
        XCTAssertEqual(request?.visibleMessageID, seededMessageID)

        let invalidRequests: [[String]] = [
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)https://other.example",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(seededMessageID)"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)bad/session",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(seededMessageID)"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)bad/message"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(String(repeating: "x", count: 129))"],
            [ChatP09DiagnosticRestoreRequest.seedArgument,
             ChatP09DiagnosticRestoreRequest.cleanupArgument,
             "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
             "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
             "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(seededMessageID)"],
        ]

        for arguments in invalidRequests {
            XCTAssertNil(
                ChatP09DiagnosticRestoreRequest.parse(arguments: arguments),
                "out-of-scope P09 arguments must fail closed: \(arguments)"
            )
        }
    }

    func testSeedAndCleanupRestoreOnlyTheExactPriorReaderPoint() {
        let store = TranscriptRestoreStore(defaults: defaults)
        let unrelatedKey = "unrelated-setting"
        defaults.set("preserve-me", forKey: unrelatedKey)
        let prior = TranscriptRestorePoint(
            followingLatest: false,
            visibleMessageID: oldMessageID
        )
        store.save(prior, server: server, sessionID: sessionID)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .installed
        )
        XCTAssertEqual(
            store.load(server: server, sessionID: sessionID),
            TranscriptRestorePoint(
                followingLatest: false,
                visibleMessageID: "transcript:row:\(seededMessageID)"
            )
        )
        XCTAssertEqual(defaults.string(forKey: unrelatedKey), "preserve-me")
        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .rejected,
            "a second seed must not overwrite the saved backup"
        )

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(
                arguments: cleanupArguments(),
                defaults: defaults
            ),
            .restored
        )
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), prior)
        XCTAssertEqual(defaults.string(forKey: unrelatedKey), "preserve-me")
    }

    func testDirectTranscriptRenderIdentityUsesTheProductionNamespace() {
        XCTAssertEqual(
            TranscriptRenderIdentity.directID(for: seededMessageID),
            "transcript:row:\(seededMessageID)"
        )
        XCTAssertNil(TranscriptRenderIdentity.directID(for: nil))
        XCTAssertNil(TranscriptRenderIdentity.directID(for: ""))
    }

    func testCleanupWithoutMatchingSeedDoesNotWipeTheRestorePoint() {
        let store = TranscriptRestoreStore(defaults: defaults)
        let prior = TranscriptRestorePoint(
            followingLatest: false,
            visibleMessageID: oldMessageID
        )
        store.save(prior, server: server, sessionID: sessionID)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(
                arguments: cleanupArguments(),
                defaults: defaults
            ),
            .rejected
        )
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), prior)
    }

    func testSeedWithoutPriorPointCleansBackToLatestWithoutLeavingBackup() {
        let store = TranscriptRestoreStore(defaults: defaults)
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), .followingLatest)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .installed
        )
        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(
                arguments: cleanupArguments(),
                defaults: defaults
            ),
            .restored
        )
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), .followingLatest)
        XCTAssertFalse(
            defaults.dictionaryRepresentation().keys.contains {
                $0.contains("chatP09.restore-backup")
            }
        )
    }

    func testNonDataBackupRejectsSeedWithoutReplacingIt() {
        let store = TranscriptRestoreStore(defaults: defaults)
        let prior = TranscriptRestorePoint(
            followingLatest: false,
            visibleMessageID: oldMessageID
        )
        store.save(prior, server: server, sessionID: sessionID)
        defaults.set("not-a-data-backup", forKey: backupKey)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .rejected
        )
        XCTAssertEqual(store.load(server: server, sessionID: sessionID), prior)
        XCTAssertEqual(defaults.string(forKey: backupKey), "not-a-data-backup")
    }

    func testNonDataPriorRestoreRejectsSeedWithoutReplacingIt() {
        defaults.set("not-a-data-restore", forKey: restoreKey)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .rejected
        )
        XCTAssertEqual(defaults.string(forKey: restoreKey), "not-a-data-restore")
        XCTAssertNil(defaults.object(forKey: backupKey))
    }

    func testNonDataCleanupTargetRejectsWithoutOverwritingCurrentValue() {
        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(arguments: seedArguments(), defaults: defaults),
            .installed
        )
        defaults.set("later-corrupt-value", forKey: restoreKey)

        XCTAssertEqual(
            ChatP09DiagnosticRestoreBootstrap.apply(
                arguments: cleanupArguments(),
                defaults: defaults
            ),
            .rejected
        )
        XCTAssertEqual(defaults.string(forKey: restoreKey), "later-corrupt-value")
        XCTAssertNotNil(defaults.object(forKey: backupKey))
    }

    private func seedArguments() -> [String] {
        [
            ChatP09DiagnosticRestoreRequest.seedArgument,
            "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
            "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
            "\(ChatP09DiagnosticRestoreRequest.messageArgumentPrefix)\(seededMessageID)",
        ]
    }

    private func cleanupArguments() -> [String] {
        [
            ChatP09DiagnosticRestoreRequest.cleanupArgument,
            "\(ChatP09DiagnosticRestoreRequest.serverArgumentPrefix)\(server.absoluteString)",
            "\(ChatP09DiagnosticRestoreRequest.sessionArgumentPrefix)\(sessionID)",
        ]
    }

    private var restoreKey: String {
        "\(TranscriptRestoreStore.visibilityKeyPrefix)\(server.absoluteString)|\(sessionID)"
    }

    private var backupKey: String {
        "semreh.debug.chatP09.restore-backup.\(server.absoluteString)|\(sessionID)"
    }
}
#endif

@MainActor
final class LiveRunBookmarkStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: LiveRunBookmarkStore!
    private let server = URL(string: "https://semreh.example")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "LiveRunBookmarkStoreTests.\(UUID().uuidString)")
        store = LiveRunBookmarkStore(defaults: defaults)
    }

    override func tearDown() {
        store.resetForTesting()
        store = nil
        defaults = nil
        super.tearDown()
    }

    func testBookmarkSurvivesProcessDeath() {
        store.save(
            LiveRunBookmark(
                streamID: "stream-live",
                lastEventID: "42",
                liveReasoningText: "checking the lock",
                streamingAssistantMessageID: "msg-assistant",
                liveToolCalls: [
                    ToolCall(
                        id: "tool-1",
                        name: "read_file",
                        preview: "README.md",
                        args: nil,
                        isCompleted: false
                    )
                ]
            ),
            server: server,
            sessionID: "session-a"
        )

        let relaunched = LiveRunBookmarkStore(defaults: defaults)
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a")?.streamID,
            "stream-live"
        )
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a")?.liveReasoningText,
            "checking the lock"
        )
        XCTAssertEqual(
            relaunched.load(server: server, sessionID: "session-a")?.liveToolCalls.first?.name,
            "read_file"
        )
    }

    func testFinishedRunClearsTheBookmark() {
        store.save(
            LiveRunBookmark(
                streamID: "stream-live",
                lastEventID: nil,
                liveReasoningText: "done",
                streamingAssistantMessageID: nil
            ),
            server: server,
            sessionID: "session-a"
        )
        store.remove(server: server, sessionID: "session-a")
        XCTAssertNil(store.load(server: server, sessionID: "session-a"))
    }
}

@MainActor
private func makeComposerSizingView(_ text: String = "A short draft") -> UITextView {
    let view = ComposerTextView.PastingTextView(frame: CGRect(x: 0, y: 0, width: 280, height: 120))
    view.font = .systemFont(ofSize: 17)
    view.textContainerInset = .zero
    view.textContainer.lineFragmentPadding = 0
    view.isScrollEnabled = false
    view.text = text
    return view
}

@MainActor
private func makeComposerSizingCoordinator(onHeight: @escaping (CGFloat) -> Void = { _ in }) -> ComposerTextView.Coordinator {
    ComposerTextView.Coordinator(text: .constant(""), isFocused: .constant(false), onHeightChange: onHeight)
}

@MainActor
final class ComposerProposalSizingTests: XCTestCase {
    func testDocumentReplacementRetiresCompositionAndSelectionWithoutDismissingFocus() async throws {
        var draft = "First line\nSecond line "
        var heights: [CGFloat] = []
        let coordinator = ComposerTextView.Coordinator(
            text: Binding(get: { draft }, set: { draft = $0 }), isFocused: .constant(true),
            onHeightChange: { heights.append($0) })
        let editor = makeComposerSizingView(draft)
        editor.delegate = coordinator
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.addSubview(editor)
        defer { editor.resignFirstResponder(); window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        XCTAssertTrue(editor.becomeFirstResponder())
        editor.selectedRange = NSRange(location: draft.utf16.count, length: 0)
        editor.setMarkedText("漢字", selectedRange: NSRange(location: 1, length: 0))
        coordinator.textViewDidChange(editor)
        XCTAssertNotNil(editor.markedTextRange)
        // Ordinary bridge refreshes must leave the input method in control.
        XCTAssertFalse(coordinator.synchronizeExternalText(draft, in: editor))
        XCTAssertNotNil(editor.markedTextRange)
        draft = ""
        XCTAssertTrue(coordinator.synchronizeExternalText(draft, in: editor))
        coordinator.reportHeight(for: editor, force: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(draft, "", "UIKit callbacks must not resurrect a cleared draft")
        XCTAssertEqual(editor.text, "")
        XCTAssertNil(editor.markedTextRange)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.contentOffset, .zero)
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertFalse(editor.isScrollEnabled)
        XCTAssertEqual(heights.last, max(22, min(120, ComposerTextView.contentHeight(for: editor, width: 280))))
        let next = "cafe\u{301} 👩🏽‍💻 العربية"
        editor.insertText(next)
        coordinator.textViewDidChange(editor)
        XCTAssertEqual(Array(draft.utf8), Array(next.utf8))
        // A failed send/restored draft is exact and does not dismiss the keyboard.
        draft = "Restored\r\n" + next
        XCTAssertTrue(coordinator.synchronizeExternalText(draft, in: editor))
        XCTAssertEqual(Array(editor.text.utf8), Array(draft.utf8))
        XCTAssertTrue(editor.isFirstResponder)
    }

    func testMountedExternalClearKeepsKeyboardFocusAndNextDraftInput() async throws {
        var draft = "First line\nالعربية and cafe\u{301} "
        var focused = true
        var accessibilityHidden = false
        var focusWrites: [Bool] = []
        var reportedHeight: CGFloat = 0
        var pastedFiles = 0
        var keyboardSends = 0
        let makeInput = {
            ComposerTextView(
                text: Binding(get: { draft }, set: { draft = $0 }),
                isFocused: Binding(get: { focused }, set: { focused = $0; focusWrites.append($0) }),
                isDisabled: false, isAccessibilityHidden: accessibilityHidden,
                isKeyboardSendEnabled: true, onKeyboardSend: { keyboardSends += 1 },
                onHeightChange: { reportedHeight = $0 },
                onPasteFileProviders: { pastedFiles += $0.count }, onPasteFileURLs: { _ in },
                onPasteImageProviders: { _ in }, onPasteImages: { _ in }
            ).environment(\.layoutDirection, .rightToLeft)
        }
        let host = UIHostingController(rootView: makeInput())
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let container = UIViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        host.view.frame = CGRect(x: 0, y: 100, width: 280, height: 120)
        let previousPasteboard = UIPasteboard.general.items
        defer {
            UIPasteboard.general.items = previousPasteboard
            host.view.endEditing(true)
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        func refresh() async throws {
            host.rootView = makeInput()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
        }
        try await refresh()
        let original = try XCTUnwrap(findTextView(in: host.view) as? ComposerTextView.PastingTextView)
        XCTAssertTrue(original.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(350))
        let stableContainer = try XCTUnwrap(original.superview)
        let retiredCoordinator = original.delegate
        original.selectedRange = NSRange(location: draft.utf16.count, length: 0)
        original.setMarkedText("漢字", selectedRange: NSRange(location: 1, length: 0))
        original.delegate?.textViewDidChange?(original)
        XCTAssertNotNil(original.markedTextRange)
        try await refresh()
        XCTAssertTrue(findTextView(in: host.view) === original,
                      "An ordinary binding echo must keep the active input-method document")
        XCTAssertNotNil(original.markedTextRange)

        let keyboardHide = expectation(description: "External clear must not hide the keyboard")
        keyboardHide.isInverted = true
        let observer = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification,
            object: nil, queue: .main) { _ in keyboardHide.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }
        focusWrites.removeAll()
        draft = ""
        try await refresh()
        let editor = try XCTUnwrap(findTextView(in: host.view) as? ComposerTextView.PastingTextView)
        XCTAssertFalse(editor === original, "The completed input document must retire its native decoration owner")
        XCTAssertTrue(editor.superview === stableContainer)
        XCTAssertNil(original.superview)
        XCTAssertNil(original.delegate)
        XCTAssertTrue(editor.isFirstResponder && focused)
        XCTAssertFalse(focusWrites.contains(false), "Retiring the old document must not clear the new focus owner")
        XCTAssertEqual(editor.text, "")
        XCTAssertNil(editor.markedTextRange)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.contentOffset, .zero)
        XCTAssertEqual(editor.accessibilityIdentifier, "chat-composer-input")
        XCTAssertTrue(editor.isAccessibilityElement)
        XCTAssertEqual(stableContainer.subviews.compactMap { $0 as? UITextView }.count, 1)
        XCTAssertEqual(editor.semanticContentAttribute, .forceRightToLeft)
        XCTAssertEqual(editor.textAlignment, .right)
        XCTAssertEqual(editor.autocorrectionType, original.autocorrectionType)
        XCTAssertEqual(editor.spellCheckingType, original.spellCheckingType)
        XCTAssertNotEqual(editor.autocorrectionType, .no)
        XCTAssertNotEqual(editor.spellCheckingType, .no)
        XCTAssertFalse(editor.scrollsToTop)
        XCTAssertEqual(reportedHeight, max(22, min(120, ComposerTextView.contentHeight(for: editor, width: editor.bounds.width))))
        // A queued callback from the removed leaf must not resurrect the sent
        // draft, end focus, or report its old multiline geometry.
        retiredCoordinator?.textViewDidChange?(original)
        retiredCoordinator?.textViewDidEndEditing?(original)
        let currentHeight = reportedHeight
        (retiredCoordinator as? ComposerTextView.Coordinator)?.reportHeight(for: original, force: true)
        XCTAssertEqual(draft, "")
        XCTAssertTrue(focused)
        XCTAssertEqual(reportedHeight, currentHeight)
        try await refresh()
        XCTAssertTrue(findTextView(in: host.view) === editor, "An already empty external document must not churn editors")
        await fulfillment(of: [keyboardHide], timeout: 0.15)
        NotificationCenter.default.removeObserver(observer)

        let next = "cafe\u{301} 👩🏽‍💻 العربية\nsecond line"
        UIPasteboard.general.string = next
        editor.paste(nil)
        // UIKit may load paste providers asynchronously. Wait for the actual
        // document edit and its delegate-driven binding update before beginning
        // another composition; a manual callback here observes the old empty
        // document and lets the eventual paste interrupt the IME assertion.
        func pasteCompletedExactly() -> Bool {
            (editor.text ?? "").utf8.elementsEqual(next.utf8) && draft.utf8.elementsEqual(next.utf8)
        }
        let pasteDeadline = ProcessInfo.processInfo.systemUptime + 2
        while !pasteCompletedExactly(), ProcessInfo.processInfo.systemUptime < pasteDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(Array((editor.text ?? "").utf8), Array(next.utf8))
        XCTAssertEqual(Array(draft.utf8), Array(next.utf8))
        guard pasteCompletedExactly() else { return }
        editor.setMarkedText("漢字", selectedRange: NSRange(location: 1, length: 0))
        editor.delegate?.textViewDidChange?(editor)
        try await refresh()
        XCTAssertTrue(findTextView(in: host.view) === editor)
        XCTAssertNotNil(editor.markedTextRange, "The next draft must retain working IME composition")
        editor.unmarkText()
        draft += " dictated continuation"
        try await refresh()
        XCTAssertTrue(findTextView(in: host.view) === editor, "Voice/restored nonempty edits must keep the editor")
        XCTAssertEqual(Array(editor.text.utf8), Array(draft.utf8))
        XCTAssertTrue(editor.isFirstResponder)
        let file = NSItemProvider(item: Data("file:///tmp/composer-fixture.txt".utf8) as NSData,
                                  typeIdentifier: UTType.fileURL.identifier)
        editor.pasteItemProviders([file])
        XCTAssertEqual(pastedFiles, 1, "The new document must keep attachment paste routing")
        let sendCommand = try XCTUnwrap(editor.keyCommands?.first {
            $0.input == ComposerKeyboardCommand.input && $0.modifierFlags == ComposerKeyboardCommand.modifierFlags
        })
        let sendAction = try XCTUnwrap(sendCommand.action)
        XCTAssertTrue(UIApplication.shared.sendAction(sendAction, to: editor, from: nil, for: nil))
        XCTAssertEqual(keyboardSends, 1, "The replacement must retain the hardware keyboard Send callback")

        editor.selectedRange = NSRange(location: 0, length: editor.text.utf16.count)
        editor.deleteBackward()
        editor.delegate?.textViewDidChange?(editor)
        XCTAssertEqual(draft, "")
        try await refresh()
        XCTAssertTrue(findTextView(in: host.view) === editor,
                      "Deleting the draft through UIKit is not an external clear")

        draft = "A retained hidden-root draft"
        try await refresh()
        XCTAssertTrue(editor.isFirstResponder && focused)
        // Hide and clear together while the editor still owns focus. The input
        // itself must relinquish ownership even before the parent reconciles it.
        accessibilityHidden = true
        draft = ""
        try await refresh()
        let hiddenEditor = try XCTUnwrap(findTextView(in: host.view))
        XCTAssertFalse(hiddenEditor.isFirstResponder, "A hidden root's clear must not reactivate its keyboard")
        XCTAssertFalse(hiddenEditor.isAccessibilityElement)
        XCTAssertTrue(hiddenEditor.accessibilityElementsHidden)
        XCTAssertFalse(focused)
        accessibilityHidden = false
        try await refresh()
        XCTAssertTrue(findTextView(in: host.view) === hiddenEditor)
        XCTAssertFalse(hiddenEditor.isFirstResponder,
                       "Revealing a cleared retained root must not revive its discarded focus request")
        XCTAssertFalse(focused)
    }

    func testLongDraftHonorsProposedWidthAndCapsHeightAcrossRelayout() async throws {
        let draft = String(repeating: "Preserved draft with selectable words and wrapping. ", count: 100)
        var reportedHeight: CGFloat = 0
        let input = ComposerTextView(
            text: .constant(draft),
            isFocused: .constant(false),
            isDisabled: false,
            isKeyboardSendEnabled: false,
            onKeyboardSend: {},
            onHeightChange: { reportedHeight = $0 },
            onPasteFileProviders: { _ in },
            onPasteFileURLs: { _ in },
            onPasteImageProviders: { _ in },
            onPasteImages: { _ in }
        )
        let host = UIHostingController(rootView: input)
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let container = UIViewController()
        window.rootViewController = container
        window.makeKeyAndVisible()
        container.addChild(host)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        defer {
            host.willMove(toParent: nil)
            host.view.removeFromSuperview()
            host.removeFromParent()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        for width in [CGFloat(280), 160, 340] {
            host.view.frame = CGRect(x: 0, y: 100, width: width, height: 120)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let size = host.sizeThatFits(in: CGSize(width: width, height: 1_000))
            XCTAssertEqual(size.width, width, accuracy: 0.5, "A persisted draft must not expand the proposal")
            XCTAssertEqual(size.height, 120, accuracy: 0.5, "Long drafts must scroll within the existing height cap")
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let textView = try XCTUnwrap(findTextView(in: host.view))
            textView.setNeedsLayout()
            textView.layoutIfNeeded()
            XCTAssertEqual(textView.bounds.width, width, accuracy: 0.5)
            XCTAssertEqual(reportedHeight, size.height, accuracy: 0.5)
            XCTAssertTrue(textView.isScrollEnabled)
            XCTAssertFalse(textView.scrollsToTop, "The capped composer must not compete with transcript status-bar scrolling")
            XCTAssertTrue(textView.isSelectable)
            XCTAssertEqual(textView.text, draft)
        }
    }

    func testAlternatingWidthsMatchUIKitWithFewerMeasurementsAB() {
        let draft = String(repeating: "Unicode 👩🏽‍💻 العربية 漢字 e\u{301} wrapping ", count: 12)
        let widths: [CGFloat] = [160, 280, 160, 280, 160, 280]
        var rows = ["capacity,request,width,utf16_count,measurement_calls,height,UIKit_height"]
        defer {
            let attachment = XCTAttachment(string: rows.joined(separator: "\n"))
            attachment.name = "R53 actual UIKit calls and exact heights (not app latency)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for capacity in [1, 4] {
            let view = makeComposerSizingView(draft)
            let coordinator = ComposerTextView.Coordinator(text: .constant(""), isFocused: .constant(false),
                onHeightChange: { _ in }, measurementCacheCapacity: capacity)
            var calls = 0
            coordinator.measureContentHeight = { view, width in
                calls += 1
                return ComposerTextView.contentHeight(for: view, width: width)
            }
            let selection = view.selectedRange
            let focus = view.isFirstResponder
            for (request, width) in widths.enumerated() {
                let before = calls
                let actual = coordinator.contentHeight(for: view, width: width)
                let oracle = ComposerTextView.contentHeight(for: view, width: width)
                XCTAssertEqual(actual, oracle)
                XCTAssertLessThanOrEqual(coordinator.cachedMeasurementEntryCount, capacity)
                rows.append("\(capacity),\(request),\(width),\(draft.utf16.count),\(calls - before),\(actual),\(oracle)")
            }
            XCTAssertEqual(calls, capacity == 1 ? widths.count : 2)
            XCTAssertEqual(view.text, draft)
            XCTAssertEqual(view.selectedRange, selection)
            XCTAssertEqual(view.isFirstResponder, focus)
        }
    }

    func testProposalAndPostLayoutWidthsRetainBothMeasurements() {
        let view = makeComposerSizingView()
        var reports: [CGFloat] = []
        let coordinator = ComposerTextView.Coordinator(text: .constant(""), isFocused: .constant(false),
            onHeightChange: { reports.append($0) }, measurementCacheCapacity: 4)
        var calls = 0
        coordinator.measureContentHeight = { view, width in
            calls += 1
            return ComposerTextView.contentHeight(for: view, width: width)
        }
        for _ in 0..<6 {
            XCTAssertEqual(coordinator.contentHeight(for: view, width: 160),
                           ComposerTextView.contentHeight(for: view, width: 160))
            coordinator.reportHeight(for: view)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 2)
        XCTAssertEqual(reports, [min(120, max(22, ComposerTextView.contentHeight(for: view, width: 280)))])
    }

    func testMeasurementCachePressurePromotesHitsAndBoundsCapacity() {
        let view = makeComposerSizingView()
        let coordinator = ComposerTextView.Coordinator(text: .constant(""), isFocused: .constant(false),
            onHeightChange: { _ in }, measurementCacheCapacity: 4)
        var calls = 0
        coordinator.measureContentHeight = { view, width in
            calls += 1
            return ComposerTextView.contentHeight(for: view, width: width)
        }
        for width in [CGFloat(160), 180, 200, 220, 160, 240, 160] {
            XCTAssertEqual(coordinator.contentHeight(for: view, width: width),
                           ComposerTextView.contentHeight(for: view, width: width))
            XCTAssertLessThanOrEqual(coordinator.cachedMeasurementEntryCount, 4)
        }
        XCTAssertEqual(calls, 5, "A hit must promote 160 ahead of the evicted 180 entry")
        XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 4)
        XCTAssertEqual(coordinator.contentHeight(for: view, width: 180),
                       ComposerTextView.contentHeight(for: view, width: 180))
        XCTAssertEqual(calls, 6)
        XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 4)
    }

    func testViewChangeAndUnsupportedContentClearAllCachedEntries() {
        let first = makeComposerSizingView()
        let second = makeComposerSizingView()
        let coordinator = ComposerTextView.Coordinator(text: .constant(""), isFocused: .constant(false),
            onHeightChange: { _ in }, measurementCacheCapacity: 4)
        var calls = 0
        coordinator.measureContentHeight = { view, width in
            calls += 1
            return ComposerTextView.contentHeight(for: view, width: width)
        }
        for width in [CGFloat(160), 280] { _ = coordinator.contentHeight(for: first, width: width) }
        XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 2)
        _ = coordinator.contentHeight(for: second, width: 160)
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 1)
        _ = coordinator.contentHeight(for: first, width: 160)
        XCTAssertEqual(calls, 4)
        first.textStorage.addAttribute(.kern, value: 2, range: NSRange(location: 0, length: 1))
        for _ in 0..<2 {
            XCTAssertEqual(coordinator.contentHeight(for: first, width: 160),
                           ComposerTextView.contentHeight(for: first, width: 160))
            XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 0)
        }
        XCTAssertEqual(calls, 6)
        first.textStorage.removeAttribute(.kern, range: NSRange(location: 0, length: 1))
        _ = coordinator.contentHeight(for: first, width: 160)
        XCTAssertEqual(calls, 7, "Unsupported content must discard the previously supported entries")
        XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 1)
        first.setMarkedText("候補", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertNotNil(first.markedTextRange)
        _ = coordinator.contentHeight(for: first, width: 160)
        XCTAssertEqual(coordinator.cachedMeasurementEntryCount, 0)
        XCTAssertEqual(calls, 8)
        first.unmarkText()
    }

    private func findTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
    }
}

@MainActor
final class ComposerMeasurementReuseTests: XCTestCase {
    func testIdenticalProposalAndReportReuseRealMeasurement() {
        let view = makeComposerSizingView()
        var reports: [CGFloat] = []
        let coordinator = makeComposerSizingCoordinator { reports.append($0) }
        var operations = 0
        coordinator.measureContentHeight = { view, width in
            operations += 1
            return ComposerTextView.contentHeight(for: view, width: width)
        }
        let oracle = ComposerTextView.contentHeight(for: view, width: 280)
        let proposal = coordinator.contentHeight(for: view, width: 280)
        for _ in 0..<12 {
            XCTAssertEqual(coordinator.contentHeight(for: view, width: 280), oracle)
            coordinator.reportHeight(for: view)
        }
        XCTAssertEqual(proposal, oracle)
        XCTAssertEqual(operations, 1)
        XCTAssertEqual(reports, [min(120, max(22, oracle))])
    }

    func testSizingMutationsInvalidateWithoutChangingUIKitGeometry() {
        let view = makeComposerSizingView(String(repeating: "مرحبا 👩🏽‍💻 e\u{301} words ", count: 20))
        let coordinator = makeComposerSizingCoordinator()
        var operations = 0
        coordinator.measureContentHeight = { view, width in
            operations += 1
            return ComposerTextView.contentHeight(for: view, width: width)
        }
        _ = coordinator.contentHeight(for: view, width: view.bounds.width)
        let mutations: [(String, () -> Void)] = [
            ("programmatic replacement", { view.text = "Replacement\n" + view.text }),
            ("typing/paste", { view.insertText(" pasted 🧑‍🚀") }),
            ("width", { view.bounds.size.width = 160 }),
            ("same-size font", { view.font = .monospacedSystemFont(ofSize: 17, weight: .bold) }),
            ("paragraph style", {
                let style = NSMutableParagraphStyle()
                style.lineSpacing = 13
                view.textStorage.addAttribute(.paragraphStyle, value: style,
                    range: NSRange(location: 0, length: view.textStorage.length))
            }),
            ("insets", { view.textContainerInset.top = 11 }),
            ("padding", { view.textContainer.lineFragmentPadding = 9 }),
            ("RTL", { view.semanticContentAttribute = .forceRightToLeft; view.textAlignment = .right }),
            ("traits", {
                view.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
                view.updateTraitsIfNeeded()
                XCTAssertEqual(view.traitCollection.preferredContentSizeCategory, .accessibilityExtraExtraExtraLarge)
            }),
            ("line limit", { view.textContainer.maximumNumberOfLines = 3 }),
            ("line break", { view.textContainer.lineBreakMode = .byTruncatingTail })
        ]
        for (name, mutate) in mutations {
            mutate()
            let before = operations
            let actual = coordinator.contentHeight(for: view, width: view.bounds.width)
            XCTAssertEqual(operations, before + 1, name)
            XCTAssertEqual(actual, ComposerTextView.contentHeight(for: view, width: view.bounds.width), name)
        }
        // Unsupported runs and IME composition deliberately never reuse a result.
        view.textStorage.addAttribute(.kern, value: 2, range: NSRange(location: 0, length: 1))
        var before = operations
        for _ in 0..<2 { _ = coordinator.contentHeight(for: view, width: view.bounds.width) }
        XCTAssertEqual(operations, before + 2)
        view.text = "composition"
        view.setMarkedText("候補", selectedRange: NSRange(location: 0, length: 0))
        XCTAssertNotNil(view.markedTextRange)
        before = operations
        for _ in 0..<2 { _ = coordinator.contentHeight(for: view, width: view.bounds.width) }
        XCTAssertEqual(operations, before + 2)
        view.unmarkText()
    }

    func testIndependentViewLifetimesAndRestoredUnicodeDraftPreserveState() {
        let draft = String(repeating: "👨‍👩‍👧‍👦 مرحبا e\u{301} 漢字\n", count: 150)
        let coordinator = makeComposerSizingCoordinator()
        var operations = 0
        coordinator.measureContentHeight = { view, width in
            operations += 1
            return ComposerTextView.contentHeight(for: view, width: width)
        }
        weak var released: UITextView?
        do {
            let first = makeComposerSizingView(draft)
            released = first
            _ = coordinator.contentHeight(for: first, width: 280)
        }
        XCTAssertNil(released, "The cache must not retain a text view")
        let restored = makeComposerSizingView(draft)
        restored.selectedRange = NSRange(location: 4, length: 0)
        let selection = restored.selectedRange
        let focus = restored.isFirstResponder
        let before = operations
        let height = coordinator.contentHeight(for: restored, width: 280)
        XCTAssertEqual(operations, before + 1)
        XCTAssertEqual(height, ComposerTextView.contentHeight(for: restored, width: 280))
        var reported: CGFloat = 0
        coordinator.onHeightChange = { reported = $0 }
        coordinator.reportHeight(for: restored)
        XCTAssertEqual(reported, 120)
        XCTAssertTrue(restored.isScrollEnabled)
        XCTAssertEqual(restored.text, draft)
        XCTAssertEqual(restored.selectedRange, selection)
        XCTAssertEqual(restored.isFirstResponder, focus)
        let independent = makeComposerSizingCoordinator()
        var independentOperations = 0
        independent.measureContentHeight = { view, width in
            independentOperations += 1
            return ComposerTextView.contentHeight(for: view, width: width)
        }
        _ = independent.contentHeight(for: restored, width: 280)
        XCTAssertEqual(independentOperations, 1)
        restored.text = ""
        coordinator.reportHeight(for: restored)
        XCTAssertEqual(reported, max(22, min(120, ComposerTextView.contentHeight(for: restored, width: 280))))
        XCTAssertFalse(restored.isScrollEnabled)
    }

    func testBoundedSameProcessMeasurementABAttachment() {
        let draft = String(repeating: "Unicode 👩🏽‍💻 العربية 漢字 e\u{301} wrapping\n", count: 150)
        var rows = ["round,mode,iteration,duration_ns,measurement_count,height"]
        defer {
            let attachment = XCTAttachment(string: rows.joined(separator: "\n"))
            attachment.name = "R49 real UIKit measurement AB raw iterations (not UI FPS)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        for round in 0..<4 {
            for cached in (round.isMultiple(of: 2) ? [false, true] : [true, false]) {
                let view = makeComposerSizingView(draft)
                let coordinator = makeComposerSizingCoordinator()
                var operations = 0
                coordinator.measureContentHeight = { view, width in
                    operations += 1
                    return ComposerTextView.contentHeight(for: view, width: width)
                }
                let oracle = ComposerTextView.contentHeight(for: view, width: 280)
                for iteration in 0..<20 {
                    let before = operations
                    let start = DispatchTime.now().uptimeNanoseconds
                    let height: CGFloat
                    if cached {
                        height = coordinator.contentHeight(for: view, width: 280)
                    } else {
                        operations += 1
                        height = ComposerTextView.contentHeight(for: view, width: 280)
                    }
                    let duration = DispatchTime.now().uptimeNanoseconds - start
                    rows.append("\(round),\(cached ? "cached" : "uncached"),\(iteration),\(duration),\(operations - before),\(height)")
                    XCTAssertEqual(height, oracle)
                }
                XCTAssertEqual(operations, cached ? 1 : 20)
                XCTAssertEqual(view.text, draft)
            }
        }
    }
}
