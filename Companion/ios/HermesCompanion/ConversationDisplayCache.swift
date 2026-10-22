import CryptoKit
import Foundation

struct HostScope: Codable, Hashable, Sendable {
    let endpoint: String
    let deviceID: String
    let profile: String

    init(_ grant: DeviceGrant) {
        var url = URLComponents(string: grant.baseURL)!
        url.scheme = url.scheme?.lowercased()
        url.host = url.host?.lowercased()
        if (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80) { url.port = nil }
        while url.path.hasSuffix("/") { url.path.removeLast() }
        endpoint = url.string!
        deviceID = grant.deviceID
        profile = grant.host.profile
    }
}

enum ReaderPosition: Codable, Equatable, Sendable {
    case latest
    case anchored(messageID: String, offsetFromUsableTop: Double)
}

struct ReaderRestoration: Equatable, Sendable {
    let id: UUID
    let position: ReaderPosition
}

struct DisplayAttachment: Codable, Equatable, Sendable {
    let name: String
    let mediaType: String
}

struct CanonicalDisplayMessage: Codable, Equatable, Sendable {
    let id: String
    let role: String
    let text: String
    let createdAt: String?
    let operationID: String?
    let attachments: [DisplayAttachment]

    init(_ message: ChatMessage) {
        id = message.id
        role = message.role
        text = message.text
        createdAt = message.createdAt
        operationID = message.operationId
        attachments = message.attachments?.map { .init(name: $0.name, mediaType: $0.mediaType) } ?? message.displayAttachments ?? []
    }

    var message: ChatMessage {
        .init(id: id, role: role, text: text, createdAt: createdAt, provisional: false,
              operationId: operationID, displayAttachments: attachments.isEmpty ? nil : attachments)
    }
    var byteCount: Int { message.byteCount }
}

struct DisplayWindow: Codable, Sendable {
    let rows: [CanonicalDisplayMessage]
    let before: String?
    let hasMore: Bool
    let hasNewer: Bool

    init(_ window: TranscriptWindow) {
        rows = window.messages.filter { !$0.provisional && $0.delivery == nil }.map(CanonicalDisplayMessage.init)
        before = window.before
        hasMore = window.hasMore
        hasNewer = window.hasNewer
    }
    var byteCount: Int { rows.reduce(0) { $0 + $1.byteCount } }

    func validate() throws {
        guard rows.count <= TranscriptWindow.maxRows, byteCount <= TranscriptWindow.maxBytes,
              Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ !$0.id.isEmpty && ["user", "assistant", "system"].contains($0.role) }) else {
            throw ClientError.invalidResponse
        }
    }
}

struct CachedConversation: Codable, Sendable {
    let scope: HostScope
    let session: ChatSession
    let window: DisplayWindow
    let recentTail: DisplayWindow?
    var reader: ReaderPosition
    let fetchedAt: Date
    var viewedAt: Date

    init(scope: HostScope, session: ChatSession, window: DisplayWindow, recentTail: DisplayWindow?, reader: ReaderPosition, fetchedAt: Date, viewedAt: Date = Date()) {
        self.scope = scope
        self.session = session
        self.window = window
        if let recentTail, window.hasNewer,
           window.rows.count + recentTail.rows.count <= TranscriptWindow.maxRows,
           window.byteCount + recentTail.byteCount <= TranscriptWindow.maxBytes {
            self.recentTail = recentTail
        } else { self.recentTail = nil }
        self.reader = reader
        self.fetchedAt = fetchedAt
        self.viewedAt = viewedAt
    }
    var byteCount: Int { window.byteCount + (recentTail?.byteCount ?? 0) }
    func validate() throws {
        try window.validate()
        try recentTail?.validate()
        guard !session.id.isEmpty, session.id.utf8.count <= 1024, session.title.utf8.count <= 4096, session.updatedAt.utf8.count <= 128,
              scope.endpoint.utf8.count <= 4096, scope.deviceID.utf8.count <= 1024, scope.profile.utf8.count <= 1024,
              session.profile == scope.profile,
              window.rows.count + (recentTail?.rows.count ?? 0) <= TranscriptWindow.maxRows,
              byteCount <= TranscriptWindow.maxBytes else { throw ClientError.invalidResponse }
        if case .anchored(let id, let offset) = reader {
            guard !id.isEmpty, offset.isFinite else { throw ClientError.invalidResponse }
        }
    }
}

