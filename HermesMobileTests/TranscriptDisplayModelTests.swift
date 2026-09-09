import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class TranscriptMessageTests: XCTestCase {
    func testAttachmentImageCacheSeparatesSamePathAcrossServerSessionNamespaces() async throws {
        let cache = AttachmentImageCache()
        let path = "/tmp/shared-preview.png"
        let blueData = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let redData = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).pngData { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        var firstLoads = 0
        var secondLoads = 0

        let first = await cache.image(
            for: path,
            cacheNamespace: "https://one.example.test|session-a"
        ) { _ in
            firstLoads += 1
            return blueData
        }
        let second = await cache.image(
            for: path,
            cacheNamespace: "https://two.example.test|session-a"
        ) { _ in
            secondLoads += 1
            return redData
        }
        _ = await cache.image(
            for: path,
            cacheNamespace: "https://one.example.test|session-a"
        ) { _ in
            XCTFail("The first namespace should reuse its cached image")
            return nil
        }

        XCTAssertEqual(firstLoads, 1)
        XCTAssertEqual(secondLoads, 1)
        XCTAssertNotEqual(try XCTUnwrap(first?.pngData()), try XCTUnwrap(second?.pngData()))
    }

    func testTranscriptMessagesHideToolRowsAndPreserveLoadedIndices() {
        let messages = [
            ChatMessage(role: "user", content: "Plan it", timestamp: 1, messageId: "u1"),
            ChatMessage(role: "assistant", content: "Working on it", timestamp: 2, messageId: "a1"),
            ChatMessage(
                role: "tool",
                content: #"{"success":true,"diff":"..."}"#,
                timestamp: 3,
                messageId: "t1",
                toolCallId: "tool-1"
            ),
            ChatMessage(role: "assistant", content: "Done. Here's what changed.", timestamp: 4, messageId: "a2")
        ]

        let transcriptMessages = ChatViewModel.transcriptMessages(from: messages)

        XCTAssertEqual(transcriptMessages.map(\.loadedIndex), [0, 1, 3])
        XCTAssertEqual(transcriptMessages.map(\.message.id), ["u1", "a1", "a2"])
    }

    func testToolHeavyTurnRenderSequenceDropsEmptyRowsWithoutAccessories() {
        var messages = [
            ChatMessage(role: "user", content: "Research this", timestamp: 1, messageId: "u1")
        ]
        for index in 0..<68 {
            let toolID = "tool-\(index)"
            messages.append(ChatMessage(
                role: "assistant",
                content: "",
                timestamp: Double(index * 2 + 2),
                messageId: "a-\(index)",
                toolCalls: [
                    .object([
                        "id": .string(toolID),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string("web_search"),
                            "arguments": .string("{}")
                        ])
                    ])
                ]
            ))
            messages.append(ChatMessage(
                role: "tool",
                content: "result \(index)",
                timestamp: Double(index * 2 + 3),
                messageId: "result-\(index)",
                toolCallId: toolID
            ))
        }
        messages.append(ChatMessage(
            role: "assistant",
            content: "Search stopped after reaching the tool-use limit.",
            timestamp: 200,
            messageId: "final"
        ))

        let transcript = ChatViewModel.transcriptMessages(from: messages)
        let groups = ToolCallGroup.groups(
            persistedToolCalls: [],
            messages: messages,
            messageOffset: 0
        )
        let rendered = ChatTranscriptRenderSequence.filtering(
            transcript,
            showsThinkingAndToolCards: true,
            compressionAfterRenderID: nil,
            reasoningGroupsForAnchor: { _ in [] },
            toolCallGroupsForAnchor: { anchorID in
                groups.filter { $0.anchorMessageID == anchorID }
            },
            liveAccessoryAnchorIDs: []
        ) { message in
            message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.anchorMessageID, "a-0")
        XCTAssertEqual(groups.first?.toolCalls.count, 68)
        XCTAssertEqual(transcript.count, 70, "Tool result rows are filtered, but every empty assistant row remains.")
        XCTAssertEqual(rendered.map(\.anchorID), ["u1", "a-0", "final"])
        XCTAssertEqual(
            transcript.count - rendered.count,
            67,
            "Accessory-free empty assistants must not become LazyVStack children that contribute outer spacing."
        )
    }

    func testRenderSequencePreservesEmptyAccessoryAndCompressionAnchors() throws {
        let messages = [
            ChatMessage(role: "assistant", content: "", timestamp: 1, messageId: "reasoning-anchor"),
            ChatMessage(role: "assistant", content: "", timestamp: 2, messageId: "compression-anchor"),
            ChatMessage(role: "assistant", content: "", timestamp: 3, messageId: "empty")
        ]
        let transcript = ChatViewModel.transcriptMessages(from: messages)
        let compressionRenderID = try XCTUnwrap(
            transcript.first { $0.anchorID == "compression-anchor" }?.renderID
        )

        let rendered = ChatTranscriptRenderSequence.filtering(
            transcript,
            showsThinkingAndToolCards: true,
            compressionAfterRenderID: compressionRenderID,
            reasoningGroupsForAnchor: { _ in [] },
            toolCallGroupsForAnchor: { _ in [] },
            liveAccessoryAnchorIDs: ["reasoning-anchor"],
            shouldRenderMessage: { _ in false }
        )

        XCTAssertEqual(rendered.map(\.anchorID), ["reasoning-anchor", "compression-anchor"])
        XCTAssertEqual(
            rendered.last?.anchorID,
            "compression-anchor",
            "An empty filtered tail must not become the latest scroll target."
        )
    }

    func testDirectTranscriptProjectsAttachmentRefsWithoutMutatingRawMessage() {
        let rawContent = "Inspect these\n@image:/home/images/upload.jpg\n@file:notes.txt"
        let message = ChatMessage(role: "user", content: rawContent, timestamp: 1, messageId: "u1")

        let legacy = ChatViewModel.transcriptMessages(from: [message])
        XCTAssertNil(legacy[0].attachmentDisplayContent)

        let direct = ChatViewModel.transcriptMessages(
            from: [message],
            hidingStreamingAssistantID: nil,
            preferDurableIDs: true
        )
        XCTAssertEqual(direct[0].attachmentDisplayContent, "Inspect these")
        XCTAssertEqual(direct[0].message.content, rawContent)
    }

    func testDirectTranscriptProjectsStructuredTextPartAndPreservesAttachmentOnlyEmptyText() {
        let structured = ChatMessage(
            role: "user",
            content: "Caption\n@image:/home/images/upload.jpg",
            timestamp: 1,
            messageId: "u1",
            contentParts: [
                .object([
                    "type": .string("text"),
                    "text": .string("Caption\n@image:/home/images/upload.jpg")
                ]),
                .object(["type": .string("image")])
            ]
        )
        let attachmentOnly = ChatMessage(
            role: "user",
            content: "@image:/home/images/upload.jpg",
            timestamp: 2,
            messageId: "u2"
        )

        let transcript = ChatViewModel.transcriptMessages(
            from: [structured, attachmentOnly],
            hidingStreamingAssistantID: nil,
            preferDurableIDs: true
        )
        XCTAssertEqual(transcript[0].attachmentDisplayContent, "Caption")
        XCTAssertEqual(transcript[1].attachmentDisplayContent, "")
    }

    func testTranscriptMessagesCanHideActiveStreamingAssistantTurn() {
        let messages = [
            ChatMessage(role: "user", content: "Use tools", timestamp: 1, messageId: "u1"),
            ChatMessage(role: "assistant", content: "", timestamp: 2, messageId: "stream-1"),
            ChatMessage(
                role: "tool",
                content: #"{"success":true}"#,
                timestamp: 3,
                messageId: "t1",
                toolCallId: "tool-1"
            ),
            ChatMessage(role: "assistant", content: "Older answer", timestamp: 4, messageId: "a2")
        ]

        let transcriptMessages = ChatViewModel.transcriptMessages(
            from: messages,
            hidingStreamingAssistantID: "stream-1"
        )

        XCTAssertEqual(transcriptMessages.map(\.loadedIndex), [0, 3])
        XCTAssertEqual(transcriptMessages.map(\.message.id), ["u1", "a2"])
    }

    func testTranscriptMessagesKeepStreamingAssistantAnchorStableAcrossContentUpdates() {
        let initialMessages = [
            ChatMessage(role: "user", content: "Write a long answer", timestamp: 1, messageId: "u1"),
            ChatMessage(role: "assistant", content: "", timestamp: 2, messageId: "stream-1")
        ]
        let updatedMessages = [
            ChatMessage(role: "user", content: "Write a long answer", timestamp: 1, messageId: "u1"),
            ChatMessage(role: "assistant", content: "First streamed token.", timestamp: 2, messageId: "stream-1")
        ]

        let initialTranscriptMessages = ChatViewModel.transcriptMessages(from: initialMessages)
        let updatedTranscriptMessages = ChatViewModel.transcriptMessages(from: updatedMessages)

        XCTAssertEqual(initialTranscriptMessages.map(\.anchorID), ["u1", "stream-1"])
        XCTAssertEqual(updatedTranscriptMessages.map(\.anchorID), ["u1", "stream-1"])
        XCTAssertEqual(initialTranscriptMessages.map(\.id), updatedTranscriptMessages.map(\.id))
        XCTAssertEqual(initialTranscriptMessages.map(\.loadedIndex), updatedTranscriptMessages.map(\.loadedIndex))
    }

    func testTranscriptMessagesKeepRenderIDStableWhenServerReplacesStreamingAssistantID() {
        let streamingMessages = [
            ChatMessage(role: "user", content: "Finish the summary", timestamp: 1, messageId: "u1"),
            ChatMessage(role: "assistant", content: "Working summary", timestamp: 2, messageId: "stream-1")
        ]
        let completedMessages = [
            ChatMessage(role: "user", content: "Finish the summary", timestamp: 1, messageId: "u1"),
            ChatMessage(role: "assistant", content: "Final summary", timestamp: 2, messageId: "assistant-1")
        ]

        let streamingTranscriptMessages = ChatViewModel.transcriptMessages(from: streamingMessages)
        let completedTranscriptMessages = ChatViewModel.transcriptMessages(from: completedMessages)

        XCTAssertEqual(streamingTranscriptMessages.map(\.id), completedTranscriptMessages.map(\.id))
        XCTAssertEqual(streamingTranscriptMessages.map(\.anchorID), ["u1", "stream-1"])
        XCTAssertEqual(completedTranscriptMessages.map(\.anchorID), ["u1", "assistant-1"])
    }

    func testTranscriptMessagesUseRawAnchorForNilMessageIDsIndependentOfContent() {
        let initialMessages = [
            ChatMessage(role: "user", content: "Hello", timestamp: 1, messageId: nil),
            ChatMessage(role: "assistant", content: "", timestamp: 2, messageId: nil)
        ]
        let updatedMessages = [
            ChatMessage(role: "user", content: "Hello", timestamp: 1, messageId: nil),
            ChatMessage(role: "assistant", content: "A streamed response.", timestamp: 2, messageId: nil)
        ]

        let initialTranscriptMessages = ChatViewModel.transcriptMessages(
            from: initialMessages,
            messageOffset: 10
        )
        let updatedTranscriptMessages = ChatViewModel.transcriptMessages(
            from: updatedMessages,
            messageOffset: 10
        )

        XCTAssertEqual(initialTranscriptMessages.map(\.anchorID), ["raw:10", "raw:11"])
        XCTAssertEqual(updatedTranscriptMessages.map(\.anchorID), ["raw:10", "raw:11"])
        XCTAssertEqual(initialTranscriptMessages.map(\.id), updatedTranscriptMessages.map(\.id))
    }

    func testTranscriptMessagesKeepRenderIDsStableWhenOlderMessagesPrepend() {
        let initialWindow = [
            ChatMessage(role: "assistant", content: "Earlier answer", timestamp: 1, messageId: "a1"),
            ChatMessage(role: "user", content: "Follow up", timestamp: 2, messageId: "u2"),
            ChatMessage(role: "assistant", content: "Latest answer", timestamp: 3, messageId: "a2")
        ]
        let expandedWindow = [
            ChatMessage(role: "user", content: "First question", timestamp: 0, messageId: "u1"),
            ChatMessage(role: "assistant", content: "Earlier answer", timestamp: 1, messageId: "a1"),
            ChatMessage(role: "user", content: "Follow up", timestamp: 2, messageId: "u2"),
            ChatMessage(role: "assistant", content: "Latest answer", timestamp: 3, messageId: "a2")
        ]

        let initialTranscriptMessages = ChatViewModel.transcriptMessages(
            from: initialWindow,
            messageOffset: 1
        )
        let expandedTranscriptMessages = ChatViewModel.transcriptMessages(
            from: expandedWindow,
            messageOffset: 0
        )

        XCTAssertEqual(initialTranscriptMessages.map(\.id), ["transcript:1", "transcript:2", "transcript:3"])
        XCTAssertEqual(expandedTranscriptMessages.map(\.id), ["transcript:0", "transcript:1", "transcript:2", "transcript:3"])

        let initialRenderIDsByMessageID = Dictionary(
            uniqueKeysWithValues: initialTranscriptMessages.compactMap { transcriptMessage in
                transcriptMessage.message.messageId.map { ($0, transcriptMessage.id) }
            }
        )
        for expandedTranscriptMessage in expandedTranscriptMessages {
            guard let messageID = expandedTranscriptMessage.message.messageId,
                  let initialRenderID = initialRenderIDsByMessageID[messageID]
            else { continue }

            XCTAssertEqual(
                expandedTranscriptMessage.id,
                initialRenderID,
                "renderID should stay stable for message \(messageID)"
            )
        }
    }

    func testTranscriptMessagesPreserveMessagesWithNilMessageIDsWhenNoStreamingTurnHidden() {
        let messages = [
            ChatMessage(role: "user", content: "Hello", timestamp: 1, messageId: nil),
            ChatMessage(role: "assistant", content: "Hi", timestamp: 2, messageId: nil),
            ChatMessage(
                role: "tool",
                content: #"{"success":true}"#,
                timestamp: 3,
                messageId: nil,
                toolCallId: "tool-1"
            )
        ]

        let transcriptMessages = ChatViewModel.transcriptMessages(from: messages)

        XCTAssertEqual(transcriptMessages.map(\.loadedIndex), [0, 1])
        XCTAssertEqual(transcriptMessages.map(\.message.role), ["user", "assistant"])
    }

    func testCacheWindowKeepsOnlyNewestPageForConstantTimePersistence() {
        let messages = (0..<1_000).map { index in
            ChatMessage(
                role: index.isMultiple(of: 2) ? "user" : "assistant",
                content: "Message \(index)",
                timestamp: Double(index),
                messageId: "message-\(index)"
            )
        }

        let window = ChatViewModel.cacheMessageWindow(from: messages)

        XCTAssertEqual(window.count, 50)
        XCTAssertEqual(window.first?.messageId, "message-950")
        XCTAssertEqual(window.last?.messageId, "message-999")
    }

    func testReasoningDisplayGroupsAggregateOneAssistantTurnOnFinalVisibleAnchor() {
        let messages = [
            ChatMessage(role: "user", content: "Investigate", timestamp: 1, messageId: "u1"),
            ChatMessage(role: "assistant", content: nil, timestamp: 2, messageId: "a1", reasoning: "First thought."),
            ChatMessage(role: "assistant", content: nil, timestamp: 3, messageId: "a2", reasoning: "Second thought."),
            ChatMessage(role: "assistant", content: "Final answer", timestamp: 4, messageId: "a3", reasoning: "Third thought.")
        ]

        let groups = ChatViewModel.reasoningDisplayGroups(messages: messages, archivedGroups: [])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.anchorMessageID, "a3")
        XCTAssertEqual(groups.first?.text, "First thought.\n\nSecond thought.\n\nThird thought.")
    }

    func testReasoningDisplayGroupsCollapseExactServerEnvelopeOnFinalAnchor() throws {
        let data = Data(#"{"session":{"session_id":"reasoning-group-session","messages":[{"role":"user","content":"Investigate the continuity issue.","timestamp":1771000001,"messageId":"u1"},{"role":"assistant","content":null,"reasoning":"Inspecting the canonical session identity.","timestamp":1771000002,"messageId":"a1"},{"role":"assistant","content":null,"reasoning":"Comparing WebUI and official Hermes transport behavior.","timestamp":1771000003,"messageId":"a2"},{"role":"tool","content":"Read-only transport evidence.","timestamp":1771000004,"messageId":"t1"},{"role":"assistant","content":"The completed turn is available under the same canonical session ID.","reasoning":"Synthesizing the verified findings.","timestamp":1771000005,"messageId":"a3"}]}}"#.utf8)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(SessionResponse.self, from: data)
        let messages = try XCTUnwrap(response.session?.messages)

        let groups = ChatViewModel.reasoningDisplayGroups(messages: messages, archivedGroups: [])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.anchorMessageID, "a3")
    }

    func testReasoningDisplayGroupsDeduplicateNormalizedTextInFirstSeenOrder() {
        let messages = [
            ChatMessage(role: "user", content: "Investigate", timestamp: 1, messageId: "u1"),
            ChatMessage(role: "assistant", content: nil, timestamp: 2, messageId: "a1", reasoning: "First   thought."),
            ChatMessage(role: "assistant", content: nil, timestamp: 3, messageId: "a2", reasoning: " Second thought. "),
            ChatMessage(role: "assistant", content: "Final", timestamp: 4, messageId: "a3", reasoning: "First thought.")
        ]

        let group = ChatViewModel.reasoningDisplayGroups(messages: messages, archivedGroups: []).first

        XCTAssertEqual(group?.text, "First   thought.\n\nSecond thought.")
    }

    func testReasoningDisplayGroupsDoNotCrossUserTurns() {
        let messages = [
            ChatMessage(role: "user", content: "First", timestamp: 1, messageId: "u1"),
            ChatMessage(role: "assistant", content: "First answer", timestamp: 2, messageId: "a1", reasoning: "First thought."),
            ChatMessage(role: "user", content: "Second", timestamp: 3, messageId: "u2"),
            ChatMessage(role: "assistant", content: "Second answer", timestamp: 4, messageId: "a2", reasoning: "Second thought.")
        ]

        let groups = ChatViewModel.reasoningDisplayGroups(messages: messages, archivedGroups: [])

        XCTAssertEqual(groups.map(\.anchorMessageID), ["a1", "a2"])
        XCTAssertEqual(groups.map(\.text), ["First thought.", "Second thought."])
    }

    func testReasoningDisplayGroupsKeepRepeatedNoIDUserPromptsAsSeparateTurns() {
        let messages = [
            ChatMessage(role: "user", content: "Continue", timestamp: 1, messageId: nil),
            ChatMessage(role: "assistant", content: "First answer", timestamp: 2, messageId: "a1", reasoning: "First thought."),
            ChatMessage(role: "user", content: "Continue", timestamp: 3, messageId: nil),
            ChatMessage(role: "assistant", content: "Second answer", timestamp: 4, messageId: "a2", reasoning: "Second thought.")
        ]

        let groups = ChatViewModel.reasoningDisplayGroups(messages: messages, archivedGroups: [])

        XCTAssertEqual(groups.map(\.anchorMessageID), ["a1", "a2"])
        XCTAssertEqual(groups.map(\.text), ["First thought.", "Second thought."])
    }

    func testReasoningDisplayGroupsAggregateArchivedAndMessageDerivedReasoning() {
        let messages = [
            ChatMessage(role: "user", content: "Investigate", timestamp: 1, messageId: "u1"),
            ChatMessage(role: "assistant", content: "Final answer", timestamp: 2, messageId: "a2", reasoning: "Message-derived thought.")
        ]
        let archived = [ReasoningGroup(id: "archived-1", anchorMessageID: "a2", text: "Archived thought.")]

        let groups = ChatViewModel.reasoningDisplayGroups(messages: messages, archivedGroups: archived)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.anchorMessageID, "a2")
        XCTAssertEqual(groups.first?.text, "Archived thought.\n\nMessage-derived thought.")
    }

    func testReasoningDisplayGroupIDIsStableAcrossMessageOffsets() {
        let messages = [
            ChatMessage(role: "user", content: "Investigate", timestamp: 1, messageId: "u1"),
            ChatMessage(role: "assistant", content: "Final answer", timestamp: 2, messageId: "a1", reasoning: "Thought.")
        ]

        let first = ChatViewModel.reasoningDisplayGroups(messages: messages, messageOffset: 0, archivedGroups: [])
        let paged = ChatViewModel.reasoningDisplayGroups(messages: messages, messageOffset: 20, archivedGroups: [])

        XCTAssertEqual(first.map(\.id), paged.map(\.id))
    }

    func testHistoricalReasoningDisplayDoesNotConsumeLiveReasoningText() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("HermesMobile/Features/Chat/ChatViewModel.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("liveReasoningText: liveReasoningText"))
        XCTAssertTrue(source.contains("archivedGroups: completedReasoningGroups"))
        XCTAssertFalse(source.contains("reasoningDisplayGroups(messages: messages, liveReasoningText:"))
    }

    func testReasoningGroupsAreMemoizedAcrossIncrementalStreamingUpdates() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repositoryRoot
            .appendingPathComponent("HermesMobile/Features/Chat/ChatViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("private(set) var displayedReasoningGroups: [ReasoningGroup] = []"),
            "Reasoning derivation must be stored instead of rescanning the full transcript on every body evaluation."
        )
        let incrementalStart = try XCTUnwrap(source.range(of: "private func replaceDisplayedTranscriptMessage"))
        let incrementalEnd = try XCTUnwrap(
            source.range(of: "private func recomputeDisplayedTranscriptMessages", range: incrementalStart.upperBound..<source.endIndex)
        )
        let incrementalSource = String(source[incrementalStart.lowerBound..<incrementalEnd.lowerBound])
        XCTAssertFalse(
            incrementalSource.contains("recomputeDisplayedReasoningGroups"),
            "Appending visible assistant tokens must not rescan historical reasoning groups."
        )
        XCTAssertTrue(source.contains("displayedReasoningGroupsForAnchor"))

        let transcriptViewURL = repositoryRoot.appendingPathComponent(
            "HermesMobile/Features/Chat/ChatTranscriptView.swift"
        )
        let transcriptSource = try String(contentsOf: transcriptViewURL, encoding: .utf8)
        XCTAssertTrue(transcriptSource.contains("reasoningGroupsForAnchor:"))
        XCTAssertFalse(
            transcriptSource.contains("reasoningGroups.filter { $0.anchorMessageID == transcriptMessage.anchorID }"),
            "Each row must receive only its anchor's reasoning groups instead of filtering the full history."
        )
    }

    func testStreamingFlushUpdatesOnlyTheLiveTranscriptRow() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HermesMobile/Features/Chat/ChatViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let flushStart = try XCTUnwrap(source.range(of: "private func flushAssistantTokens"))
        let flushEnd = try XCTUnwrap(
            source.range(of: "private func deduplicatedReplayToken", range: flushStart.upperBound..<source.endIndex)
        )
        let flushSource = String(source[flushStart.lowerBound..<flushEnd.lowerBound])

        XCTAssertTrue(
            flushSource.contains("replaceStreamingMessage(") && flushSource.contains("at: index"),
            "A streaming token must update only its live row instead of remapping every loaded transcript message."
        )
        XCTAssertFalse(
            flushSource.contains("messages[index] = ChatMessage"),
            "Direct array replacement triggers the full messages observer and scales with conversation length."
        )
        XCTAssertTrue(source.contains("displayedTranscriptRowIndexByLoadedIndex"))
        let replacementStart = try XCTUnwrap(source.range(of: "private func replaceDisplayedTranscriptMessage"))
        let replacementEnd = try XCTUnwrap(
            source.range(of: "private func recomputeDisplayedTranscriptMessages", range: replacementStart.upperBound..<source.endIndex)
        )
        let replacementSource = String(source[replacementStart.lowerBound..<replacementEnd.lowerBound])
        XCTAssertFalse(
            replacementSource.contains("firstIndex"),
            "Incremental token flushes must use O(1) loaded-index lookup instead of scanning every displayed row."
        )
    }

    func testStreamingMessageStorageDoesNotPublishTheWholeHistoryArray() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HermesMobile/Features/Chat/ChatViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(
            source.contains("@ObservationIgnored private(set) var messages: [ChatMessage]"),
            "Publishing the complete messages array makes each live-row replacement retain/copy history-sized storage."
        )
        XCTAssertTrue(
            source.contains("private(set) var transcriptRenderRevision"),
            "An explicit lightweight revision must remain the observable transcript invalidation signal."
        )
    }

    func testStreamingPendingTextUsesOneAppendOnlyBuffer() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HermesMobile/Features/Chat/ChatViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("pendingAssistantTextBuffer: String"))
        XCTAssertFalse(
            source.contains("pendingAssistantTokenChunks.joined()"),
            "Joining every queued token for dedup and pacing repeatedly copies the pending response."
        )
    }

    func testStreamingReasoningUsesOneAppendOnlyBuffer() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HermesMobile/Features/Chat/ChatViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("pendingReasoningTextBuffer: String"))
        XCTAssertFalse(
            source.contains("pendingReasoningChunks.joined()"),
            "Reasoning bursts must not repeatedly join every pending event before presentation."
        )
    }

    func testStreamingFlushUsesCachedLiveMessageIndex() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HermesMobile/Features/Chat/ChatViewModel.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let appendStart = try XCTUnwrap(source.range(of: "private func appendAssistantToken"))
        let appendEnd = try XCTUnwrap(
            source.range(of: "private func deduplicatedReplayToken", range: appendStart.upperBound..<source.endIndex)
        )
        let hotPath = String(source[appendStart.lowerBound..<appendEnd.lowerBound])

        XCTAssertTrue(source.contains("streamingAssistantMessageIndex"))
        XCTAssertTrue(hotPath.contains("streamingAssistantMessagePosition"))
        XCTAssertFalse(
            hotPath.contains("messages.firstIndex"),
            "Every token/flush must not scan the entire loaded history to find the live tail row."
        )
    }

    func testTranscriptUsesLazyRowConstructionForLongConversations() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HermesMobile/Features/Chat/ChatTranscriptView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let contentStart = try XCTUnwrap(source.range(of: "private func transcriptScrollContent("))
        let contentEnd = try XCTUnwrap(
            source.range(of: "private func compressionReferenceCardView", range: contentStart.upperBound..<source.endIndex)
        )
        let scrollContent = source[contentStart.lowerBound..<contentEnd.lowerBound]

        XCTAssertTrue(
            scrollContent.contains("\n        LazyVStack(spacing: transcriptMessageSpacing)"),
            "Long conversations must lazily instantiate transcript rows instead of building the full history eagerly."
        )
        XCTAssertFalse(scrollContent.contains("\n        VStack(spacing: transcriptMessageSpacing)"))
    }
}

