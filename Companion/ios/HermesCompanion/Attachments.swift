import Foundation
import Observation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

struct AttachmentPayload: Codable, Sendable {
    let fileURL: URL
    let name: String
    let mediaType: String
    let byteCount: Int
    let previewURL: URL?
}
struct AttachmentTicket: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let mediaType: String
    let byteCount: Int
    let status: String
}
struct DraftAttachment: Identifiable, Codable, Sendable {
    enum State: Codable, Sendable {
        case importing
        case ready(AttachmentPayload)
        case failed(String)
    }
    let id: UUID
    var name: String
    var state: State
    var uploadOperationID = UUID().uuidString.lowercased()
    var ticket: AttachmentTicket?
    var uploadedAt: Date?
    var uploadError: String?
    var uncertainUpload = false
    var payload: AttachmentPayload? { if case .ready(let value) = state { return value }; return nil }
}

extension DraftAttachment {
    enum CodingKeys: String, CodingKey { case id, name, state, uploadOperationID, ticket, uploadedAt, uploadError, uncertainUpload }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        state = try values.decode(State.self, forKey: .state)
        uploadOperationID = try values.decodeIfPresent(String.self, forKey: .uploadOperationID) ?? id.uuidString.lowercased()
        ticket = try values.decodeIfPresent(AttachmentTicket.self, forKey: .ticket)
        uploadedAt = try values.decodeIfPresent(Date.self, forKey: .uploadedAt)
        uploadError = try values.decodeIfPresent(String.self, forKey: .uploadError)
        uncertainUpload = try values.decodeIfPresent(Bool.self, forKey: .uncertainUpload) ?? false
    }
}

@MainActor @Observable
final class AttachmentDrafts {
    nonisolated static let maxDrafts = 20
    nonisolated static let maxLocalBytes = 64 * 1024 * 1024
    nonisolated static let ticketLifetime: TimeInterval = 24 * 60 * 60
    nonisolated static let maxCount = 4
    nonisolated static let maxBytes = 5 * 1024 * 1024
    nonisolated static let maxTotalBytes = 16 * 1024 * 1024
    private var values: [String: [DraftAttachment]] = [:]
    private(set) var persistenceIssue: String?
    private let manifest: URL
    let directory: URL
    init(hostID: String) {
        let hash = SHA256.hash(data: Data(hostID.utf8)).map { String(format: "%02x", $0) }.joined()
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("AttachmentDrafts/" + hash, isDirectory: true)
        manifest = directory.appendingPathComponent("drafts.json")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var restored = false
        if let data = try? Data(contentsOf: manifest), let saved = try? JSONDecoder().decode([String: [DraftAttachment]].self, from: data) {
            restored = true
            values = saved.mapValues { items in items.map { item in
                var item = item
                if case .importing = item.state { item.state = .failed("Import interrupted. Remove this item and choose it again.") }
                if let payload = item.payload {
                    if let rebased = rebase(payload) { item.state = .ready(rebased) }
                    else { item.state = .failed("This local file is missing. Remove it and choose it again.") }
                }
                return item
            } }
        }
        values = values.filter { !$0.value.isEmpty }
        removeUnreferencedFiles()
        refreshExpiredTickets()
        if restored { persist() }
    }
    private func ownedFile(_ basename: String) -> URL? {
        guard UUID(uuidString: basename) != nil else { return nil }
        return directory.appendingPathComponent(basename)
    }
    private func isRegularOwnedFile(_ url: URL) -> Bool {
        guard let metadata = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
        return metadata.isRegularFile == true && metadata.isSymbolicLink != true
    }
    private func rebase(_ payload: AttachmentPayload) -> AttachmentPayload? {
        guard let file = ownedFile(payload.fileURL.lastPathComponent), isRegularOwnedFile(file) else { return nil }
        let preview = directory.appendingPathComponent(file.lastPathComponent + "-preview.jpg")
        return .init(fileURL: file, name: payload.name, mediaType: payload.mediaType, byteCount: payload.byteCount,
                     previewURL: payload.previewURL != nil && isRegularOwnedFile(preview) ? preview : nil)
    }
    private func removeUnreferencedFiles() {
        let items = values.values.flatMap { $0 }
        var retained = Set(items.flatMap { [$0.id.uuidString, $0.id.uuidString + "-preview.jpg"] })
        for item in items {
            if let payload = item.payload {
                retained.insert(payload.fileURL.lastPathComponent)
                if let preview = payload.previewURL { retained.insert(preview.lastPathComponent) }
            }
        }
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let name = url.lastPathComponent
            let stem = name.hasSuffix("-preview.jpg") ? String(name.dropLast("-preview.jpg".count)) : name
            if UUID(uuidString: stem) != nil, !retained.contains(name) { try? FileManager.default.removeItem(at: url) }
        }
    }
    var localByteCount: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.lastPathComponent != "drafts.json" }.reduce(0) { count, url in
            count + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
    func importRejection(for sessionID: String?) -> String? {
        let key = sessionID ?? "new-conversation"
        if (values[key] ?? []).isEmpty, values.values.filter({ !$0.isEmpty }).count >= Self.maxDrafts {
            return "Attachments are saved in 20 conversations. Remove an unsent attachment draft before adding another."
        }
        let importing = values.values.flatMap { $0 }.filter { if case .importing = $0.state { return true }; return false }.count
        let reservation = Self.maxBytes + 64 * 1024
        if localByteCount + (importing + 1) * reservation > Self.maxLocalBytes {
            return "Unsent attachments can use up to 64 MB on this phone. Remove an unsent attachment to make room."
        }
        return nil
    }
    func refreshExpiredTickets(now: Date = Date()) {
        var changed = false
        for key in Array(values.keys) {
            guard var items = values[key] else { continue }
            for index in items.indices where items[index].ticket != nil && !items[index].uncertainUpload {
                if now.timeIntervalSince(items[index].uploadedAt ?? .distantPast) >= Self.ticketLifetime {
                    if items[index].uploadError == nil {
                        items[index].uploadError = "Upload expired. Retry on send to upload it again."
                        changed = true
                    }
                }
            }
            values[key] = items
        }
        if changed { persist() }
    }
    func contains(_ id: UUID) -> Bool { values.values.contains { $0.contains { $0.id == id } } }
    func sessionID(for id: UUID) -> String? {
        let key = values.first { $0.value.contains { $0.id == id } }?.key
        return key == "new-conversation" ? nil : key
    }
    func items(for sessionID: String?) -> [DraftAttachment] { values[sessionID ?? "new-conversation"] ?? [] }
    func set(_ items: [DraftAttachment], for sessionID: String?) {
        let key = sessionID ?? "new-conversation"
        if items.isEmpty { values.removeValue(forKey: key) }
        else { values[key] = items }
        persist()
    }
    func update(_ id: UUID, sessionID: String?, _ change: (inout DraftAttachment) -> Void) {
        var items = items(for: sessionID)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
        set(items, for: sessionID)
    }
    func remove(_ ids: Set<UUID>, sessionID: String?) {
        let old = items(for: sessionID)
        set(old.filter { !ids.contains($0.id) }, for: sessionID)
        for item in old where ids.contains(item.id) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(item.id.uuidString))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(item.id.uuidString + "-preview.jpg"))
            if let payload = item.payload, let file = ownedFile(payload.fileURL.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file.lastPathComponent + "-preview.jpg"))
            }
        }
    }
    func moveNewDraft(to sessionID: String) {
        let items = items(for: nil)
        guard !items.isEmpty else { return }
        values["new-conversation"] = nil
        set(items, for: sessionID)
    }
    private func persist() {
        do {
            let data = try JSONEncoder().encode(values)
            try data.write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            persistenceIssue = nil
        } catch {
            persistenceIssue = "Attachments could not be saved on this phone. Keep the app open or choose them again later."
        }
    }
}

