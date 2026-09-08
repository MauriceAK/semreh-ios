import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientAgentControlTests: APIClientTestCase {
    func testApprovalPendingDecodesSingularPatternKeyWhenPatternKeysMissing() throws {
        let response = try JSONDecoder().decode(
            ApprovalPendingResponse.self,
            from: Data("""
            {
              "pending": {
                "approval_id": "approval-2",
                "command": "python script.py",
                "description": "Run Python",
                "pattern_key": "python_exec"
              },
              "pending_count": 1,
              "ignored": true
            }
            """.utf8)
        )

        XCTAssertEqual(response.pending?.displayPatternKeys, ["python_exec"])
        XCTAssertEqual(response.pendingCount, 1)
    }

    func testPendingApprovalDecodesServerIdentifierAliases() throws {
        let decoder = JSONDecoder()

        let snake = try decoder.decode(
            PendingApproval.self,
            from: Data(#"{"approval_id":"approval-snake","command":"make install"}"#.utf8)
        )
        let camel = try decoder.decode(
            PendingApproval.self,
            from: Data(#"{"approvalId":"approval-camel","command":"make install"}"#.utf8)
        )
        let gatewayID = try decoder.decode(
            PendingApproval.self,
            from: Data(#"{"approval_id":"   ","id":"approval-gateway","command":"make install"}"#.utf8)
        )

        XCTAssertEqual(snake.approvalId, "approval-snake")
        XCTAssertEqual(camel.approvalId, "approval-camel")
        XCTAssertEqual(gatewayID.approvalId, "approval-gateway")
        XCTAssertEqual(gatewayID.id, "approval-gateway")
    }

    func testSubmitGoalBuildsExpectedBodyAndDecodesResponse() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/goal")
            XCTAssertEqual(request.httpMethod, "POST")

            let body = try apiTestJSONBody(from: request)
            XCTAssertEqual(body["session_id"] as? String, "abc123")
            XCTAssertEqual(body["args"] as? String, "Ship the release notes")
            XCTAssertEqual(body["workspace"] as? String, "/tmp/workspace")
            XCTAssertEqual(body["model"] as? String, "gpt-5.4")
            XCTAssertEqual(body["model_provider"] as? String, "openai")
            XCTAssertEqual(body["profile"] as? String, "default")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "action": "set",
              "message": "Goal set.",
              "goal": {
                "goal": "Ship the release notes",
                "status": "active",
                "turns_used": "2",
                "max_turns": 20,
                "last_verdict": "continue",
                "last_reason": "still working",
                "paused_reason": null
              },
              "kickoff_prompt": "Continue the goal.",
              "decision": {
                "status": "active",
                "should_continue": true,
                "continuation_prompt": "Continue.",
                "verdict": "continue",
                "reason": "new goal",
                "message": "Keep going",
                "message_key": "goal.continue",
                "message_args": ["one", 2, true]
              }
            }
            """, for: request)
        }

        let response = try await client.submitGoal(
            sessionID: "abc123",
            args: "Ship the release notes",
            workspace: "/tmp/workspace",
            model: "gpt-5.4",
            modelProvider: "openai",
            profile: "default"
        )

        XCTAssertEqual(response.ok, true)
        XCTAssertEqual(response.action, "set")
        XCTAssertEqual(response.displayMessage, "Goal set.")
        XCTAssertEqual(response.goal?.goal, "Ship the release notes")
        XCTAssertEqual(response.goal?.status, "active")
        XCTAssertEqual(response.goal?.turnsUsed, 2)
        XCTAssertEqual(response.goal?.maxTurns, 20)
        XCTAssertEqual(response.goal?.lastVerdict, "continue")
        XCTAssertEqual(response.goal?.lastReason, "still working")
        XCTAssertNil(response.goal?.pausedReason)
        XCTAssertEqual(response.kickoffPromptText, "Continue the goal.")
        XCTAssertEqual(response.decision?.shouldContinue, true)
        XCTAssertEqual(response.decision?.continuationPrompt, "Continue.")
        XCTAssertEqual(response.decision?.messageKey, "goal.continue")
        XCTAssertEqual(response.decision?.messageArgs, [.string("one"), .number(2), .bool(true)])
    }

}