final class ChatTranscriptDisplaySettingsTests: XCTestCase {
    func testTypingIndicatorStaysHiddenBehindVisibleThinkingAndToolCards() {
        XCTAssertFalse(ChatTranscriptDisplaySettings.shouldShowAssistantTypingIndicator(
            hasActiveStream: true,
            isCancellingStream: false,
            hasStreamingAssistantMessage: false,
            liveReasoningText: "Inspecting files",
            hasLiveToolCalls: false,
            showsThinkingAndToolCards: true
        ))

        XCTAssertFalse(ChatTranscriptDisplaySettings.shouldShowAssistantTypingIndicator(
            hasActiveStream: true,
            isCancellingStream: false,
            hasStreamingAssistantMessage: false,
            liveReasoningText: "",
            hasLiveToolCalls: true,
            showsThinkingAndToolCards: true
        ))
    }

    func testTypingIndicatorShowsWhenHiddenCardsAreOnlyLiveActivity() {
        XCTAssertTrue(ChatTranscriptDisplaySettings.shouldShowAssistantTypingIndicator(
            hasActiveStream: true,
            isCancellingStream: false,
            hasStreamingAssistantMessage: false,
            liveReasoningText: "Inspecting files",
            hasLiveToolCalls: true,
            showsThinkingAndToolCards: false
        ))

        XCTAssertFalse(ChatTranscriptDisplaySettings.shouldShowAssistantTypingIndicator(
            hasActiveStream: true,
            isCancellingStream: false,
            hasStreamingAssistantMessage: true,
            liveReasoningText: "Inspecting files",
            hasLiveToolCalls: true,
            showsThinkingAndToolCards: false
        ))
    }

