import CryptoKit
import Foundation

/// The stable scope used for an unresolved server-side attachment marker.
/// The runtime ID identifies the live Hermes queue; the stored ID is retained
/// as display/reconciliation metadata and is not part of the file key.
struct DirectGatewayAttachmentRecoveryIdentity: Codable, Equatable, Sendable {
    let origin: String
    let profile: String
    let storedID: String
    let runtimeID: String

    init(origin: URL, profile: String, storedID: String, runtimeID: String) throws {
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
            throw DirectGatewayAttachmentRecoveryMarkerStoreError.invalidIdentity
        }
        components.scheme = scheme
        components.host = host
        if (scheme == "http" && components.port == 80) ||
            (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        components.path = ""
        guard let normalizedOrigin = components.url?.absoluteString else {
            throw DirectGatewayAttachmentRecoveryMarkerStoreError.invalidIdentity
        }
        let normalizedProfile = profile.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStoredID = storedID.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRuntimeID = runtimeID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedProfile.isEmpty,
              !normalizedStoredID.isEmpty,
              !normalizedRuntimeID.isEmpty else {
            throw DirectGatewayAttachmentRecoveryMarkerStoreError.invalidIdentity
        }
        self.origin = normalizedOrigin
        self.profile = normalizedProfile
        self.storedID = normalizedStoredID
        self.runtimeID = normalizedRuntimeID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let origin = URL(string: try container.decode(String.self, forKey: .origin)) else {
            throw DirectGatewayAttachmentRecoveryMarkerStoreError.invalidIdentity
        }
        try self.init(
            origin: origin,
            profile: try container.decode(String.self, forKey: .profile),
            storedID: try container.decode(String.self, forKey: .storedID),
            runtimeID: try container.decode(String.self, forKey: .runtimeID)
        )
    }

    private enum CodingKeys: String, CodingKey { case origin, profile, storedID, runtimeID }
}

struct DirectGatewayAttachmentRecoveryMarker: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable { case unresolved }

    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let token: UUID
    let identity: DirectGatewayAttachmentRecoveryIdentity
    let status: Status

    init(
        token: UUID = UUID(),
        identity: DirectGatewayAttachmentRecoveryIdentity,
        status: Status = .unresolved
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.token = token
        self.identity = identity
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case token
        case identity
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DirectGatewayAttachmentRecoveryMarkerStoreError.unsupportedSchema
        }
        schemaVersion = version
        token = try container.decode(UUID.self, forKey: .token)
        identity = try container.decode(DirectGatewayAttachmentRecoveryIdentity.self, forKey: .identity)
        status = try container.decode(Status.self, forKey: .status)
    }
}

protocol DirectGatewayAttachmentRecoveryMarkerStoreProtocol: AnyObject {
    func load(for identity: DirectGatewayAttachmentRecoveryIdentity) throws -> DirectGatewayAttachmentRecoveryMarker?
    func write(_ marker: DirectGatewayAttachmentRecoveryMarker) throws
    /// Removes only the exact token currently stored for this identity.
    func remove(_ marker: DirectGatewayAttachmentRecoveryMarker) throws
}

enum DirectGatewayAttachmentRecoveryMarkerStoreError: Error, Equatable, Sendable {
    case invalidIdentity
    case corrupt
    case unsupportedSchema
    case tokenMismatch
    case missing
    case io
}

/// Durable, one-file-per-chat marker storage. The marker contains no bytes,
/// prompts, credentials, or client file paths. A caller must inject an
/// isolated root in tests; production uses the app-support namespace.
final class DirectGatewayAttachmentRecoveryMarkerStore: DirectGatewayAttachmentRecoveryMarkerStoreProtocol {
    private let fileManager: FileManager
    private let rootURL: URL

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(
            "HermesMobile/DirectGatewayAttachmentRecoveryMarkers",
            isDirectory: true
        )
    }

    func load(for identity: DirectGatewayAttachmentRecoveryIdentity) throws -> DirectGatewayAttachmentRecoveryMarker? {
        let url = try markerURL(for: identity)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            throw DirectGatewayAttachmentRecoveryMarkerStoreError.io
        }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch { throw DirectGatewayAttachmentRecoveryMarkerStoreError.io }
        do {
            let marker = try JSONDecoder().decode(DirectGatewayAttachmentRecoveryMarker.self, from: data)
            guard marker.identity.origin == identity.origin,
                  marker.identity.profile == identity.profile,
                  marker.identity.runtimeID == identity.runtimeID else {
                throw DirectGatewayAttachmentRecoveryMarkerStoreError.corrupt
            }
            return marker
        } catch let error as DirectGatewayAttachmentRecoveryMarkerStoreError {
            throw error
        } catch {
            throw DirectGatewayAttachmentRecoveryMarkerStoreError.corrupt
        }
    }

    func write(_ marker: DirectGatewayAttachmentRecoveryMarker) throws {
        let url = try markerURL(for: marker.identity)
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: nil
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(marker)
            try data.write(to: url, options: [.atomic])
        } catch let error as DirectGatewayAttachmentRecoveryMarkerStoreError {
            throw error
        } catch {
            throw DirectGatewayAttachmentRecoveryMarkerStoreError.io
        }
    }

    func remove(_ marker: DirectGatewayAttachmentRecoveryMarker) throws {
        let url = try markerURL(for: marker.identity)
        guard let current = try load(for: marker.identity) else {
            throw DirectGatewayAttachmentRecoveryMarkerStoreError.missing
        }
        guard current.token == marker.token else {
            throw DirectGatewayAttachmentRecoveryMarkerStoreError.tokenMismatch
        }
        do { try fileManager.removeItem(at: url) }
        catch { throw DirectGatewayAttachmentRecoveryMarkerStoreError.io }
    }

    /// Internal for focused disk-corruption tests; not an app-facing path API.
    func markerURL(for identity: DirectGatewayAttachmentRecoveryIdentity) throws -> URL {
        let material = "\(identity.origin)\u{0}\(identity.profile)\u{0}\(identity.runtimeID)"
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return rootURL.appendingPathComponent("marker-\(digest).json", isDirectory: false)
    }
}
