import XCTest
@testable import HermesMobile

final class ChatMarkerMessageClassifierTests: XCTestCase {
    // MARK: - Context compaction

    func testBracketedCompactionPrefixMatches() {
        let message = makeMessage(role: "user", content: "[Context compaction] Summary of earlier conversation…")
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .contextCompaction)
    }

    func testUnbracketedCompactionPrefixMatches() {
        let message = makeMessage(role: "assistant", content: "Context compaction: the prior history was summarized.")
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .contextCompaction)
    }

    func testCompactionPrefixIsCaseInsensitive() {
        let message = makeMessage(role: "user", content: "[CONTEXT COMPACTION] details")
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .contextCompaction)
    }

    func testCompactionPrefixToleratesLeadingWhitespace() {
        let message = makeMessage(role: "user", content: "  \n\t[context compaction] details")
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .contextCompaction)
    }

    func testToolRoleNeverMatches() {
        let message = makeMessage(role: "tool", content: "[context compaction] details")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testMissingRoleNeverMatches() {
        let message = makeMessage(role: nil, content: "[context compaction] details")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testNonMarkerTextStartingWithContextDoesNotMatch() {
        let message = makeMessage(role: "user", content: "Context windows are interesting — explain compaction.")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    // MARK: - Preserved task list

    func testPreservedTaskListPrefixMatchesForUserRole() {
        let message = makeMessage(
            role: "user",
            content: "[Your active task list was preserved across context compression]\n1. Do the thing"
        )
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .preservedTaskList)
    }

    func testPreservedTaskListPrefixIsCaseInsensitiveAndToleratesWhitespace() {
        let message = makeMessage(
            role: "user",
            content: "   [YOUR ACTIVE TASK LIST WAS PRESERVED ACROSS CONTEXT COMPRESSION] tasks"
        )
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .preservedTaskList)
    }

    func testPreservedTaskListPrefixDoesNotMatchNonUserRoles() {
        let message = makeMessage(
            role: "assistant",
            content: "[Your active task list was preserved across context compression] tasks"
        )
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    // MARK: - Plain messages

    func testNormalUserMessageDoesNotMatch() {
        let message = makeMessage(role: "user", content: "Hey, can you check the build?")
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    func testEmptyContentDoesNotMatch() {
        let message = makeMessage(role: "user", content: nil)
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
    }

    // MARK: - Process wakeup

    func testBackgroundProcessCompletionIsASystemCardNotAUserBubble() {
        let message = makeMessage(
            role: "user",
            content: """
            [IMPORTANT: Background process proc_39c8cd3215a6 completed (exit_code=0).
            Command: xcodebuild -project HermesMobile.xcodeproj
            Output:
            ** BUILD SUCCEEDED **
            ]
            """
        )
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .processWakeup)
        XCTAssertFalse(TranscriptTurnClassifier.isUserTurnBoundary(message))
    }

    func testBackgroundProcessWatchMatchIsASystemCard() {
        let message = makeMessage(
            role: "user",
            content: """
            [IMPORTANT: Background process w1 matched watch pattern "ERROR".
            Command: tail -f app.log
            Matched output:
            ERROR timeout
            ]
            """
        )
        XCTAssertEqual(ChatMarkerMessageClassifier.classify(message), .processWakeup)
        XCTAssertFalse(TranscriptTurnClassifier.isUserTurnBoundary(message))
    }

    func testRealUserMessageAboutBackgroundProcessStaysAUserBubble() {
        let message = makeMessage(
            role: "user",
            content: "Can you check that background process output from the last build?"
        )
        XCTAssertNil(ChatMarkerMessageClassifier.classify(message))
        XCTAssertTrue(TranscriptTurnClassifier.isUserTurnBoundary(message))
    }

    // MARK: - Card body

    func testCardBodyStripsPreservedTaskListMarker() {
        let body = ChatMarkerMessageClassifier.cardBody(
            for: .preservedTaskList,
            content: "[Your active task list was preserved across context compression]\n1. First task\n2. Second task"
        )
        XCTAssertEqual(body, "1. First task\n2. Second task")
    }

    func testCardBodyPreservesMarkdownTaskListAfterMarker() {
        let source = """
        [Your active task list was preserved across context compression]
        ## Follow-up
        - [ ] **Check** the `message_id` anchor
        - [x] Keep completed work visible
        """

        XCTAssertEqual(
            ChatMarkerMessageClassifier.cardBody(for: .preservedTaskList, content: source),
            """
            ## Follow-up
            - [ ] **Check** the `message_id` anchor
            - [x] Keep completed work visible
            """
        )
    }

    func testCardBodyKeepsCompactionTextIntact() {
        let body = ChatMarkerMessageClassifier.cardBody(
            for: .contextCompaction,
            content: "  [Context compaction] Summary text  "
        )
        XCTAssertEqual(body, "[Context compaction] Summary text")
    }

    // MARK: - Helpers

    private func makeMessage(role: String?, content: String?) -> ChatMessage {
        ChatMessage(role: role, content: content, timestamp: nil, messageId: "test-id")
    }
}

final class MarkerMessageCardPresentationTests: XCTestCase {
    func testLatestTaskSummaryRemovesMarkdownCheckboxButKeepsMeaningfulText() {
        XCTAssertEqual(
            MarkerMessageCardPresentation.latestTaskSummary(in: "## Follow-up\n- [ ] Inspect the fixture\n- [x] **Keep** completed work visible"),
            "Keep completed work visible"
        )
        XCTAssertEqual(
            MarkerMessageCardPresentation.latestTaskSummary(in: "1. [ ] **Review** the `message_id` anchor"),
            "Review the message_id anchor"
        )
    }

    func testLatestTaskSummaryRemovesUpstreamCurrentTaskMarker() {
        XCTAssertEqual(
            MarkerMessageCardPresentation.latestTaskSummary(in: "- [>] Run the `build-v4` check"),
            "Run the build-v4 check"
        )
    }

    func testLatestTaskSummaryDoesNotStripCheckboxTextAwayFromLeadingSyntax() {
        XCTAssertEqual(
            MarkerMessageCardPresentation.latestTaskSummary(in: "Compare the `[x]` state with the server."),
            "Compare the [x] state with the server."
        )
    }
}