    func testTypingIndicatorHidesBehindPendingClarificationPrompt() {
        XCTAssertFalse(ChatTranscriptDisplaySettings.shouldShowAssistantTypingIndicator(
            hasActiveStream: true,
            isCancellingStream: false,
            hasStreamingAssistantMessage: false,
            hasPendingClarificationPrompt: true,
            liveReasoningText: "",
            hasLiveToolCalls: false,
            showsThinkingAndToolCards: false
        ))
    }

    func testStreamingBubbleRenderingDoesNotMatchNilMessageIDs() {
        XCTAssertFalse(ChatTranscriptDisplaySettings.shouldUseStreamingBubbleRendering(
            hasActiveStream: true,
            messageRole: "user",
            messageID: nil,
            streamingAssistantMessageID: nil
        ))

        XCTAssertFalse(ChatTranscriptDisplaySettings.shouldUseStreamingBubbleRendering(
            hasActiveStream: true,
            messageRole: "assistant",
            messageID: nil,
            streamingAssistantMessageID: nil
        ))
    }

    func testStreamingBubbleRenderingMatchesActiveStreamingAssistant() {
        XCTAssertTrue(ChatTranscriptDisplaySettings.shouldUseStreamingBubbleRendering(
            hasActiveStream: true,
            messageRole: "assistant",
            messageID: "stream-1",
            streamingAssistantMessageID: "stream-1"
        ))

        XCTAssertFalse(ChatTranscriptDisplaySettings.shouldUseStreamingBubbleRendering(
            hasActiveStream: true,
            messageRole: "assistant",
            messageID: "assistant-1",
            streamingAssistantMessageID: "stream-1"
        ))
    }

