#if DEBUG
import Foundation

/// Pure replay logic for the Streaming Lab (issue #234): a canned markdown
/// fixture plus the pacing math that decides how many word units each tick
/// reveals. Pure so it is unit-testable; the view owns the actual timer.
///
/// Word units come from `StreamingWordDrain`, the same splitter production
/// uses for #212 pacing, so `prefix(of:unitCount:)` can never alter content —
/// the final prefix is exactly the fixture.
enum StreamingLabReplay {
    /// Matches the production word-reveal cadence in `ChatViewModel`
    /// (one unit per 48ms tick), so the default lab speed feels like a real
    /// reply and higher speeds reveal several words per tick — the chunky
    /// #212 backlog-catch-up arrival pattern.
    static let tickInterval: TimeInterval = 0.048

    static let defaultWordsPerSecond: Double = 21
    static let minWordsPerSecond: Double = 2
    static let maxWordsPerSecond: Double = 80

    /// Exercises every shape the fade pipeline treats differently: short
    /// paragraphs, one long wrapping paragraph, a heading, a flat bullet
    /// list, a nested list, and a code fence (which reveals unfaded).
    static let fixture = """
    Hermes is a self-hosted agent you carry in your pocket. This first \
    paragraph is short on purpose.

    A second short paragraph follows the first one, so the block boundary \
    between them gets exercised on every single replay.

    # How the fade should feel

    This is the long wrapping paragraph. It keeps going for long enough \
    that the renderer has to wrap it across several lines on an iPhone, \
    because the most important part of the Telegram-style effect is how a \
    word drops to the start of the next line while it is still invisible \
    and then fades up in place, with the gradient sweeping smoothly across \
    the whole width of the bubble instead of popping line by line.

    - First flat bullet about pacing
    - Second flat bullet about the gradient width
    - Third flat bullet about absorption

    1. Ordered parent item
       - Nested child that must stay inside its parent block
       - Second nested child to stretch the nested case
    2. Second ordered parent item

    ```swift
    // Code fences reveal instantly, with no fade.
    let knobs = StreamingTextFadeDefaults.self
    ```

    A closing paragraph after the fence, so the replay always ends on \
    fadeable text and the completion linger is visible at the very end.
    """

    /// Deterministic, server-free workload metadata for regression runs. It
    /// describes the same content classes exercised by the native performance
    /// fixture without pretending a synthetic replay is a device acceptance
    /// result. Payloads stay compact: the corpus is generated from these
    /// templates instead of retaining hundreds of copied strings.
    enum FixtureContentKind: String, CaseIterable {
        case richMarkdown = "rich_markdown"
        case code
        case tool
        case media
    }

    struct CorpusMetadata: Equatable {
        let conversationCount: Int
        let messagesPerConversation: Int
        let totalMessageCount: Int
        let approximateUTF8Bytes: Int
        let contentKinds: Set<FixtureContentKind>

        var report: String {
            let kinds = contentKinds.map(\.rawValue).sorted().joined(separator: ",")
            return "synthetic_fixture=true conversations=\(conversationCount) "
                + "messages_per_conversation=\(messagesPerConversation) "
                + "total_messages=\(totalMessageCount) approximate_utf8_bytes=\(approximateUTF8Bytes) "
                + "content_kinds=\(kinds) native_device_acceptance=required_separately"
        }
    }

    static let regressionConversationCount = 12
    static let regressionMessagesPerConversation = 50

    static var fixtureUnitCount: Int {
        StreamingWordDrain.unitCount(in: fixture)
    }

    static var corpusMetadata: CorpusMetadata {
        let templates = regressionMessageTemplates
        let bytesPerConversation = (0..<regressionMessagesPerConversation).reduce(into: 0) { total, index in
            total += templates[index % templates.count].payload.utf8.count
        }
        return CorpusMetadata(
            conversationCount: regressionConversationCount,
            messagesPerConversation: regressionMessagesPerConversation,
            totalMessageCount: regressionConversationCount * regressionMessagesPerConversation,
            approximateUTF8Bytes: bytesPerConversation * regressionConversationCount,
            contentKinds: Set(templates.map(\.kind))
        )
    }

    /// Returns one deterministic conversation from the realistic-size corpus.
    /// The lab still mounts only one conversation at a time so opting in does
    /// not silently turn normal app launch into a performance workload.
    static func regressionConversation(at index: Int) -> String {
        guard regressionConversationCount > 0 else { return "" }
        let conversation = min(max(index, 0), regressionConversationCount - 1)
        let templates = regressionMessageTemplates
        return (0..<regressionMessagesPerConversation).map { message in
            let template = templates[(conversation + message) % templates.count]
            return "## Message \(message + 1) · \(template.kind.rawValue)\n\n\(template.payload)"
        }.joined(separator: "\n\n---\n\n")
    }

    private static let regressionMessageTemplates: [(kind: FixtureContentKind, payload: String)] = [
        (.richMarkdown, fixture),
        (.code, """
        ```swift
        struct Row: Identifiable { let id: Int; let title: String }
        let rows = (0..<250).map { Row(id: $0, title: "Row \\($0)") }
        ```
        """),
        (.tool, """
        **Tool activity fixture** — `read_file` completed with a bounded preview.

        ```json
        {"path":"Sources/Transcript.swift","lines":240,"truncated":true}
        ```
        """),
        (.media, """
        Media references exercise parser paths without network access:
        MEDIA:/fixtures/performance/image-01.png
        MEDIA:/fixtures/performance/clip-01.m4a
        MEDIA:/fixtures/performance/document-01.pdf
        """)
    ]

    /// First `unitCount` word units of `text`.
    static func prefix(of text: String, unitCount: Int) -> String {
        StreamingWordDrain.splitAtUnitBoundary(text, unitCount: unitCount).head
    }

    /// One tick of replay progress. `carry` accumulates the fractional unit
    /// budget so slow speeds still advance (every tick banks
    /// `tickInterval * wordsPerSecond` units and reveals the whole ones),
    /// and a mid-replay speed change simply changes the next tick's deposit.
    static func advance(
        revealed: Int,
        carry: Double,
        wordsPerSecond: Double,
        tickInterval: TimeInterval = tickInterval
    ) -> (revealed: Int, carry: Double) {
        let budget = max(0, carry) + max(0, wordsPerSecond) * max(0, tickInterval)
        let wholeUnits = Int(budget)
        return (revealed + wholeUnits, budget - Double(wholeUnits))
    }
}
#endif
