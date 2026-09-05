import Foundation
import XCTest
@testable import HermesMobile

final class DirectHermesAuthTests: APIClientTestCase {
    func testDirectRedirectGuardRefusesOffOriginCredentialBodyAndDowngrade() throws {
        let origin = try XCTUnwrap(URL(string: "https://example.test"))
        let guardDelegate = DirectHermesRedirectGuard(origin: origin)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: origin)
        for target in ["https://other.test/login", "http://example.test/login", "https://example.test:444/login", "https://example.test/login"] {
            let destination = try XCTUnwrap(URL(string: target))
            var request = URLRequest(url: destination)
            request.httpMethod = "POST"
            request.httpBody = Data("test-only-body".utf8)
            let response = try XCTUnwrap(HTTPURLResponse(url: origin, statusCode: 307, httpVersion: nil, headerFields: nil))
            var called = false
            var followed = false
            guardDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                called = true
                followed = $0 != nil
            }
            XCTAssertTrue(called)
            XCTAssertEqual(followed, target == "https://example.test/login")
        }
    }

    func testDirectProvidersUsesCanonicalRouteAndToleratesProviderFields() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/auth/providers")
            let body = Data(#"{"providers":[{"name":"basic","display_name":"Username & Password","supports_password":true,"future_field":"ignored"}]}"#.utf8)
            return (try XCTUnwrap(self.response(for: request, statusCode: 200)), body)
        }

        let response = try await client.directProviders()

        XCTAssertEqual(response.providers?.count, 1)
        XCTAssertEqual(response.providers?.first?.name, "basic")
        XCTAssertEqual(response.providers?.first?.supportsPassword, true)
    }

    func testDirectPasswordLoginSendsCapturedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/auth/password-login")
            let object = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: try XCTUnwrap(apiTestBodyData(from: request))) as? [String: Any]
            )
            XCTAssertTrue(object["provider"] as? String == "basic")
            XCTAssertTrue(object["username"] as? String == "test-user")
            XCTAssertTrue(object["password"] as? String == "test-password")
            XCTAssertTrue(object["next"] as? String == "")
            let body = Data(#"{"ok":true,"next":"/","future_field":true}"#.utf8)
            return (try XCTUnwrap(self.response(for: request, statusCode: 200)), body)
        }

        let response = try await client.directPasswordLogin(
            username: "test-user",
            password: "test-password"
        )

        XCTAssertTrue(response.ok == true)
        XCTAssertTrue(response.next == "/")
    }

    func testInvalidCredentials401RemainsHTTPErrorNotSessionExpiry() async throws {
        let client = makeClient { request in
            let body = Data(#"{"detail":"Invalid credentials"}"#.utf8)
            return (try XCTUnwrap(self.response(for: request, statusCode: 401)), body)
        }

        do {
            _ = try await client.directPasswordLogin(
                username: "test-user",
                password: "wrong-password"
            )
            XCTFail("Expected invalid-credentials HTTP error")
        } catch let DirectHermesRequestError.http(statusCode, reason) {
            XCTAssertEqual(statusCode, 401)
            XCTAssertEqual(reason, .invalidCredentials)
        } catch {
            XCTFail("Expected DirectHermesRequestError.http, got \(error)")
        }
    }

    func testDirectStatusDecodesCapturedFieldsAndIgnoresUnknownFields() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/status")
            let body = Data(#"{"version":"0.21.0","release_date":"2026.8.31","auth_required":true,"auth_providers":["basic"],"auth_flows":["cookie","native_pkce"],"overall":"degraded","future_field":{"ignored":true}}"#.utf8)
            return (try XCTUnwrap(self.response(for: request, statusCode: 200)), body)
        }

        let response = try await client.directStatus()

        XCTAssertEqual(response.version, "0.21.0")
        XCTAssertEqual(response.releaseDate, "2026.8.31")
        XCTAssertTrue(response.authRequired == true)
        XCTAssertEqual(response.authProviders, ["basic"])
        XCTAssertEqual(response.authFlows, ["cookie", "native_pkce"])
        XCTAssertEqual(response.overall, "degraded")
    }

    func testProtectedProbeClassifiesRecognizedUnauthenticated401() async throws {
        let client = makeClient { request in
            let body = Data(#"{"error":"unauthenticated","detail":"Unauthorized","reason":"no_cookie","login_url":"/login"}"#.utf8)
            return (try XCTUnwrap(self.response(for: request, statusCode: 401)), body)
        }

        do {
            try await client.directProtectedProbe()
            XCTFail("Expected structured session-expiry error")
        } catch DirectHermesAuthError.sessionExpired {
            // Expected path.
        } catch {
            XCTFail("Expected DirectHermesAuthError.sessionExpired, got \(error)")
        }
    }

    func testProtectedProbeClassifiesRecognizedSessionExpired401() async throws {
        let body = Data(#"{"error":"session_expired","detail":"Unauthorized","reason":"invalid_or_expired_session"}"#.utf8)
        XCTAssertTrue(
            DirectHermesAuthFailureClassifier.isSessionExpired(statusCode: 401, body: body)
        )
    }

    func testProtectedProbeAcceptsCapturedAuthenticatedSuccessBody() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/sessions")
            let body = Data(#"{"sessions":[],"total":0,"limit":20,"offset":0}"#.utf8)
            return (try XCTUnwrap(self.response(for: request, statusCode: 200)), body)
        }

        try await client.directProtectedProbe()
    }

    func testForbiddenAndUnavailableAreNotSessionExpiry() async throws {
        for (statusCode, body) in [
            (403, #"{"detail":"Forbidden"}"#),
            (503, #"{"detail":"Provider unavailable"}"#)
        ] {
            let client = makeClient { request in
                return (
                    try XCTUnwrap(self.response(for: request, statusCode: statusCode)),
                    Data(body.utf8)
                )
            }

            do {
                try await client.directProtectedProbe()
                XCTFail("Expected HTTP error")
            } catch let DirectHermesRequestError.http(actualStatus, reason) {
                XCTAssertEqual(actualStatus, statusCode)
                XCTAssertTrue(reason == .forbidden || reason == .unavailable)
            } catch {
                XCTFail("Expected DirectHermesRequestError.http, got \(error)")
            }
        }
    }

    func testGeneric401AndRateLimitRemainNonExpiryDirectErrors() async throws {
        let generic401Client = makeClient { request in
            let body = Data(#"{"detail":"Unauthorized"}"#.utf8)
            return (try XCTUnwrap(self.response(for: request, statusCode: 401)), body)
        }

        do {
            try await generic401Client.directProtectedProbe()
            XCTFail("Expected generic 401")
        } catch let DirectHermesRequestError.http(statusCode, reason) {
            XCTAssertEqual(statusCode, 401)
            XCTAssertEqual(reason, .unauthorized)
        } catch {
            XCTFail("Expected bounded direct HTTP error, got \(error)")
        }

        let rateLimitedClient = makeClient { request in
            let body = Data(#"{"detail":"Too many login attempts"}"#.utf8)
            return (try XCTUnwrap(self.response(for: request, statusCode: 429)), body)
        }

        do {
            _ = try await rateLimitedClient.directProviders()
            XCTFail("Expected rate-limit error")
        } catch let DirectHermesRequestError.http(statusCode, reason) {
            XCTAssertEqual(statusCode, 429)
            XCTAssertEqual(reason, .rateLimited)
            XCTAssertFalse(
                    DirectHermesAuthFailureClassifier.isSessionExpired(
                        statusCode: statusCode,
                        body: Data(#"{"detail":"Too many login attempts"}"#.utf8)
                    )
            )
        } catch {
            XCTFail("Expected bounded direct HTTP error, got \(error)")
        }
    }

    func testDirectWSTicketUsesProtectedRouteAndDecodesWithoutLoggingTicket() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/auth/ws-ticket")
            let body = Data(#"{"ticket":"opaque-test-ticket","ttl_seconds":30,"future_field":"ignored"}"#.utf8)
            return (try XCTUnwrap(self.response(for: request, statusCode: 200)), body)
        }

        let response = try await client.directWSTicket()

        XCTAssertTrue(response.ticket == "opaque-test-ticket")
        XCTAssertEqual(response.ttlSeconds, 30)
    }

    func testDirectLogoutAcceptsCapturedRedirect() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/auth/logout")
            let response = try XCTUnwrap(
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 302,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, Data())
        }

        try await client.directLogout()
    }

    private func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse? {
        HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.test")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )
    }

}