    func testCardExpansionFollowsStartExpandedPreferenceUntilToggled() {
        XCTAssertFalse(ChatTranscriptDisplaySettings.isCardExpanded(userToggled: nil, startsExpanded: false))
        XCTAssertTrue(ChatTranscriptDisplaySettings.isCardExpanded(userToggled: nil, startsExpanded: true))
    }

    func testCardExpansionTapOverrideWinsOverPreference() {
        XCTAssertTrue(ChatTranscriptDisplaySettings.isCardExpanded(userToggled: true, startsExpanded: false))
        XCTAssertFalse(ChatTranscriptDisplaySettings.isCardExpanded(userToggled: false, startsExpanded: true))
    }

    func testCardStartExpandedKeysAreStableAndDistinct() {
        XCTAssertEqual(
            ChatTranscriptDisplaySettings.thinkingCardsStartExpandedKey,
            "chatTranscript.thinkingCardsStartExpanded"
        )
        XCTAssertEqual(
            ChatTranscriptDisplaySettings.toolCardsStartExpandedKey,
            "chatTranscript.toolCardsStartExpanded"
        )
        XCTAssertNotEqual(
            ChatTranscriptDisplaySettings.thinkingCardsStartExpandedKey,
            ChatTranscriptDisplaySettings.showsThinkingAndToolCardsKey
        )
    }

