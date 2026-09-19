import CryptoKit
import Foundation

/// Durable identity for a prompt whose delivery outcome is not proven. Unlike
/// attachment recovery, this deliberately excludes the runtime ID so the
/// barrier survives a fresh `session.resume` binding after app termination.
struct DirectPromptDeliveryUncertaintyIdentity: Codable, Equatable, Sendable {
    let origin: String
    let profile: String
    let storedID: String

    private enum CodingKeys: String, CodingKey { case origin, profile, storedID }

    init(origin: URL, profile: String, storedID: String) throws {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw DirectPromptDeliveryUncertaintyStoreError.invalidIdentity
        }
        components.scheme = scheme
        components.host = host
        if (scheme == "http" && components.port == 80) ||
            (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        components.path = ""
        guard let normalizedOrigin = components.url?.absoluteString else {
            throw DirectPromptDeliveryUncertaintyStoreError.invalidIdentity
        }
        let normalizedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStoredID = storedID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProfile.isEmpty, !normalizedStoredID.isEmpty else {
            throw DirectPromptDeliveryUncertaintyStoreError.invalidIdentity
        }
        self.origin = normalizedOrigin
        self.profile = normalizedProfile
        self.storedID = normalizedStoredID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let origin = URL(string: try container.decode(String.self, forKey: .origin)) else {
            throw DirectPromptDeliveryUncertaintyStoreError.invalidIdentity
        }
        try self.init(
            origin: origin,
            profile: try container.decode(String.self, forKey: .profile),
            storedID: try container.decode(String.self, forKey: .storedID)
        )
    }
}

struct DirectPromptDeliveryUncertaintyMarker: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case unresolved }

    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let token: UUID
    let identity: DirectPromptDeliveryUncertaintyIdentity
    let status: Status
    let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, token, identity, status, createdAt
    }

    init(
        token: UUID = UUID(),
        identity: DirectPromptDeliveryUncertaintyIdentity,
        status: Status = .unresolved,
        createdAt: Date = Date()
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.token = token
        self.identity = identity
        self.status = status
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DirectPromptDeliveryUncertaintyStoreError.unsupportedSchema
        }
        schemaVersion = version
        token = try container.decode(UUID.self, forKey: .token)
        identity = try container.decode(DirectPromptDeliveryUncertaintyIdentity.self, forKey: .identity)
        status = try container.decode(Status.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

protocol DirectPromptDeliveryUncertaintyStoreProtocol: AnyObject {
    func load(for identity: DirectPromptDeliveryUncertaintyIdentity) throws -> DirectPromptDeliveryUncertaintyMarker?
    func candidates(for identity: DirectPromptDeliveryUncertaintyIdentity, limit: Int) throws -> [DirectPromptDeliveryUncertaintyMarker]
    func write(_ marker: DirectPromptDeliveryUncertaintyMarker) throws
    func remove(_ marker: DirectPromptDeliveryUncertaintyMarker) throws
}

enum DirectPromptDeliveryUncertaintyStoreError: Error, Equatable, Sendable {
    case invalidIdentity
    case corrupt
    case unsupportedSchema
    case tokenMismatch
    case missing
    case io
    case candidateLimitExceeded
}

/// Metadata-only, one-file-per-chat persistence. It never stores prompt text,
/// attachments, credentials, or a runtime ID.
final class DirectPromptDeliveryUncertaintyStore: DirectPromptDeliveryUncertaintyStoreProtocol {
    private let fileManager: FileManager
    private let rootURL: URL

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "HermesMobile/DirectPromptDeliveryUncertainty",
            isDirectory: true
        )
    }

    func load(for identity: DirectPromptDeliveryUncertaintyIdentity) throws -> DirectPromptDeliveryUncertaintyMarker? {
        let url = try markerURL(for: identity)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            throw DirectPromptDeliveryUncertaintyStoreError.io
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch { throw DirectPromptDeliveryUncertaintyStoreError.io }
        do {
            let marker = try JSONDecoder().decode(DirectPromptDeliveryUncertaintyMarker.self, from: data)
            guard marker.identity == identity else {
                throw DirectPromptDeliveryUncertaintyStoreError.corrupt
            }
            return marker
        } catch let error as DirectPromptDeliveryUncertaintyStoreError {
            throw error
        } catch let error as DecodingError {
            if case .dataCorrupted(let context) = error,
               context.codingPath.contains(where: { $0.stringValue == "schemaVersion" }) {
                throw DirectPromptDeliveryUncertaintyStoreError.unsupportedSchema
            }
            throw DirectPromptDeliveryUncertaintyStoreError.corrupt
        } catch {
            throw DirectPromptDeliveryUncertaintyStoreError.corrupt
        }
    }

    func write(_ marker: DirectPromptDeliveryUncertaintyMarker) throws {
        let url = try markerURL(for: marker.identity)
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(marker).write(to: url, options: [.atomic])
        } catch let error as DirectPromptDeliveryUncertaintyStoreError {
            throw error
        } catch {
            throw DirectPromptDeliveryUncertaintyStoreError.io
        }
    }

    /// Legacy filenames hash the entire identity, so discovery must inspect the
    /// flat directory. Only valid, attributable records participate. An invalid
    /// legacy record cannot be scoped here; exact-ID load still fails closed.
    func candidates(for identity: DirectPromptDeliveryUncertaintyIdentity, limit: Int) throws -> [DirectPromptDeliveryUncertaintyMarker] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else { return [] }
        guard isDirectory.boolValue else { throw DirectPromptDeliveryUncertaintyStoreError.io }
        let urls: [URL]
        do { urls = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) }
        catch { throw DirectPromptDeliveryUncertaintyStoreError.io }
        var result: [DirectPromptDeliveryUncertaintyMarker] = []
        for url in urls where url.lastPathComponent.hasPrefix("marker-") && url.pathExtension == "json" {
            guard let metadata = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  metadata.isRegularFile == true,
                  let size = metadata.fileSize, size <= 16_384,
                  let data = try? Data(contentsOf: url),
                  let marker = try? JSONDecoder().decode(DirectPromptDeliveryUncertaintyMarker.self, from: data),
                  marker.identity.origin == identity.origin,
                  marker.identity.profile == identity.profile,
                  try markerURL(for: marker.identity) == url else { continue }
            guard result.count < limit else { throw DirectPromptDeliveryUncertaintyStoreError.candidateLimitExceeded }
            result.append(marker)
        }
        return result.sorted { $0.identity.storedID < $1.identity.storedID }
    }

    func remove(_ marker: DirectPromptDeliveryUncertaintyMarker) throws {
        let url = try markerURL(for: marker.identity)
        guard let current = try load(for: marker.identity) else {
            throw DirectPromptDeliveryUncertaintyStoreError.missing
        }
        guard current.token == marker.token else {
            throw DirectPromptDeliveryUncertaintyStoreError.tokenMismatch
        }
        do { try fileManager.removeItem(at: url) }
        catch { throw DirectPromptDeliveryUncertaintyStoreError.io }
    }

    func markerURL(for identity: DirectPromptDeliveryUncertaintyIdentity) throws -> URL {
        let material = "\(identity.origin)\u{0}\(identity.profile)\u{0}\(identity.storedID)"
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return rootURL.appendingPathComponent("marker-\(digest).json", isDirectory: false)
    }
}
