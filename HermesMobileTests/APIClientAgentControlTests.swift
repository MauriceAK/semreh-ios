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

}