    func testHidesAttachmentPathsKeyIsStableAndDistinct() {
        XCTAssertEqual(
            ChatTranscriptDisplaySettings.hidesAttachmentPathsKey,
            "chatTranscript.hidesAttachmentPaths"
        )
        XCTAssertNotEqual(
            ChatTranscriptDisplaySettings.hidesAttachmentPathsKey,
            ChatTranscriptDisplaySettings.showsThinkingAndToolCardsKey
        )
    }

    func testAssistantTurnTimestampsKeyIsStableAndDistinct() {
        XCTAssertEqual(
            ChatTranscriptDisplaySettings.showsAssistantTurnTimestampsKey,
            "chatTranscript.showsAssistantTurnTimestamps"
        )
        XCTAssertNotEqual(
            ChatTranscriptDisplaySettings.showsAssistantTurnTimestampsKey,
            ChatTranscriptDisplaySettings.hidesAttachmentPathsKey
        )
    }

    func testResponseSpeedKeyIsStableAndDistinct() {
        XCTAssertEqual(
            ChatTranscriptDisplaySettings.showsResponseSpeedKey,
            "chatTranscript.showsResponseSpeed"
        )
        XCTAssertNotEqual(
            ChatTranscriptDisplaySettings.showsResponseSpeedKey,
            ChatTranscriptDisplaySettings.showsAssistantTurnTimestampsKey
        )
    }