actor ConversationDisplayCache {
    static let maxConversations = 20
    static let maxBytes = 32 * 1024 * 1024
    static let maxFileBytes = TranscriptWindow.maxBytes
    private static let maxIndexBytes = 512 * 1024
    private struct Record: Codable {
        let scope: HostScope
        let session: ChatSession
        let file: String
        let bytes: Int
        var viewedAt: Date
    }
    private struct Index: Codable {
        let version: Int
        var records: [Record]
    }
    private struct Envelope: Codable {
        let version: Int
        let conversation: CachedConversation
    }
    private let directory: URL
    private let beforeRead: (@Sendable () async -> Void)?
    private var index: Index?

    init(directory: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ConversationDisplay-v1", isDirectory: true), beforeRead: (@Sendable () async -> Void)? = nil) {
        self.directory = directory
        self.beforeRead = beforeRead
    }

    func sessions(in scope: HostScope) -> [ChatSession] {
        loadIndex()
        return index!.records.filter { $0.scope == scope }.sorted { $0.viewedAt > $1.viewedAt }.map(\.session)
    }

    func conversation(_ id: String, in scope: HostScope) async -> CachedConversation? {
        await beforeRead?()
        loadIndex()
        guard let record = index!.records.first(where: { $0.scope == scope && $0.session.id == id }) else { return nil }
        let url = directory.appendingPathComponent(record.file)
        do {
            let data = try boundedData(at: url, limit: Self.maxFileBytes)
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, envelope.conversation.scope == scope,
                  envelope.conversation.session.id == id else { throw ClientError.invalidResponse }
            try envelope.conversation.validate()
            return envelope.conversation
        } catch {
            index!.records.removeAll { $0.file == record.file }
            try? FileManager.default.removeItem(at: url)
            persistIndex()
            return nil
        }
    }

    func remember(_ conversation: CachedConversation) {
        loadIndex()
        do {
            try conversation.validate()
            let data = try JSONEncoder().encode(Envelope(version: 1, conversation: conversation))
            guard data.count <= Self.maxFileBytes else { return }
            try prepareDirectory()
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let key = try encoder.encode(conversation.scope) + Data(conversation.session.id.utf8)
            let file = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined() + ".json"
            try write(data, to: directory.appendingPathComponent(file))
            index!.records.removeAll { $0.file == file }
            index!.records.append(.init(scope: conversation.scope, session: conversation.session, file: file, bytes: data.count, viewedAt: conversation.viewedAt))
            index!.records.sort { $0.viewedAt > $1.viewedAt }
            while index!.records.count > Self.maxConversations || index!.records.reduce(0, { $0 + $1.bytes }) > Self.maxBytes - Self.maxIndexBytes {
                let removed = index!.records.removeLast()
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(removed.file))
            }
            persistIndex()
        } catch {}
    }

    func retire(_ scope: HostScope) {
        loadIndex()
        let removed = index!.records.filter { $0.scope == scope }
        index!.records.removeAll { $0.scope == scope }
        for record in removed { try? FileManager.default.removeItem(at: directory.appendingPathComponent(record.file)) }
        persistIndex()
    }

    private func loadIndex() {
        guard index == nil else { return }
        if let data = try? boundedData(at: directory.appendingPathComponent("index.json"), limit: Self.maxIndexBytes),
           let decoded = try? JSONDecoder().decode(Index.self, from: data), decoded.version == 1,
           decoded.records.count <= Self.maxConversations,
           decoded.records.allSatisfy({ $0.file.count == 69 && $0.file.hasSuffix(".json") && !$0.file.contains("/") && (0...Self.maxFileBytes).contains($0.bytes) }),
           decoded.records.reduce(0, { $0 + $1.bytes }) <= Self.maxBytes - Self.maxIndexBytes {
            index = decoded
        } else { index = .init(version: 1, records: []) }
        let retained = Set(index!.records.map(\.file) + ["index.json"])
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where !retained.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func boundedData(at url: URL, limit: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= limit else { throw ClientError.payloadTooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw ClientError.payloadTooLarge }
        return data
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func persistIndex() {
        guard let index else { return }
        do {
            try prepareDirectory()
            try write(JSONEncoder().encode(index), to: directory.appendingPathComponent("index.json"))
        } catch {}
    }
}