enum AttachmentImport {
    static func file(_ source: URL, directory: URL, id: UUID) async throws -> AttachmentPayload {
        try await Task.detached(priority: .userInitiated) {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            guard source.lastPathComponent.utf8.count <= 180 else { throw failure("Rename this file using a shorter name, then choose it again.") }
            let metadata = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .contentTypeKey])
            guard metadata.isRegularFile == true else { throw failure("Choose a file, rather than a folder.") }
            guard (metadata.fileSize ?? Int.max) <= AttachmentDrafts.maxBytes else { throw failure("Each file must be 5 MB or smaller.") }
            let data = try Data(contentsOf: source)
            let ext = source.pathExtension.lowercased()
            let textExtensions = ["txt", "md", "markdown", "csv", "json", "py", "js", "mjs", "swift", "c", "h", "cc", "cpp", "hpp", "html", "htm", "css", "xml", "yaml", "yml", "sh", "log"]
            let type: String
            if ["jpg", "jpeg"].contains(ext) { type = "image/jpeg" }
            else if ext == "png" { type = "image/png" }
            else if ext == "pdf" { type = "application/pdf" }
            else if textExtensions.contains(ext) || metadata.contentType?.conforms(to: .text) == true {
                guard data.count <= 128 * 1024 else { throw failure("Text and code files must be 128 KB or smaller.") }
                guard String(data: data, encoding: .utf8) != nil else { throw failure("Text files must use UTF-8 encoding.") }
                type = "text/plain"
            } else { throw failure("Choose a JPEG, PNG, PDF, or UTF-8 text or code file.") }
            return try save(data, name: source.lastPathComponent, mediaType: type, directory: directory, id: id)
        }.value
    }
    static func photo(_ data: Data, directory: URL, id: UUID) async throws -> AttachmentPayload {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else { throw failure("This photo could not be opened. Choose another photo.") }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw failure("This photo could not be prepared.") }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw failure("This photo could not be prepared.") }
            return try save(output as Data, name: "Photo.jpg", mediaType: "image/jpeg", directory: directory, id: id)
        }.value
    }
    private static func save(_ data: Data, name: String, mediaType: String, directory: URL, id: UUID) throws -> AttachmentPayload {
        guard !data.isEmpty else { throw failure("This file is empty.") }
        guard data.count <= AttachmentDrafts.maxBytes else { throw failure("Each attachment must be 5 MB or smaller.") }
        var thumbnail: CGImage?
        if mediaType == "image/jpeg" || mediaType == "image/png" {
            let expected = mediaType == "image/jpeg" ? UTType.jpeg.identifier : UTType.png.identifier
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetType(source) as String? == expected,
                  let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 112] as CFDictionary) else {
                throw failure("This image could not be opened. Choose a valid JPEG or PNG file.")
            }
            thumbnail = decoded
        }
        let url = directory.appendingPathComponent(id.uuidString)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var previewURL: URL?
        if let thumbnail {
            let preview = directory.appendingPathComponent(id.uuidString + "-preview.jpg")
            if let destination = CGImageDestinationCreateWithURL(preview as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, thumbnail, nil)
                if CGImageDestinationFinalize(destination) { previewURL = preview }
            }
        }
        return .init(fileURL: url, name: name, mediaType: mediaType, byteCount: data.count, previewURL: previewURL)
    }
    private static func failure(_ message: String) -> ClientError { .server(0, "attachment_import", message) }
}