    func testTimestampAndResponseSpeedTogglesAreIndependent() {
        XCTAssertFalse(ChatTranscriptDisplaySettings.showsAssistantTurnHeader(
            role: "assistant",
            hasTextContent: true,
            isEnabled: false,
            showsResponseSpeed: false,
            hasResponseSpeed: true
        ))
        XCTAssertTrue(ChatTranscriptDisplaySettings.showsAssistantTurnHeader(
            role: "assistant",
            hasTextContent: true,
            isEnabled: true,
            showsResponseSpeed: false,
            hasResponseSpeed: true
        ))
        XCTAssertTrue(ChatTranscriptDisplaySettings.showsAssistantTurnHeader(
            role: "assistant",
            hasTextContent: true,
            isEnabled: false,
            showsResponseSpeed: true,
            hasResponseSpeed: true
        ))
        XCTAssertTrue(ChatTranscriptDisplaySettings.showsAssistantTurnHeader(
            role: "assistant",
            hasTextContent: true,
            isEnabled: true,
            showsResponseSpeed: true,
            hasResponseSpeed: true
        ))
    }

    func testInvalidResponseSpeedAloneDoesNotCreateHeaderRow() {
        XCTAssertFalse(ChatTranscriptDisplaySettings.showsAssistantTurnHeader(
            role: "assistant",
            hasTextContent: true,
            isEnabled: false,
            showsResponseSpeed: true,
            hasResponseSpeed: false
        ))
    }

