import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientAuthAndErrorTests: APIClientTestCase {
    func testOnboardingPasswordValidationOnlyRequiresKnownAuthEnabledPassword() {
        XCTAssertEqual(
            OnboardingViewModel.passwordValidationMessage(
                authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false),
                password: " \n "
            ),
            OnboardingViewModel.emptyPasswordMessage
        )
        XCTAssertNil(
            OnboardingViewModel.passwordValidationMessage(
                authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false),
                password: "secret"
            )
        )
        XCTAssertNil(
            OnboardingViewModel.passwordValidationMessage(
                authStatus: AuthStatusResponse(authEnabled: false, loggedIn: false),
                password: ""
            )
        )
        XCTAssertNil(OnboardingViewModel.passwordValidationMessage(authStatus: nil, password: ""))
    }

    @MainActor
    func testAuthManagerConnectsToNoPasswordHTTPSHostWithoutLogin() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: false, loggedIn: false))
        var requestedURLs: [URL] = []
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { url in
                requestedURLs.append(url)
                return client
            },
            serverRegistry: ServerRegistry.inMemory()
        )

        await manager.configure(serverURLString: "https://tailscale.example.test", password: "")

        let expectedURL = try XCTUnwrap(URL(string: "https://tailscale.example.test"))
        XCTAssertEqual(requestedURLs, [expectedURL])
        XCTAssertEqual(client.loginPasswords, [])
        XCTAssertEqual(client.protectedProbeCallCount, 1)
        XCTAssertEqual(keychain.savedValues[.serverURL], expectedURL.absoluteString)
        XCTAssertEqual(manager.state, .loggedIn(server: expectedURL))
        XCTAssertNil(manager.lastErrorMessage)
    }

    func testServerURLNormalizationDropsAccidentalWWWBeforeWebUISubdomain() throws {
        XCTAssertEqual(
            try AuthManager.normalizedServerURL(from: "https://www.webui.example.test"),
            URL(string: "https://webui.example.test")
        )
        XCTAssertEqual(
            try AuthManager.normalizedServerURL(from: "www.webui.example.test"),
            URL(string: "https://webui.example.test")
        )
        XCTAssertEqual(
            try AuthManager.normalizedServerURL(from: "https://www.example.com"),
            URL(string: "https://www.example.com")
        )
    }

    func testDirectOriginRequiresHTTPSDistinctRootHost() throws {
        XCTAssertNoThrow(try AuthManager.validateDirectHermesOrigin(URL(string: "https://hermes.example.test")!))
        XCTAssertThrowsError(try AuthManager.validateDirectHermesOrigin(URL(string: "http://100.96.12.34:9119")!))
        XCTAssertThrowsError(try AuthManager.validateDirectHermesOrigin(URL(string: "http://127.0.0.1:18791")!))
        XCTAssertNoThrow(try AuthManager.validateDirectHermesOrigin(URL(string: "http://127.0.0.1:18791")!, allowLoopbackHTTP: true))
        XCTAssertThrowsError(try AuthManager.validateDirectHermesOrigin(URL(string: "https://hermes.example.test:8443")!))
        XCTAssertThrowsError(try AuthManager.validateDirectHermesOrigin(URL(string: "https://user:pass@hermes.example.test")!))
        XCTAssertThrowsError(try AuthManager.validateDirectHermesInput("https://hermes.example.test/api?profile=default"))
        XCTAssertEqual(
            try AuthManager.normalizedServerURL(from: "https://HERmes.example.test.:443"),
            URL(string: "https://hermes.example.test")
        )
    }

    func testUsernameValidationOnlyAppliesWhenAuthIsRequired() {
        XCTAssertEqual(
            OnboardingViewModel.usernameValidationMessage(
                authStatus: AuthStatusResponse(authEnabled: true),
                username: " \n "
            ),
            OnboardingViewModel.emptyUsernameMessage
        )
        XCTAssertNil(
            OnboardingViewModel.usernameValidationMessage(
                authStatus: AuthStatusResponse(authEnabled: false),
                username: ""
            )
        )
    }

    @MainActor
    func testAuthManagerRejectsMissingAuthRequiredBeforePersisting() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(
            authStatus: AuthStatusResponse(authEnabled: false),
            directStatus: DirectHermesStatusResponse(
                version: nil,
                releaseDate: nil,
                authRequired: nil,
                authProviders: nil,
                authFlows: nil,
                overall: nil
            )
        )
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            serverRegistry: ServerRegistry.inMemory()
        )

        await manager.configure(serverURLString: "https://example.test", password: "")

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertNil(keychain.savedValues[.serverURL])
        XCTAssertEqual(client.protectedProbeCallCount, 0)
    }

    @MainActor
    func testAuthManagerRequiresUsernameBeforeDirectLogin() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true))
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            serverRegistry: ServerRegistry.inMemory()
        )

        await manager.configure(serverURLString: "https://example.test", username: " \n ", password: "secret")

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertEqual(manager.lastErrorMessage, OnboardingViewModel.emptyUsernameMessage)
        XCTAssertEqual(client.loginPasswords, [])
        XCTAssertEqual(client.protectedProbeCallCount, 0)
        XCTAssertNil(keychain.savedValues[.serverURL])
    }

    @MainActor
    func testAuthManagerRequiresProtectedProbeBeforePersisting() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(
            authStatus: AuthStatusResponse(authEnabled: false),
            protectedProbeError: DirectHermesRequestError.http(statusCode: 503, reason: .unavailable)
        )
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            serverRegistry: ServerRegistry.inMemory()
        )

        await manager.configure(serverURLString: "https://example.test", password: "")

        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertEqual(client.protectedProbeCallCount, 1)
        XCTAssertNil(keychain.savedValues[.serverURL])
    }

    @MainActor
    func testAuthManagerPreservesPasswordRequiredEmptyPasswordBehavior() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            serverRegistry: ServerRegistry.inMemory()
        )

        await manager.configure(serverURLString: "https://example.test", username: "test-user", password: "")

        XCTAssertEqual(client.loginPasswords, [])
        XCTAssertNil(keychain.savedValues[.serverURL])
        XCTAssertEqual(manager.state, .unconfigured)
        XCTAssertEqual(manager.lastErrorMessage, OnboardingViewModel.emptyPasswordMessage)
    }

    @MainActor
    func testAuthManagerLogsInWhenPasswordIsRequired() async throws {
        let keychain = InMemoryKeychainStore()
        let client = MockAuthAPIClient(authStatus: AuthStatusResponse(authEnabled: true, loggedIn: false))
        let manager = AuthManager(
            keychain: keychain,
            clientFactory: { _ in client },
            serverRegistry: ServerRegistry.inMemory()
        )

        await manager.configure(serverURLString: "https://example.test", username: "test-user", password: "secret")

        let expectedURL = try XCTUnwrap(URL(string: "https://example.test"))
        XCTAssertEqual(client.loginPasswords, ["secret"])
        XCTAssertEqual(client.loginUsernames, ["test-user"])
        XCTAssertEqual(keychain.savedValues[.serverURL], expectedURL.absoluteString)
        XCTAssertEqual(manager.state, .loggedIn(server: expectedURL))
        XCTAssertNil(manager.lastErrorMessage)
    }

    func testUnauthorizedResponseThrowsUnauthorized() async {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )
            return (try XCTUnwrap(response), Data())
        }

        do {
            _ = try await client.sessions()
            XCTFail("Expected unauthorized error")
        } catch APIError.unauthorized {
            // Expected path.
        } catch {
            XCTFail("Expected unauthorized error, got \(error)")
        }
    }

    func testVanishedSessionResponseUsesRecoveryMessage() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )
            let body = Data(#"{"error":"Session not found"}"#.utf8)
            return (try XCTUnwrap(response), body)
        }

        do {
            _ = try await client.session(id: "missing-session")
            XCTFail("Expected vanished-session HTTP error")
        } catch let APIError.http(statusCode, body) {
            XCTAssertEqual(statusCode, 404)
            XCTAssertEqual(body, #"{"error":"Session not found"}"#)
            XCTAssertEqual(
                APIError.http(statusCode: statusCode, body: body).localizedDescription,
                "That session no longer exists on the server. Reopen another session or create a new one."
            )
        } catch {
            XCTFail("Expected vanished-session HTTP error, got \(error)")
        }
    }

    func testCloudflareErrorDoesNotExposeRawHTMLBody() async throws {
        let client = makeClient { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 502,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )
            let body = Data("<html><title>Bad gateway</title><body>cloudflare</body></html>".utf8)
            return (try XCTUnwrap(response), body)
        }

        do {
            _ = try await client.sessions()
            XCTFail("Expected HTTP error")
        } catch let APIError.http(statusCode, body) {
            let message = APIError.http(statusCode: statusCode, body: body).localizedDescription
            XCTAssertEqual(
                message,
                "The server or Cloudflare tunnel is unavailable. Check that the Mac is awake, hermes-webui is running, and the tunnel is connected."
            )
            XCTAssertFalse(message.contains("<html>"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("bad gateway"))
        } catch {
            XCTFail("Expected HTTP error, got \(error)")
        }
    }

    func testHTTPErrorPrivacySafeLogCategoryDoesNotExposeServerBody() {
        let error = APIError.http(
            statusCode: 400,
            body: #"{"error":"password=secret prompt=private raw response"}"#
        )

        let category = error.privacySafeLogCategory

        XCTAssertEqual(category, "http.400")
        XCTAssertFalse(category.contains("secret"))
        XCTAssertFalse(category.contains("private"))
        XCTAssertFalse(category.contains("raw response"))
    }

    func testNetworkErrorPrivacySafeLogCategoryUsesOnlyURLCode() {
        let error = APIError.network(underlying: URLError(.timedOut))

        XCTAssertEqual(error.privacySafeLogCategory, "network.url.-1001")
    }

    func testNetworkTimeoutUsesSetupGuidance() async throws {
        let error = APIError.network(underlying: URLError(.timedOut))

        XCTAssertEqual(
            error.localizedDescription,
            "The server did not respond in time. Check that the Mac is awake, hermes-webui is running, and the tunnel is connected."
        )
    }

    func testAppTransportSecurityErrorUsesHTTPGuidance() async throws {
        let error = APIError.network(underlying: URLError(.appTransportSecurityRequiresSecureConnection))

        XCTAssertEqual(
            error.localizedDescription,
            "iOS blocked this insecure HTTP connection. Use HTTPS, or use a Tailscale IP in the 100.64.0.0/10 range."
        )
    }
}
