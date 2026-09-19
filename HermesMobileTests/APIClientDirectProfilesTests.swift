import Foundation
import XCTest
@testable import HermesMobile

final class APIClientDirectProfilesTests: APIClientTestCase {
    @MainActor
    func testFreshProfileWithoutOverridesUsesStockInheritanceWithoutConfigWrite() async throws {
        var paths: [String] = []
        let client = makeClient { request in
            paths.append(request.url!.path)
            if request.url?.path == "/api/profiles/active" {
                return apiTestJSONResponse(#"{"active":"next-start","current":"running"}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/profiles")
            let body = try apiTestJSONBody(from: request) as? [String: AnyHashable]
            XCTAssertEqual(body, ["name": "work", "clone_all": false])
            return apiTestJSONResponse(#"{"ok":true,"name":"work","path":"/fixture/profiles/work","model_set":false}"#, for: request)
        }
        let workflow = DirectProfileCreationWorkflow()
        await workflow.create(client: client, name: "work", cloneConfig: false,
            model: nil, provider: nil, baseURL: nil, apiKey: nil)
        XCTAssertTrue(workflow.completed)
        XCTAssertFalse(workflow.modelAssignmentUnconfirmed)
        XCTAssertEqual(paths, ["/api/profiles/active", "/api/profiles"])
    }

    @MainActor
    func testCreateProfileUsesRunningCloneAndScopedEndpointConfiguration() async throws {
        var routes: [String] = []
        let client = makeClient { request in
            routes.append("\(request.httpMethod ?? "") \(request.url?.path ?? "")")
            switch request.url?.path {
            case "/api/profiles/active":
                return apiTestJSONResponse(#"{"active":"next-start","current":"running"}"#, for: request)
            case "/api/profiles":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(try apiTestJSONBody(from: request) as? [String: AnyHashable],
                    ["name": "new-work", "clone_from": "running", "clone_all": false, "provider": "custom", "model": "fixture-model"])
                return apiTestJSONResponse(#"{"ok":true,"name":"new-work","path":"/fixture/profiles/new-work","model_set":true}"#, for: request)
            case "/api/config":
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                    [URLQueryItem(name: "profile", value: "new-work")])
                let body = try apiTestJSONBody(from: request) as? [String: [String: [String: String]]]
                XCTAssertEqual(body, ["config": ["model": ["base_url": "https://endpoint.test/v1", "api_key": "fixture-key"]]])
                return apiTestJSONResponse(#"{"ok":true}"#, for: request)
            default: throw URLError(.badURL)
            }
        }
        let workflow = DirectProfileCreationWorkflow()
        await workflow.create(client: client, name: "new-work", cloneConfig: true,
            model: "fixture-model", provider: "custom", baseURL: "https://endpoint.test/v1", apiKey: "fixture-key")
        XCTAssertTrue(workflow.completed)
        XCTAssertEqual(workflow.created?.name, "new-work")
        XCTAssertEqual(routes, ["GET /api/profiles/active", "POST /api/profiles", "PUT /api/config"])
    }

    @MainActor
    func testPartialConfigurationRetryDoesNotRepeatCreateOrChangeCapturedInputs() async throws {
        var creates = 0
        var updates = 0
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/profiles/active":
                return apiTestJSONResponse(#"{"active":"other","current":"running"}"#, for: request)
            case "/api/profiles":
                creates += 1
                return apiTestJSONResponse(#"{"ok":true,"name":"work","path":"/fixture/profiles/work","model_set":false}"#, for: request)
            case "/api/config":
                updates += 1
                let body = try apiTestJSONBody(from: request) as? [String: [String: [String: String]]]
                XCTAssertEqual(body, ["config": ["model": ["api_key": "original-key"]]])
                if updates == 1 { throw URLError(.networkConnectionLost) }
                return apiTestJSONResponse(#"{"ok":true}"#, for: request)
            default: throw URLError(.badURL)
            }
        }
        let workflow = DirectProfileCreationWorkflow()
        await workflow.create(client: client, name: "work", cloneConfig: false,
            model: nil, provider: nil, baseURL: nil, apiKey: "original-key")
        XCTAssertEqual(workflow.created?.name, "work")
        XCTAssertFalse(workflow.completed)
        XCTAssertTrue(workflow.canRetryConfiguration)
        await workflow.create(client: client, name: "different", cloneConfig: false,
            model: nil, provider: nil, baseURL: nil, apiKey: "changed-key")
        await workflow.retryConfiguration(client: client)
        XCTAssertTrue(workflow.completed)
        XCTAssertEqual(creates, 1)
        XCTAssertEqual(updates, 2)
    }

    @MainActor
    func testUnconfirmedCreateNeverAutomaticallyRetriesOrConfiguresReceiptOtherIdentity() async throws {
        var creates = 0
        let client = makeClient { request in
            if request.url?.path == "/api/profiles/active" {
                return apiTestJSONResponse(#"{"current":"running"}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/profiles")
            creates += 1
            return apiTestJSONResponse(#"{"ok":true,"name":"other","path":"/fixture/profiles/other"}"#, for: request)
        }
        let workflow = DirectProfileCreationWorkflow()
        for _ in 0..<2 {
            await workflow.create(client: client, name: "work", cloneConfig: false,
                model: nil, provider: nil, baseURL: nil, apiKey: "fixture")
        }
        await workflow.retryConfiguration(client: client)
        XCTAssertTrue(workflow.creationUncertain)
        XCTAssertNil(workflow.created)
        XCTAssertEqual(creates, 1)
    }

    @MainActor
    func testBestEffortModelFailureStaysPartialWithoutUnsafeModelRepair() async throws {
        var routes: [String] = []
        let client = makeClient { request in
            routes.append(request.url!.path)
            if request.url?.path == "/api/profiles/active" {
                return apiTestJSONResponse(#"{"current":"running"}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/profiles")
            return apiTestJSONResponse(#"{"ok":true,"name":"work","path":"/fixture/profiles/work","model_set":false}"#, for: request)
        }
        let workflow = DirectProfileCreationWorkflow()
        await workflow.create(client: client, name: "work", cloneConfig: true,
            model: "new-model", provider: "custom", baseURL: nil, apiKey: nil)
        XCTAssertNotNil(workflow.created)
        XCTAssertFalse(workflow.completed)
        XCTAssertTrue(workflow.modelAssignmentUnconfirmed)
        XCTAssertFalse(workflow.canRetryConfiguration)
        await workflow.retryConfiguration(client: client)
        XCTAssertEqual(routes, ["/api/profiles/active", "/api/profiles"])
    }

    func testStartupDefaultWriteUsesStockPostAndDurableReadbackWithoutChangingCurrent() async throws {
        var methods: [String] = []
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/active")
            XCTAssertNil(request.url?.query)
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" {
                let body = try XCTUnwrap(apiTestJSONBody(from: request) as? [String: String])
                XCTAssertEqual(body, ["name": "work"])
                return apiTestJSONResponse(#"{"ok":true,"active":"work"}"#, for: request)
            }
            XCTAssertEqual(request.httpMethod, "GET")
            return apiTestJSONResponse(#"{"active":"work","current":"personal"}"#, for: request)
        }
        let result = try await client.directSetStartupDefaultProfile(name: " Work ")
        XCTAssertEqual(methods, ["POST", "GET"])
        XCTAssertEqual(result.startupDefaultName, "work")
        XCTAssertEqual(result.current, "personal")
    }

    func testStartupDefaultWriteRejectsMismatchedReadbackWithoutRetry() async throws {
        var methods: [String] = []
        let client = makeClient { request in
            methods.append(request.httpMethod ?? "")
            return apiTestJSONResponse(request.httpMethod == "POST"
                ? #"{"ok":true,"active":"work"}"#
                : #"{"active":"other","current":"personal"}"#, for: request)
        }
        do { _ = try await client.directSetStartupDefaultProfile(name: "work"); XCTFail("Readback must match") }
        catch DirectStartupDefaultWriteError.unconfirmed { }
        XCTAssertEqual(methods, ["POST", "GET"])
    }

    func testStartupDefaultWriteRejectsMissingOrConflictingAcknowledgement() async throws {
        for response in [#"{"active":"work"}"#, #"{"ok":false,"active":"work"}"#, #"{"ok":true,"active":"other"}"#] {
            var count = 0
            let client = makeClient { request in
                count += 1
                XCTAssertEqual(request.httpMethod, "POST")
                return apiTestJSONResponse(response, for: request)
            }
            do { _ = try await client.directSetStartupDefaultProfile(name: "work"); XCTFail("Unproven ACK") }
            catch DirectStartupDefaultWriteError.unconfirmed { }
            XCTAssertEqual(count, 1)
        }
    }

    func testStartupDefaultAcknowledgementDoesNotSucceedWhenReadbackFails() async throws {
        var methods: [String] = []
        let client = makeClient { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "POST" {
                return apiTestJSONResponse(#"{"ok":true,"active":"work"}"#, for: request)
            }
            throw URLError(.timedOut)
        }
        do { _ = try await client.directSetStartupDefaultProfile(name: "work"); XCTFail("ACK alone is insufficient") }
        catch { }
        XCTAssertEqual(methods, ["POST", "GET"])
    }

    func testStartupDefaultLostPostAcknowledgementIsNotRetried() async throws {
        var count = 0
        let client = makeClient { _ in
            count += 1
            throw URLError(.timedOut)
        }
        do { _ = try await client.directSetStartupDefaultProfile(name: "work"); XCTFail("Unconfirmed write") }
        catch { }
        XCTAssertEqual(count, 1)
    }

    func testStartupDefaultEmptyNameDoesNotDispatch() async throws {
        let client = makeClient { _ in
            XCTFail("Empty name must not dispatch")
            throw URLError(.badURL)
        }
        do { _ = try await client.directSetStartupDefaultProfile(name: " \n "); XCTFail("Expected invalid name") }
        catch DirectStartupDefaultWriteError.invalidName { }
    }
}