    func testAssistantTurnHeaderShowsForAssistantTextTurnWhenEnabled() {
        XCTAssertTrue(ChatTranscriptDisplaySettings.showsAssistantTurnHeader(
            role: "assistant",
            hasTextContent: true,
            isEnabled: true
        ))
    }

    func testAssistantTurnHeaderHiddenWhenToggleOff() {
        XCTAssertFalse(ChatTranscriptDisplaySettings.showsAssistantTurnHeader(
            role: "assistant",
            hasTextContent: true,
            isEnabled: false
        ))
    }

    func testAssistantTurnHeaderHiddenForEmptyOrToolOnlyAssistantRow() {
        XCTAssertFalse(ChatTranscriptDisplaySettings.showsAssistantTurnHeader(
            role: "assistant",
            hasTextContent: false,
            isEnabled: true
        ))
    }

    func testAssistantTurnHeaderHiddenForNonAssistantRoles() {
        for role in ["user", "system", "tool", "local_assistant", "local_notice"] {
            XCTAssertFalse(
                ChatTranscriptDisplaySettings.showsAssistantTurnHeader(
                    role: role,
                    hasTextContent: true,
                    isEnabled: true
                ),
                "Header must not render for role \(role)"
            )
        }

        XCTAssertFalse(ChatTranscriptDisplaySettings.showsAssistantTurnHeader(
            role: nil,
            hasTextContent: true,
            isEnabled: true
        ))
    }

    func testContentWithoutAttachedFilesMarkerStripsTrailingMarker() {
        // Mirrors the exact format PendingAttachment.chatMessageText appends.
        let sent = "Analyze these files\n\n[Attached files: /tmp/workspace/sample.html, /tmp/workspace/image.jpg]"
        XCTAssertEqual(
            MessageAttachment.contentWithoutAttachedFilesMarker(in: sent),
            "Analyze these files"
        )
    }

    func testContentWithoutAttachedFilesMarkerReturnsEmptyForAttachmentOnlyMessage() {
        // No typed draft: the whole content is just the appended marker.
        let sent = "\n\n[Attached files: /tmp/workspace/image.jpg]"
        XCTAssertEqual(MessageAttachment.contentWithoutAttachedFilesMarker(in: sent), "")
    }

    func testContentWithoutAttachedFilesMarkerPreservesInteriorNewlines() {
        let sent = "line one\nline two\n\n[Attached files: /tmp/a.png]"
        XCTAssertEqual(
            MessageAttachment.contentWithoutAttachedFilesMarker(in: sent),
            "line one\nline two"
        )
    }

    func testContentWithoutAttachedFilesMarkerLeavesPlainMessageUnchanged() {
        let plain = "Just a normal message with no attachments"
        XCTAssertEqual(MessageAttachment.contentWithoutAttachedFilesMarker(in: plain), plain)
    }

    func testContentWithoutAttachedFilesMarkerIgnoresMarkerWithTrailingText() {
        // The parser only treats the marker as a suffix; trailing prose means it
        // is not a real attachment marker, so the content is left untouched.
        let content = "hello\n\n[Attached files: /tmp/a.png] and then more text"
        XCTAssertEqual(MessageAttachment.contentWithoutAttachedFilesMarker(in: content), content)
    }
}

final class ChatActiveRunStatusPolicyTests: XCTestCase {
    func testStatusHidesWhenTranscriptBottomIsVisible() {
        XCTAssertNil(ChatActiveRunStatusPolicy.presentation(
            isStartingChat: false,
            hasActiveStream: true,
            activeStreamRecoveryState: .idle,
            isCancellingStream: false,
            isScrolledNearBottom: true
        ))
    }

    func testStatusShowsActiveRunWhenScrolledAwayFromBottom() {
        let presentation = ChatActiveRunStatusPolicy.presentation(
            isStartingChat: false,
            hasActiveStream: true,
            activeStreamRecoveryState: .idle,
            isCancellingStream: false,
            isScrolledNearBottom: false
        )

        XCTAssertEqual(presentation?.kind, .active)
        XCTAssertEqual(presentation?.label, "Hermes is working")
    }

    func testStatusShowsStartingBeforeStreamIDExists() {
        let presentation = ChatActiveRunStatusPolicy.presentation(
            isStartingChat: true,
            hasActiveStream: false,
            activeStreamRecoveryState: .idle,
            isCancellingStream: false,
            isScrolledNearBottom: false
        )

        XCTAssertEqual(presentation?.kind, .starting)
    }

    func testStatusPrioritizesRecoveryStateOverGenericActiveRun() {
        let presentation = ChatActiveRunStatusPolicy.presentation(
            isStartingChat: false,
            hasActiveStream: true,
            activeStreamRecoveryState: .reconnecting,
            isCancellingStream: false,
            isScrolledNearBottom: false
        )

        XCTAssertEqual(presentation?.kind, .reconnecting)
        XCTAssertEqual(presentation?.accessibilityLabel, "Hermes is reconnecting the response stream")
    }

