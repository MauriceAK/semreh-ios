import XCTest
@testable import HermesMobile

@MainActor
final class LocalOrganizerStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private let server = URL(string: "https://Example.TEST/")!

    override func setUp() {
        super.setUp()
        suiteName = "LocalOrganizerStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testGroupsAssignmentsAndBookmarksPersistAcrossStoreInstancesAndScopes() throws {
        let first = LocalOrganizerStore(defaults: defaults)
        let group = try first.createGroup(name: "Work", color: "#123456", server: server, profile: " default ")
        try first.assignSession("session-1", toGroup: group.projectId, server: server, profile: "default")
        try first.addWorkspaceBookmark(path: "/repo", name: "Repo", server: server, profile: "default")

        let second = LocalOrganizerStore(defaults: defaults)
        let snapshot = try second.snapshot(server: URL(string: "https://example.test")!, profile: "default")
        XCTAssertTrue(group.projectId?.hasPrefix("local-group-") == true)
        XCTAssertEqual(snapshot.groups.map(\.name), ["Work"])
        XCTAssertEqual(snapshot.sessionAssignments, ["session-1": group.projectId!])
        XCTAssertEqual(snapshot.workspaceBookmarks, [.init(path: "/repo", name: "Repo")])
        XCTAssertTrue(try second.groups(server: server, profile: "other").isEmpty)
        XCTAssertTrue(try second.groups(server: URL(string: "https://other.test")!, profile: "default").isEmpty)
    }

    func testMoveUnassignDeleteAndIdentityTransferStayWithinScope() throws {
        let store = LocalOrganizerStore(defaults: defaults)
        let first = try store.createGroup(name: "One", color: nil, server: server, profile: "work")
        let second = try store.createGroup(name: "Two", color: nil, server: server, profile: "work")
        try store.assignSession("old", toGroup: first.projectId, server: server, profile: "work")
        try store.assignSession("old", toGroup: second.projectId, server: server, profile: "work")
        try store.transferSessionAssignment(from: "old", to: "tip", server: server, profile: "work")
        XCTAssertEqual(try store.groupID(forSession: "old", server: server, profile: "work"), second.projectId)
        XCTAssertEqual(try store.groupID(forSession: "tip", server: server, profile: "work"), second.projectId)
        try store.deleteGroup(id: second.projectId!, server: server, profile: "work")
        XCTAssertNil(try store.groupID(forSession: "tip", server: server, profile: "work"))
        XCTAssertEqual(try store.groups(server: server, profile: "work").map(\.projectId), [first.projectId])
    }

    func testMalformedAndUnknownVersionDataRemainUntouchedAndUnwritable() throws {
        for bytes in [Data("not-json".utf8), Data(#"{"version":2,"scopes":{}}"#.utf8)] {
            defaults.set(bytes, forKey: "localOrganizer.v1")
            let store = LocalOrganizerStore(defaults: defaults)
            XCTAssertThrowsError(try store.groups(server: server, profile: "default"))
            XCTAssertThrowsError(try store.createGroup(name: "No", color: nil, server: server, profile: "default"))
            XCTAssertEqual(defaults.data(forKey: "localOrganizer.v1"), bytes)
        }
    }

    func testGroupReplacementAndRemovalPreserveEveryOtherSummaryField() {
        let original = metadataSummary()
        XCTAssertEqual(original.withLocalOrganizerGroupID("new-group"), metadataSummary(groupID: "new-group"))
        XCTAssertEqual(original.withLocalOrganizerGroupID(nil), metadataSummary(groupID: nil))
        XCTAssertEqual(original, metadataSummary(), "Copying must not mutate the source value")
    }

    func testListMetadataReplacementPreservesEveryOtherSummaryField() {
        let original = metadataSummary()
        XCTAssertEqual(
            original.replacingListMetadata(title: "Renamed", pinned: false, archived: true),
            metadataSummary(title: "Renamed", pinned: false, archived: true)
        )
        XCTAssertEqual(original, metadataSummary())
    }

    func testListMetadataNilExplicitlyClearsOnlyRequestedFields() {
        XCTAssertEqual(
            metadataSummary().replacingListMetadata(title: nil, pinned: nil, archived: nil),
            metadataSummary(title: nil, pinned: nil, archived: nil)
        )
        let empty = SessionSummary()
        XCTAssertEqual(empty.withLocalOrganizerGroupID(nil), empty)
        XCTAssertEqual(empty.replacingListMetadata(title: nil, pinned: nil, archived: nil), empty)
    }

    private func metadataSummary(
        title: String? = "Original",
        pinned: Bool? = true,
        archived: Bool? = false,
        groupID: String? = "local-group"
    ) -> SessionSummary {
        SessionSummary(
            sessionId: "session", title: title, workspace: "/workspace", model: "model",
            modelProvider: "provider", reasoningEffort: "high", messageCount: 7,
            createdAt: 101, updatedAt: 102, lastMessageAt: 103,
            pinned: pinned, archived: archived, projectId: groupID, profile: "work",
            inputTokens: 104, outputTokens: 105, estimatedCost: 0.106,
            activeStreamId: "stream", isStreaming: true, isCliSession: false,
            userMessageCount: 3, hasPendingUserMessage: true, pendingStartedAt: 107,
            worktreePath: "/worktree", sourceTag: "tag", rawSource: "raw",
            sessionSource: "source", sourceLabel: "label", parentSessionId: "parent",
            relationshipType: "fork", readOnly: false, isReadOnly: true, matchType: "content"
        )
    }
}
