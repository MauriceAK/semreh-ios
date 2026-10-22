import Foundation
import XCTest
@testable import HermesCompanion

final class ConversationDisplayCacheTests: XCTestCase {
    private func grant(device: String = "device", profile: String = "test", path: String = "/host/a") -> DeviceGrant {
        .init(baseURL: "https://example.invalid" + path, deviceID: device, token: "excluded-token", host: .init(name: "Test", profile: profile))
    }
    private func entry(_ id: String = "conversation", scope: HostScope, text: String = "Canonical", viewedAt: Date = Date()) throws -> CachedConversation {
        var window = TranscriptWindow()
        try window.replace(.init(messages: [.init(id: "row", role: "assistant", text: text, provisional: false)], before: nil, hasMore: false))
        return .init(scope: scope, session: .init(id: id, title: "Cached title", updatedAt: "", profile: scope.profile), window: DisplayWindow(window), recentTail: nil, reader: .anchored(messageID: "row", offsetFromUsableTop: 24), fetchedAt: Date(), viewedAt: viewedAt)
    }
    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    func testRoundTripContainsOnlyCanonicalDisplayDataAndRestoresReaderWindow() async throws {
        let directory = temporaryDirectory()
        let scope = HostScope(grant())
        var window = TranscriptWindow()
        for lower in stride(from: 480, through: 0, by: -120) {
            let rows = (lower..<(lower + 120)).map { ChatMessage(id: String($0), role: "assistant", text: "Row \($0)", provisional: false) }
            let page = HistoryPage(messages: rows, before: String(lower), hasMore: true)
            if window.messages.isEmpty { try window.replace(page) } else { try window.prepend(page) }
        }
        XCTAssertEqual(window.messages.count, 500)
        let cached = CachedConversation(scope: scope, session: .init(id: "long", title: "Long", updatedAt: "", profile: "test"), window: DisplayWindow(window), recentTail: nil, reader: .anchored(messageID: "200", offsetFromUsableTop: -12), fetchedAt: Date())
        await ConversationDisplayCache(directory: directory).remember(cached)
        let restoredValue = await ConversationDisplayCache(directory: directory).conversation("long", in: scope)
        let restored = try XCTUnwrap(restoredValue)
        var transcript = TranscriptWindow()
        try transcript.restore(restored.window)
        XCTAssertEqual(transcript.messages.count, 500)
        XCTAssertTrue(transcript.hasNewer)
        XCTAssertEqual(restored.reader, .anchored(messageID: "200", offsetFromUsableTop: -12))
        var filtering = TranscriptWindow()
        try filtering.replace(.init(messages: [
            .init(id: "final", role: "user", text: "Saved", provisional: false,
                attachments: [.init(id: "private-ticket", name: "report.pdf", mediaType: "application/pdf", byteCount: 100, status: "ready")]),
            .init(id: "provisional", role: "assistant", text: "Unsaved stream", provisional: true),
            .init(id: "pending", role: "user", text: "Unsaved send", provisional: false, delivery: .sending)
        ], before: nil, hasMore: false))
        let display = DisplayWindow(filtering)
        XCTAssertEqual(display.rows.map(\.id), ["final"])
        let encoded = String(decoding: try JSONEncoder().encode(display), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-ticket"))
        XCTAssertFalse(encoded.contains("Unsaved"))
        XCTAssertTrue(display.rows[0].message.displayText.contains("report.pdf"))
    }
    func testScopesIncludeEndpointDeviceAndProfileAndExcludeToken() async throws {
        let cache = ConversationDisplayCache(directory: temporaryDirectory())
        let original = HostScope(grant())
        await cache.remember(try entry(scope: original))
        for other in [HostScope(grant(device: "other")), HostScope(grant(profile: "other")), HostScope(grant(path: "/host/b"))] {
            let value = await cache.conversation("conversation", in: other)
            XCTAssertNil(value)
        }
        let changedToken = DeviceGrant(baseURL: "https://EXAMPLE.invalid:443/host/a/", deviceID: "device", token: "another-token", host: .init(name: "Renamed", profile: "test"))
        XCTAssertEqual(original, HostScope(changedToken))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(original), as: UTF8.self).contains("token"))
    }
    func testCorruptUnknownVersionAndOversizeEntriesAreMisses() async throws {
        for corruption in [Data("truncated".utf8), Data(#"{"version":42}"#.utf8), Data(repeating: 65, count: ConversationDisplayCache.maxFileBytes + 1)] {
            let directory = temporaryDirectory()
            let cache = ConversationDisplayCache(directory: directory)
            let scope = HostScope(grant())
            await cache.remember(try entry(scope: scope))
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first { $0.lastPathComponent != "index.json" })
            try corruption.write(to: file)
            let value = await ConversationDisplayCache(directory: directory).conversation("conversation", in: scope)
            XCTAssertNil(value)
        }
    }
    func testCacheEvictionAndRetirementPreserveOtherScope() async throws {
        let cache = ConversationDisplayCache(directory: temporaryDirectory())
        let scope = HostScope(grant())
        for index in 0..<22 {
            await cache.remember(try entry("session-\(index)", scope: scope, viewedAt: Date(timeIntervalSince1970: Double(index))))
        }
        let sessions = await cache.sessions(in: scope)
        XCTAssertEqual(sessions.count, 20)
        XCTAssertFalse(sessions.contains { $0.id == "session-0" })
        let other = HostScope(grant(device: "other"))
        await cache.remember(try entry(scope: other))
        await cache.retire(scope)
        let retained = await cache.conversation("conversation", in: other)
        XCTAssertNotNil(retained)
    }
    @MainActor func testNewJournalRecordsAreScopedAndLegacyRecordsRemainUnassigned() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"[{"operationID":"legacy","sessionID":"conversation","kind":"send"}]"#.utf8), forKey: "pending-operations-v1")
        let journal = OperationJournal(defaults: defaults)
        journal.begin(.init(operationId: "new", kind: "send"), sessionID: "conversation", scope: HostScope(grant()))
        let restored = OperationJournal(defaults: defaults)
        XCTAssertNil(restored.pending.first?.scope)
        XCTAssertEqual(restored.pending.last?.scope, HostScope(grant()))
        XCTAssertEqual(restored.pending.count, 2)
    }
}