    func testStatusPrioritizesCancellationOverOtherStates() {
        let presentation = ChatActiveRunStatusPolicy.presentation(
            isStartingChat: true,
            hasActiveStream: true,
            activeStreamRecoveryState: .checking,
            isCancellingStream: true,
            isScrolledNearBottom: false
        )

        XCTAssertEqual(presentation?.kind, .stopping)
    }

    func testStatusHidesWhenIdleAndNoRunIsStarting() {
        XCTAssertNil(ChatActiveRunStatusPolicy.presentation(
            isStartingChat: false,
            hasActiveStream: false,
            activeStreamRecoveryState: .idle,
            isCancellingStream: false,
            isScrolledNearBottom: false
        ))
    }

    func testStatusShowsConnectingOnColdOpenEvenAtBottom() {
        let presentation = ChatActiveRunStatusPolicy.presentation(
            isStartingChat: false,
            hasActiveStream: false,
            activeStreamRecoveryState: .idle,
            isCancellingStream: false,
            isScrolledNearBottom: true,
            isEstablishingConnection: true
        )

        XCTAssertEqual(presentation?.kind, .connecting)
        XCTAssertEqual(presentation?.label, "Connecting…")
        XCTAssertEqual(presentation?.accessibilityLabel, "Connecting to conversation")
    }

    func testConnectingStaysHiddenWhileACachedTranscriptIsAlreadyOnScreen() {
        XCTAssertFalse(
            ChatConnectionStatusPolicy.shouldShowConnecting(
                isLoading: true,
                hasPaintedTranscript: true,
                hasActiveStream: false,
                isStartingChat: false,
                isVisiblySlow: true
            )
        )
    }

    func testConnectingStaysHiddenUntilTheLoadIsVisiblySlow() {
        XCTAssertFalse(
            ChatConnectionStatusPolicy.shouldShowConnecting(
                isLoading: true,
                hasPaintedTranscript: false,
                hasActiveStream: false,
                isStartingChat: false,
                isVisiblySlow: false
            )
        )
        XCTAssertTrue(
            ChatConnectionStatusPolicy.shouldShowConnecting(
                isLoading: true,
                hasPaintedTranscript: false,
                hasActiveStream: false,
                isStartingChat: false,
                isVisiblySlow: true
            )
        )
    }

    func testConnectingYieldsToAnAlreadyLiveStream() {
        let presentation = ChatActiveRunStatusPolicy.presentation(
            isStartingChat: false,
            hasActiveStream: true,
            activeStreamRecoveryState: .reconnecting,
            isCancellingStream: false,
            isScrolledNearBottom: false,
            isEstablishingConnection: true
        )

        XCTAssertEqual(presentation?.kind, .reconnecting)
    }
}

final class AssistantTurnTimestampFormatterTests: XCTestCase {
    // 2021-01-01 14:14:00 UTC
    private let fixedTimestamp: Double = 1_609_510_440
    private let utc = TimeZone(identifier: "UTC")!

    func testFormatsTwelveHourLocaleAsShortTime() {
        let result = AssistantTurnTimestampFormatter.shortTime(
            forUnixTimestamp: fixedTimestamp,
            locale: Locale(identifier: "en_US"),
            timeZone: utc
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("2:14") == true, "Expected 12h time, got \(result ?? "nil")")
        XCTAssertTrue(result?.contains("PM") == true, "Expected PM marker, got \(result ?? "nil")")
    }

    func testFormatsTwentyFourHourLocaleAsShortTime() {
        let result = AssistantTurnTimestampFormatter.shortTime(
            forUnixTimestamp: fixedTimestamp,
            locale: Locale(identifier: "en_GB"),
            timeZone: utc
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("14:14") == true, "Expected 24h time, got \(result ?? "nil")")
        XCTAssertFalse(result?.contains("PM") == true, "24h time must not carry a PM marker")
    }

    func testReturnsNilForNilTimestamp() {
        XCTAssertNil(AssistantTurnTimestampFormatter.shortTime(forUnixTimestamp: nil))
        XCTAssertNil(AssistantTurnTimestampFormatter.shortTime(
            forUnixTimestamp: nil,
            locale: Locale(identifier: "en_US"),
            timeZone: utc
        ))
    }

    func testReturnsNilForNonFiniteTimestamp() {
        XCTAssertNil(AssistantTurnTimestampFormatter.shortTime(forUnixTimestamp: .nan))
        XCTAssertNil(AssistantTurnTimestampFormatter.shortTime(forUnixTimestamp: .infinity))
    }

    func testCurrentLocaleOverloadFormatsFiniteTimestamp() {
        XCTAssertNotNil(AssistantTurnTimestampFormatter.shortTime(forUnixTimestamp: fixedTimestamp))
    }
}

final class ResponseSpeedFormatterTests: XCTestCase {
    func testFormatsOneDecimalWithCompactAndAccessibleUnits() {
        let locale = Locale(identifier: "en_US")

        XCTAssertEqual(ResponseSpeedFormatter.compactText(12.34, locale: locale), "12.3 t/s")
        XCTAssertEqual(
            ResponseSpeedFormatter.accessibilityText(12.34, locale: locale),
            "12.3 tokens per second"
        )
    }

    func testReturnsNilForMissingNonPositiveOrNonFiniteValues() {
        XCTAssertNil(ResponseSpeedFormatter.compactText(nil))
        XCTAssertNil(ResponseSpeedFormatter.compactText(0))
        XCTAssertNil(ResponseSpeedFormatter.compactText(-1))
        XCTAssertNil(ResponseSpeedFormatter.compactText(.infinity))
        XCTAssertNil(ResponseSpeedFormatter.compactText(.nan))
    }
}
