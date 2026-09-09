import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientConfigurationTests: APIClientTestCase {
    func testDirectModelCatalogExplicitRefreshKeepsProfileAndCustomIdentity() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/model/options")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                [URLQueryItem(name: "profile", value: "work"), URLQueryItem(name: "explicit_only", value: "true"),
                 URLQueryItem(name: "refresh", value: "true")])
            return apiTestJSONResponse(#"{"model":"local-id","provider":"custom:studio","providers":[{"slug":"custom:studio","name":"Studio","authenticated":true,"models":["local-id"]}]}"#, for: request)
        }
        let result = try await client.directModelOptions(profile: "work", refresh: true)
        XCTAssertEqual(result.catalogGroups.first?.models.first?.providerID, "custom:studio")
        XCTAssertEqual(result.catalogGroups.first?.models.first?.id, "local-id")
    }

    func testDirectMainModelWritesExactProfileProviderAndVerifiesNormalizedReadback() async throws {
        var requests: [String] = []
        let client = makeClient { request in
            requests.append(request.httpMethod ?? "")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "profile" })?.value, "work & notes")
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/api/model/set")
                XCTAssertEqual(try apiTestJSONBody(from: request) as? [String: AnyHashable],
                    ["scope": "main", "provider": "custom:studio", "model": "requested",
                     "confirm_expensive_model": false])
                return apiTestJSONResponse(#"{"ok":true,"scope":"main","provider":"custom:studio","model":"normalized"}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/model/options")
            return apiTestJSONResponse(#"{"provider":"custom:studio","model":"normalized","providers":[]}"#, for: request)
        }
        let result = try await client.directSetMainModel(profile: "work & notes", provider: "custom:studio", model: "requested")
        guard case .confirmed(let model, let provider) = result else { return XCTFail("Expected verified selection") }
        XCTAssertEqual(model, "normalized")
        XCTAssertEqual(provider, "custom:studio")
        XCTAssertEqual(requests, ["POST", "GET"])
    }

    func testDirectMainModelConfirmationNeverAutomaticallyWritesAgain() async throws {
        var count = 0
        let client = makeClient { request in
            count += 1
            XCTAssertEqual(request.httpMethod, "POST")
            return apiTestJSONResponse(#"{"ok":false,"scope":"main","provider":"openai","model":"priced","confirm_required":true,"confirm_message":"Confirm cost"}"#, for: request)
        }
        let result = try await client.directSetMainModel(profile: "work", provider: "openai", model: "priced")
        guard case .confirmationRequired(let message) = result else { return XCTFail("Expected confirmation") }
        XCTAssertEqual(message, "Confirm cost")
        XCTAssertEqual(count, 1)
    }

    func testDirectMainModelExplicitConfirmationBodyAndReadback() async throws {
        let client = makeClient { request in
            if request.httpMethod == "POST" {
                let body = try apiTestJSONBody(from: request) as? [String: AnyHashable]
                XCTAssertEqual(body?["confirm_expensive_model"], true)
                return apiTestJSONResponse(#"{"ok":true,"scope":"main","provider":"openai","model":"priced"}"#, for: request)
            }
            return apiTestJSONResponse(#"{"provider":"openai","model":"priced"}"#, for: request)
        }
        let result = try await client.directSetMainModel(profile: "work", provider: "openai", model: "priced", confirmExpensive: true)
        guard case .confirmed = result else { return XCTFail("Expected confirmed readback") }
    }

    func testDirectMainModelWrongScopeProviderOrReadbackNeverConfirms() async throws {
        for acknowledgement in [
            #"{"ok":true,"scope":"auxiliary","provider":"custom:studio","model":"chosen"}"#,
            #"{"ok":true,"scope":"main","provider":"custom:other","model":"chosen"}"#,
            #"{"ok":true,"scope":"main","provider":"custom:studio","model":"chosen"}"#
        ] {
            var posts = 0
            let client = makeClient { request in
                if request.httpMethod == "POST" { posts += 1; return apiTestJSONResponse(acknowledgement, for: request) }
                return apiTestJSONResponse(#"{"provider":"custom:studio","model":"different"}"#, for: request)
            }
            do {
                _ = try await client.directSetMainModel(profile: "work", provider: "custom:studio", model: "chosen")
                XCTFail("Must not confirm mismatched state")
            } catch DirectMainModelError.unconfirmed {}
            XCTAssertEqual(posts, 1)
        }
    }

    func testProfileCreationCatalogReadsRunningProfileWithoutSwitchingStartupDefault() async throws {
        var paths: [String] = []
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            paths.append(request.url?.path ?? "")
            if request.url?.path == "/api/profiles/active" {
                return apiTestJSONResponse(#"{"active":"next-start","current":"running"}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/model/options")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first(where: { $0.name == "profile" })?.value, "running")
            XCTAssertEqual(query?.first(where: { $0.name == "explicit_only" })?.value, "true")
            return apiTestJSONResponse(#"{"providers":[{"slug":"custom","name":"Fixture","authenticated":true,"models":["same-model","same-model"]}]}"#, for: request)
        }
        let groups = try await ProfileCreationCatalog.load(client: client)
        XCTAssertEqual(paths, ["/api/profiles/active", "/api/model/options"])
        XCTAssertEqual(groups.first?.providerID, "custom")
        XCTAssertEqual(groups.first?.models.map(\.id), ["same-model"])
    }

    func testProfileCreationCatalogDoesNotSubstituteStartupDefaultWhenRunningProfileMissing() async throws {
        var requests = 0
        let client = makeClient { request in
            requests += 1
            XCTAssertEqual(request.url?.path, "/api/profiles/active")
            return apiTestJSONResponse(#"{"active":"next-start"}"#, for: request)
        }
        do {
            _ = try await ProfileCreationCatalog.load(client: client)
            XCTFail("Missing current profile must not switch catalog scope")
        } catch ProfileCreationCatalog.LoadError.missingRunningProfile { }
        XCTAssertEqual(requests, 1)
    }

    func testDirectProfilesDecodesStockRowsWithoutInventingActiveEnvelope() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/profiles")
            XCTAssertEqual(request.httpMethod, "GET")
            return apiTestJSONResponse("""
            {"profiles":[{"name":"default","is_default":true,"gateway_running":false},
                         {"name":"work","is_default":false,"model":"fixture","provider":"custom","skill_count":2}]}
            """, for: request)
        }
        let response = try await client.directProfiles()
        XCTAssertNil(response.active)
        XCTAssertNil(response.singleProfileMode)
        XCTAssertEqual(response.profiles?.first?.isDefault, true)
        XCTAssertNil(response.profiles?.first?.isActive)
        XCTAssertEqual(response.profiles?.last?.model, "fixture")
        XCTAssertEqual(response.profiles?.last?.skillCount, 2)
    }

    func testDirectActiveProfileKeepsStartupDefaultDistinctFromRunningProfile() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/profiles/active")
            XCTAssertEqual(request.httpMethod, "GET")
            return apiTestJSONResponse("{\"active\":\"work\",\"current\":\"default\"}", for: request)
        }
        let response = try await client.directActiveProfile()
        XCTAssertEqual(response.startupDefaultName, "work")
        XCTAssertEqual(response.current, "default")
    }

    func testDirectActiveProfileMissingDefaultDoesNotFallBackToRunningProfile() async throws {
        for payload in ["{\"current\":\"work\"}", "{\"active\":\"  \",\"current\":\"work\"}"] {
            let client = makeClient { apiTestJSONResponse(payload, for: $0) }
            let response = try await client.directActiveProfile()
            XCTAssertNil(response.startupDefaultName)
            XCTAssertEqual(response.current, "work")
        }
    }

    func testDirectProfileReadersClassifyStructuredAuthenticationExpiry() async throws {
        let client = makeClient { request in
            let response = try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401,
                                                        httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
            return (response, Data(#"{"error":"unauthenticated","detail":"Unauthorized"}"#.utf8))
        }
        do {
            _ = try await client.directProfiles()
            XCTFail("Expected expired authentication")
        } catch DirectHermesAuthError.sessionExpired { }
        do {
            _ = try await client.directActiveProfile()
            XCTFail("Expected expired authentication")
        } catch DirectHermesAuthError.sessionExpired { }
    }

    func testReasoningDisplayPrefersStructuredThinkingAndStripsVisibleAnswerEcho() {
        let finalAnswer = """
        **Terminal:** `/Users/hermes` directory listed.

        **Search files:** 5 `config.yaml` matches found.
        """
        let messages = [
            ChatMessage(
                role: "user",
                content: "Use terminal and search files",
                timestamp: 1_770_000_000,
                messageId: "user-tools"
            ),
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 1_770_000_001,
                messageId: "assistant-tools",
                contentParts: [
                    .object([
                        "type": .string("thinking"),
                        "text": .string("The user wants me to use terminal and search_files. I should run a quick command.")
                    ]),
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-terminal"),
                        "name": .string("terminal"),
                        "input": .object(["command": .string("ls -la")])
                    ]),
                    .object([
                        "type": .string("tool_use"),
                        "id": .string("toolu-search"),
                        "name": .string("search_files"),
                        "input": .object(["pattern": .string("config.yaml")])
                    ])
                ],
                reasoning: "Terminal works. Now run search_files to show that works too."
            ),
            ChatMessage(
                role: "user",
                content: nil,
                timestamp: 1_770_000_002,
                messageId: "tool-results",
                contentParts: [
                    .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu-terminal"),
                        "content": .string("81 entries")
                    ]),
                    .object([
                        "type": .string("tool_result"),
                        "tool_use_id": .string("toolu-search"),
                        "content": .string("5 matches")
                    ])
                ]
            ),
            ChatMessage(
                role: "assistant",
                content: nil,
                timestamp: 1_770_000_003,
                messageId: "assistant-post-tools",
                reasoning: "Terminal works. Now run search_files to show that works too."
            ),
            ChatMessage(
                role: "assistant",
                content: finalAnswer,
                timestamp: 1_770_000_004,
                messageId: "assistant-final",
                reasoning: """
                The user wants me to use terminal and search_files. I should run a quick command.
                Terminal works. Now run search_files to show that works too.
                Both tools worked. I should give a concise summary.

                \(finalAnswer)
                """
            )
        ]

        let reasoningGroups = ChatViewModel.reasoningDisplayGroups(messages: messages, archivedGroups: [])
        let transcriptMessages = ChatViewModel.transcriptMessages(from: messages)

        XCTAssertEqual(reasoningGroups.map(\.anchorMessageID), ["assistant-final"])
        XCTAssertTrue(reasoningGroups[0].text.contains("The user wants me to use terminal and search_files. I should run a quick command."))
        XCTAssertTrue(reasoningGroups[0].text.contains("Terminal works. Now run search_files to show that works too."))
        XCTAssertTrue(reasoningGroups[0].text.contains("Both tools worked. I should give a concise summary."))
        XCTAssertFalse(reasoningGroups[0].text.contains("**Terminal:**"))
        XCTAssertFalse(transcriptMessages.contains { $0.message.id == "tool-results" })
    }

    func testReasoningStatusNormalizesSupportedEfforts() throws {
        let json = """
        {
          "reasoning_effort": "low",
          "supported_efforts": [" Low ", "low", "", "HIGH"],
          "supports_reasoning_effort": false
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ReasoningStatusResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.normalizedSupportedEfforts, ["low", "high"])
        XCTAssertEqual(response.supportsReasoningEffort, false)
    }

    func testReasoningStatusDecodesSessionOverrideSeparatelyFromEffectiveEffort() throws {
        let json = """
        {
          "reasoning_effort": "high",
          "session_reasoning_effort": "max",
          "session_scoped_reasoning": true
        }
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(ReasoningStatusResponse.self, from: Data(json.utf8))

        XCTAssertEqual(response.effectiveEffort, "high")
        XCTAssertEqual(response.sessionReasoningEffort, "max")
        XCTAssertEqual(response.sessionScopedReasoning, true)
    }

    func testPersonalitiesBuildsExpectedPathAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/personalities")
            XCTAssertEqual(request.httpMethod, "GET")

            return apiTestJSONResponse("""
            {
              "personalities": [
                {
                  "name": "mentor",
                  "description": "Patient technical coach",
                  "extra": "ignored"
                },
                {
                  "name": "critic"
                }
              ]
            }
            """, for: request)
        }

        let response = try await client.personalities()

        XCTAssertEqual(response.personalities?.count, 2)
        XCTAssertEqual(response.personalities?.first?.name, "mentor")
        XCTAssertEqual(response.personalities?.first?.description, "Patient technical coach")
        XCTAssertEqual(response.personalities?.last?.description, nil)
    }

    func testSetPersonalityBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/personality/set")
            XCTAssertEqual(request.httpMethod, "POST")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["session_id"] as? String, "session-abc")
            XCTAssertEqual(body?["name"] as? String, "mentor")
            XCTAssertNil(body?["sessionId"])

            return apiTestJSONResponse("""
            {
              "ok": true,
              "personality": "mentor",
              "prompt": "Be direct."
            }
            """, for: request)
        }

        let response = try await client.setPersonality(sessionID: "session-abc", name: "mentor")

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.personality, "mentor")
        XCTAssertEqual(response.prompt, "Be direct.")
    }

    func testClearPersonalitySendsEmptyName() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/personality/set")

            let data = try XCTUnwrap(apiTestBodyData(from: request))
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["session_id"] as? String, "session-abc")
            XCTAssertEqual(body?["name"] as? String, "")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "personality": null
            }
            """, for: request)
        }

        let response = try await client.setPersonality(sessionID: "session-abc", name: "")

        XCTAssertEqual(response.ok, true)
        XCTAssertNil(response.personality)
    }

    func testProfilesResponseToleratesAbsentSingleProfileMode() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(
            ProfilesResponse.self,
            from: Data(#"{"active": "default", "profiles": []}"#.utf8)
        )

        XCTAssertNil(response.singleProfileMode)
    }

    func testProfilesResponseEffectiveDefaultPrefersActiveName() {
        let response = ProfilesResponse(
            profiles: [
                ProfileSummary(
                    name: "default",
                    path: nil,
                    isDefault: true,
                    isActive: false,
                    gatewayRunning: nil,
                    model: "gpt-5.4",
                    provider: "openai",
                    hasEnv: nil,
                    skillCount: nil
                ),
                ProfileSummary(
                    name: "work",
                    path: nil,
                    isDefault: false,
                    isActive: true,
                    gatewayRunning: nil,
                    model: "gpt-5.5",
                    provider: "anthropic",
                    hasEnv: nil,
                    skillCount: 8
                )
            ],
            active: " work "
        )

        XCTAssertEqual(response.effectiveDefaultProfileName, "work")
        XCTAssertEqual(response.displayName(for: "work"), "work")
    }

    func testProfilesResponseEffectiveDefaultFallsBackToFlags() {
        let activeFlagResponse = ProfilesResponse(
            profiles: [
                ProfileSummary(
                    name: "personal",
                    path: nil,
                    isDefault: false,
                    isActive: true,
                    gatewayRunning: nil,
                    model: nil,
                    provider: nil,
                    hasEnv: nil,
                    skillCount: nil
                )
            ],
            active: nil
        )
        XCTAssertEqual(activeFlagResponse.effectiveDefaultProfileName, "personal")

        let defaultFlagResponse = ProfilesResponse(
            profiles: [
                ProfileSummary(
                    name: "default",
                    path: nil,
                    isDefault: true,
                    isActive: false,
                    gatewayRunning: nil,
                    model: nil,
                    provider: nil,
                    hasEnv: nil,
                    skillCount: nil
                )
            ],
            active: ""
        )
        XCTAssertEqual(defaultFlagResponse.effectiveDefaultProfileName, "default")
        XCTAssertEqual(defaultFlagResponse.displayName(for: "default"), "Default")
    }

    func testProfileBaseURLRuleMirrorsUpstream() {
        XCTAssertTrue(ProfileNameRules.isValidBaseURL("http://localhost:11434"))
        XCTAssertTrue(ProfileNameRules.isValidBaseURL("https://api.example.com/v1"))
        XCTAssertFalse(ProfileNameRules.isValidBaseURL("localhost:11434"))
        XCTAssertFalse(ProfileNameRules.isValidBaseURL("ftp://example.com"))
        XCTAssertFalse(ProfileNameRules.isValidBaseURL(""))
    }

    func testProfilePickerCancellationErrorDetection() {
        XCTAssertTrue(DefaultProfilePickerView.isCancellationError(CancellationError()))
        XCTAssertTrue(DefaultProfilePickerView.isCancellationError(URLError(.cancelled)))
        XCTAssertTrue(DefaultProfilePickerView.isCancellationError(APIError.network(underlying: URLError(.cancelled))))
        XCTAssertFalse(DefaultProfilePickerView.isCancellationError(URLError(.timedOut)))
        XCTAssertFalse(DefaultProfilePickerView.isCancellationError(APIError.unauthorized))
    }

    func testProfileNameRulesMirrorUpstreamPattern() {
        XCTAssertTrue(ProfileNameRules.isValid("work"))
        XCTAssertTrue(ProfileNameRules.isValid("a"))
        XCTAssertTrue(ProfileNameRules.isValid("9lives"))
        XCTAssertTrue(ProfileNameRules.isValid("team-2_dev"))
        XCTAssertTrue(ProfileNameRules.isValid(String(repeating: "a", count: 64)))

        XCTAssertFalse(ProfileNameRules.isValid(""))
        XCTAssertFalse(ProfileNameRules.isValid("-lead"))
        XCTAssertFalse(ProfileNameRules.isValid("_x"))
        XCTAssertFalse(ProfileNameRules.isValid("Work"))
        XCTAssertFalse(ProfileNameRules.isValid("a b"))
        XCTAssertFalse(ProfileNameRules.isValid("über"))
        XCTAssertFalse(ProfileNameRules.isValid("name!"))
        XCTAssertFalse(ProfileNameRules.isValid(String(repeating: "a", count: 65)))
    }

    func testReasoningOptionsIncludeForwardCompatibleMaxLevel() {
        let options = ReasoningEffortOption.options(forSupportedEfforts: ["low", "max"])

        XCTAssertEqual(options.map(\.id), ["low", "max"])
        XCTAssertEqual(ReasoningEffortOption.title(for: "max"), "Max")
    }
}
