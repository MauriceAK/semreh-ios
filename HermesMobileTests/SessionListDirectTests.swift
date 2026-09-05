import XCTest
@testable import HermesMobile

final class SessionListDirectTests: APIClientTestCase {
    @MainActor
    func testNewChatIsLocalDraftAndDoesNotIssueNetworkRequest() async throws {
        let client = makeClient { request in
            XCTFail("New Chat must not issue a request: \(request.url?.path ?? "nil")")
            throw URLError(.badURL)
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = SessionListViewModel(server: server, client: client)

        let firstDraft = await viewModel.createSession(profile: "work")
        let secondDraft = await viewModel.createSession(profile: "work")
        let first = try XCTUnwrap(firstDraft)
        let second = try XCTUnwrap(secondDraft)

        XCTAssertNil(first.sessionId)
        XCTAssertEqual(first.title, "New Chat")
        XCTAssertEqual(first.profile, "work")
        XCTAssertNotNil(first.createdAt)
        XCTAssertNotEqual(first.createdAt, second.createdAt)
        XCTAssertTrue(viewModel.sessions.isEmpty)
        XCTAssertFalse(viewModel.isCreatingSession)
    }

    @MainActor
    func testProfileSelectionLoadsOnlySelectedProfileFromDirectRoute() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles":
                return apiTestJSONResponse(
                    #"{"profiles":[{"name":"default","is_default":true},{"name":"work"}],"active":"default","single_profile_mode":false}"#,
                    for: request
                )
            case "/api/profiles/sessions":
                let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first(where: { $0.name == "profile" })?.value, "work")
                XCTAssertEqual(query?.first(where: { $0.name == "limit" })?.value, "500")
                XCTAssertEqual(query?.first(where: { $0.name == "offset" })?.value, "0")
                XCTAssertEqual(query?.first(where: { $0.name == "order" })?.value, "recent")
                return apiTestJSONResponse(
                    #"{"sessions":[{"id":"work-2","title":"Recent","cwd":"/tmp/work","started_at":20,"last_active":30,"profile":"work"},{"id":"work-1","title":"Older","started_at":10,"last_active":15,"profile":"work"}],"total":2,"limit":500,"offset":0,"profile_totals":{"work":2}}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request path: \(request.url?.path ?? "nil")")
                throw URLError(.badURL)
            }
        }
        let server = try XCTUnwrap(URL(string: "https://example.test"))
        let viewModel = SessionListViewModel(server: server, client: client)

        await viewModel.loadActiveProfile()
        let work = try XCTUnwrap(viewModel.profileOptions.first(where: { $0.name == "work" }))
        let didSwitch = await viewModel.switchActiveProfile(work)
        XCTAssertTrue(didSwitch)
        XCTAssertEqual(viewModel.activeProfileName, "work")
        let didLoad = await viewModel.load()
        XCTAssertTrue(didLoad)

        XCTAssertEqual(viewModel.sessions.compactMap(\.sessionId), ["work-2", "work-1"])
        XCTAssertTrue(viewModel.sessions.allSatisfy { $0.profile == "work" })
    }
}
