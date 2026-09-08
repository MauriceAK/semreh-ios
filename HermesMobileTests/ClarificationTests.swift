import XCTest
@testable import HermesMobile

final class ClarificationTests: XCTestCase {
    func testClarificationPendingDecodesUpstreamShapeTolerantly() throws {
        let response = try JSONDecoder().decode(
            ClarificationPendingResponse.self,
            from: Data("""
            {"pending":{"clarify_id":"clarify-1","question":"Which branch should I use?",
            "choices_offered":["main",42,true],"session_id":"session-abc","kind":"clarify",
            "requested_at":"1716150000.0","timeout_seconds":"120","expires_at":1716150120.0,
            "future_field":{"ignored":true}},"pending_count":"2"}
            """.utf8)
        )
        XCTAssertEqual(response.pending?.clarifyId, "clarify-1")
        XCTAssertEqual(response.pending?.question, "Which branch should I use?")
        XCTAssertEqual(response.pending?.choicesOffered, ["main", "42.0", "true"])
        XCTAssertEqual(response.pending?.sessionId, "session-abc")
        XCTAssertEqual(response.pending?.requestedAt, 1_716_150_000)
        XCTAssertEqual(response.pending?.timeoutSeconds, 120)
        XCTAssertEqual(response.pending?.expiresAt, 1_716_150_120)
        XCTAssertEqual(response.pendingCount, 2)
    }

    func testClarificationPendingDecodesNullAndMissingOptionals() throws {
        let noPending = try JSONDecoder().decode(
            ClarificationPendingResponse.self, from: Data(#"{"pending":null}"#.utf8)
        )
        XCTAssertNil(noPending.pending)
        XCTAssertNil(noPending.pendingCount)
        let minimal = try JSONDecoder().decode(
            ClarificationPendingResponse.self,
            from: Data(#"{"pending":{"question":"Answer this."}}"#.utf8)
        )
        XCTAssertEqual(minimal.pending?.displayQuestion, "Answer this.")
        XCTAssertEqual(minimal.pending?.displayChoices, [])
    }

    func testClarificationRespondResponseDecodesStaleFieldsTolerantly() throws {
        let stale = try JSONDecoder().decode(
            ClarificationRespondResponse.self,
            from: Data(#"{"ok":false,"error":"expired","stale":true}"#.utf8)
        )
        XCTAssertEqual(stale.ok, false)
        XCTAssertEqual(stale.stale, true)
        XCTAssertNil(stale.staleCleared)
        let cleared = try JSONDecoder().decode(
            ClarificationRespondResponse.self,
            from: Data(#"{"ok":true,"response":"A","stale_cleared":"true","relayed":1}"#.utf8)
        )
        XCTAssertEqual(cleared.ok, true)
        XCTAssertEqual(cleared.staleCleared, true)
        XCTAssertEqual(cleared.relayed, true)
    }

    @MainActor
    func testSSEDecoderHandlesClarifyAndInitialEvents() {
        let clarify = SSEEventDecoder.decode(
            eventType: "clarify",
            data: #"{"pending":{"clarify_id":"clarify-2","question":"Choose deployment target","choices_offered":["iPhone","iPad"],"session_id":"session-abc"},"pending_count":1}"#
        )
        guard case .clarificationPending(let response) = clarify else {
            return XCTFail("Expected clarificationPending, got \(clarify)")
        }
        XCTAssertEqual(response.pending?.clarifyId, "clarify-2")
        XCTAssertEqual(response.pending?.displayChoices, ["iPhone", "iPad"])

        let initial = SSEEventDecoder.decode(
            eventType: "initial",
            data: #"{"pending":{"question":"What should I do next?","choices_offered":["Run tests","Stop"]},"pending_count":1}"#
        )
        guard case .clarificationPending(let initialResponse) = initial else {
            return XCTFail("Expected clarificationPending initial event, got \(initial)")
        }
        XCTAssertEqual(initialResponse.pending?.displayQuestion, "What should I do next?")
        XCTAssertEqual(initialResponse.pending?.displayChoices, ["Run tests", "Stop"])
    }
}
