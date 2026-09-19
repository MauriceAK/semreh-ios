import Foundation
import XCTest
@testable import HermesMobile

final class GatewayBlockingPromptModelTests: XCTestCase {
    func testApprovalEventDecodesExactChoices() throws {
        let identity = identity(requestID: "approval-1")
        let payload: JSONValue = .object([
            "request_id": .string("approval-1"),
            "command": .string("rm -i file"),
            "description": .string("A destructive command needs approval"),
            "pattern_key": .string("rm"),
            "pattern_keys": .array([.string("rm")]),
            "allow_session": .bool(true),
            "allow_permanent": .bool(true),
            "choices": .array([.string("once"), .string("session"), .string("always"), .string("deny")])
        ])

        let prompt = try GatewayApprovalPrompt.decode(payload: payload, identity: identity)
        XCTAssertEqual(prompt.choices, [.once, .session, .always, .deny])
        XCTAssertEqual(prompt.command, "rm -i file")
        XCTAssertEqual(prompt.patternKeys, ["rm"])
    }

    func testApprovalResumeSnapshotDerivesChoicesWithoutChoicesField() throws {
        let identity = identity(requestID: "approval-2")
        let payload: JSONValue = .object([
            "request_id": .string("approval-2"),
            "command": .string("python task.py"),
            "description": .string("Run task"),
            "pattern_key": .string("python"),
            "pattern_keys": .array([.string("python"), .string("workspace")]),
            "allow_session": .bool(true),
            "allow_permanent": .bool(false)
        ])

        let prompt = try GatewayApprovalPrompt.decode(payload: payload, identity: identity)
        XCTAssertEqual(prompt.choices, [.once, .session, .deny])
        XCTAssertFalse(prompt.allowPermanent)
    }

    func testApprovalElicitationDefaultsMissingScopeFlagsToEnabled() throws {
        let identity = identity(requestID: "approval-elicitation")
        let payload: JSONValue = .object([
            "request_id": .string("approval-elicitation"),
            "command": .string("perform action"),
            "description": .string("Confirm action"),
            "pattern_key": .string("elicitation"),
            "pattern_keys": .array([.string("elicitation")])
        ])

        let prompt = try GatewayApprovalPrompt.decode(payload: payload, identity: identity)
        XCTAssertTrue(prompt.allowSession)
        XCTAssertTrue(prompt.allowPermanent)
        XCTAssertEqual(prompt.choices, [.once, .session, .always, .deny])
    }

    func testSmartDeniedDerivesOnlyOnceAndDeny() throws {
        let identity = identity(requestID: "approval-smart")
        let payload: JSONValue = .object([
            "request_id": .string("approval-smart"),
            "command": .string("dangerous"),
            "description": .string("Owner override"),
            "pattern_key": .string("dangerous"),
            "pattern_keys": .array([.string("dangerous")]),
            "allow_session": .bool(true),
            "allow_permanent": .bool(true),
            "smart_denied": .bool(true)
        ])

        let prompt = try GatewayApprovalPrompt.decode(payload: payload, identity: identity)
        XCTAssertEqual(prompt.choices, [.once, .deny])
        XCTAssertTrue(prompt.smartDenied)
    }

    func testApprovalRejectsMalformedIDsAndUnsafeChoices() {
        let identity = identity(requestID: "approval-3")
        let base: [String: JSONValue] = [
            "request_id": .string("approval-3"),
            "command": .string("echo ok"),
            "description": .string("Run command"),
            "pattern_key": .string("echo"),
            "pattern_keys": .array([.string("echo")]),
            "allow_session": .bool(true),
            "allow_permanent": .bool(true)
        ]
        assertApprovalError(.object(base.merging(["request_id": .string("")]) { _, new in new }), identity: identity, expected: .malformedApproval)
        assertApprovalError(.object(base.merging(["request_id": .string("other")]) { _, new in new }), identity: identity, expected: .malformedApproval)
        assertApprovalError(.object(base.merging(["choices": .array([.string("always")])]) { _, new in new }), identity: identity, expected: .unsupportedApprovalChoice)
        assertApprovalError(.object(base.merging(["choices": .array([.string("once"), .string("session"), .string("always"), .string("execute")])]) { _, new in new }), identity: identity, expected: .unsupportedApprovalChoice)
        assertApprovalError(.object(base.merging(["pattern_keys": .array([.string("echo"), .number(1)])]) { _, new in new }), identity: identity, expected: .malformedApproval)
    }

    func testSecretDecodesMetadataAndUsesEmptyCancelValue() throws {
        let identity = identity(requestID: "secret-1")
        let prompt = try GatewaySecretPrompt.decode(payload: .object([
            "request_id": .string("secret-1"),
            "prompt": .string("API key"),
            "env_var": .string("API_KEY"),
            "metadata": .object(["provider": .string("fixture")])
        ]), identity: identity)
        XCTAssertEqual(prompt.prompt, "API key")
        XCTAssertEqual(prompt.environmentVariable, "API_KEY")
        XCTAssertEqual(prompt.cancelValue, "")
        XCTAssertTrue(prompt.isCancelOnly)
    }

    func testSecretRejectsMissingOrMismatchedFields() {
        let identity = identity(requestID: "secret-2")
        let missingEnvironment: JSONValue = .object([
            "request_id": .string("secret-2"),
            "prompt": .string("API key")
        ])
        do {
            _ = try GatewaySecretPrompt.decode(payload: missingEnvironment, identity: identity)
            XCTFail("Missing env_var must fail closed")
        } catch GatewayBlockingContractError.malformedSecret { }
        catch { XCTFail("Unexpected error: \(error)") }

        do {
            _ = try GatewaySecretPrompt.decode(payload: .object([
                "request_id": .string("other"),
                "prompt": .string("API key"),
                "env_var": .string("API_KEY")
            ]), identity: identity)
            XCTFail("Mismatched request ID must fail closed")
        } catch GatewayBlockingContractError.malformedSecret { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    func testSudoIsRequestIDOnlyAndCancelOnly() throws {
        let identity = identity(requestID: "sudo-1")
        let prompt = try GatewaySudoPrompt.decode(payload: .object([
            "request_id": .string("sudo-1"),
            "future_server_field": .string("ignored")
        ]), identity: identity)
        XCTAssertEqual(prompt.cancelValue, "")
        XCTAssertTrue(prompt.isCancelOnly)

        do {
            _ = try GatewaySudoPrompt.decode(payload: .object(["request_id": .string("")]), identity: identity)
            XCTFail("Empty request ID must fail closed")
        } catch GatewayBlockingContractError.malformedSudo { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    private func identity(requestID: String) -> GatewayBlockingPromptIdentity {
        GatewayBlockingPromptIdentity(
            origin: "https://fixture.example",
            profile: "default",
            storedID: "stored-1",
            runtimeID: "runtime-1",
            connectionGeneration: 3,
            requestID: requestID
        )
    }

    private func assertApprovalError(
        _ payload: JSONValue,
        identity: GatewayBlockingPromptIdentity,
        expected: GatewayBlockingContractError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            _ = try GatewayApprovalPrompt.decode(payload: payload, identity: identity)
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as GatewayBlockingContractError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
