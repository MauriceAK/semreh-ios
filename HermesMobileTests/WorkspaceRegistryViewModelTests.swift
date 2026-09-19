import XCTest
@testable import HermesMobile

@MainActor
final class WorkspaceRegistryViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: LocalOrganizerStore { LocalOrganizerStore(defaults: defaults) }
    private var suiteName: String!
    private let server = URL(string: "https://fixture.example")!

    override func setUp() {
        super.setUp()
        suiteName = "WorkspaceRegistryViewModelTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    @MainActor
    func testLoadUsesOnlyMatchingServerAndProfileBookmarks() async throws {
        try store.addWorkspaceBookmark(path: "/work/default", name: "Default", server: server, profile: "default")
        try store.addWorkspaceBookmark(path: "/work/team", name: "Team", server: server, profile: "team")
        try store.addWorkspaceBookmark(path: "/other", name: nil, server: URL(string: "https://other.example")!, profile: "default")
        let model = WorkspaceRegistryViewModel(server: server, profile: "default", store: store)

        await model.load()

        XCTAssertEqual(model.rows, [WorkspaceRoot(path: "/work/default", name: "Default")])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testAddRenameAndSuggestionsRemainDeviceLocal() async throws {
        let model = WorkspaceRegistryViewModel(server: server, profile: "default", store: store)

        let added = await model.addWorkspace(path: " /work/alpha ", name: " Alpha ")
        let renamed = await model.renameWorkspace(path: "/work/alpha", to: "Renamed")

        XCTAssertTrue(added)
        XCTAssertTrue(renamed)
        XCTAssertEqual(model.rows, [WorkspaceRoot(path: "/work/alpha", name: "Renamed")])
        let suggestions = await model.loadSuggestions(prefix: "ALP")
        XCTAssertEqual(suggestions, ["/work/alpha"])
        XCTAssertTrue(model.didMutateRegistry)
    }

    @MainActor
    func testRemovalRequiresExplicitConfirmation() async throws {
        try store.addWorkspaceBookmark(path: "/work/alpha", name: nil, server: server, profile: "default")
        let model = WorkspaceRegistryViewModel(server: server, profile: "default", store: store)
        await model.load()
        let row = try XCTUnwrap(model.rows.first)

        model.requestRemoval(of: row)
        model.cancelPendingRemoval()
        XCTAssertEqual(try store.workspaceBookmarks(server: server, profile: "default").map(\.path), ["/work/alpha"])

        let removed = await model.confirmRemoval(of: row)
        XCTAssertTrue(removed)
        XCTAssertTrue(model.rows.isEmpty)
    }

    @MainActor
    func testMovePersistsBookmarkOrder() async throws {
        try store.addWorkspaceBookmark(path: "/work/a", name: nil, server: server, profile: "default")
        try store.addWorkspaceBookmark(path: "/work/b", name: nil, server: server, profile: "default")
        let model = WorkspaceRegistryViewModel(server: server, profile: "default", store: store)
        await model.load()

        let moved = await model.moveWorkspaces(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertTrue(moved)
        XCTAssertEqual(model.rows.compactMap(\.path), ["/work/b", "/work/a"])
        XCTAssertEqual(try store.workspaceBookmarks(server: server, profile: "default").map(\.path), ["/work/b", "/work/a"])
    }

    @MainActor
    func testCorruptStoreSurfacesErrorAndRemainsUntouched() async throws {
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: "localOrganizer.v1")
        let model = WorkspaceRegistryViewModel(server: server, profile: "default", store: store)

        await model.load()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.rows.isEmpty)
        let added = await model.addWorkspace(path: "/work/new", name: nil)
        XCTAssertFalse(added)
        XCTAssertEqual(defaults.data(forKey: "localOrganizer.v1"), corrupt)
    }
}
