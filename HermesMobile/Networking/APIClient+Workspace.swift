import Foundation

enum DirectWorkspaceError: LocalizedError {
    case missingWorkspace, invalidPath, outsideWorkspace, invalidText
    var errorDescription: String? {
        switch self {
        case .missingWorkspace: return "The session has no authoritative workspace directory."
        case .invalidPath: return "The workspace file path is invalid."
        case .outsideWorkspace: return "The requested file is unavailable within this session's workspace."
        case .invalidText: return "This file is not valid UTF-8 text. Export it to open it in another app."
        }
    }
}

private struct DirectManagedDirectory: Decodable {
    let path: String
    let entries: [Entry]
    struct Entry: Decodable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int?
        let mtime: Double?
    }
}

extension APIClient {
    /// Resolve only through authoritative session cwd and server-returned entries.
    /// Files routes themselves are global: profile belongs to session discovery.
    private func directWorkspaceTarget(sessionID: String, profile: String, relativePath: String) async throws -> (root: String, target: String) {
        let parts = relativePath == "." ? [] : relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw DirectWorkspaceError.invalidPath
        }
        let detail = try await directSessionDetail(sessionID: sessionID, profile: profile)
        guard let cwd = detail.workspace, cwd.hasPrefix("/"), !cwd.contains("\0") else {
            throw DirectWorkspaceError.missingWorkspace
        }
        var listing = try await directManagedDirectory(path: cwd)
        let root = listing.path
        guard root.hasPrefix("/"), !root.contains("\0") else { throw DirectWorkspaceError.invalidPath }
        var target = root
        for (index, name) in parts.enumerated() {
            guard let entry = listing.entries.first(where: { $0.name == name }),
                  Self.workspaceContains(root: root, path: entry.path) else {
                throw DirectWorkspaceError.outsideWorkspace
            }
            target = entry.path
            if index < parts.count - 1 {
                guard entry.isDirectory else { throw DirectWorkspaceError.invalidPath }
                listing = try await directManagedDirectory(path: target)
                guard Self.workspaceContains(root: root, path: listing.path) else { throw DirectWorkspaceError.outsideWorkspace }
            }
        }
        return (root, target)
    }

    private static func workspaceContains(root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private func directManagedDirectory(path: String) async throws -> DirectManagedDirectory {
        var components = URLComponents()
        components.path = "/api/files"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        return try decode(DirectManagedDirectory.self, from: await sendDirectData(
            path: components.string!, method: "GET", classifyStructuredAuthExpiry: true))
    }

    func directWorkspaceDirectory(sessionID: String, profile: String, path: String) async throws -> DirectoryListResponse {
        let scope = try await directWorkspaceTarget(sessionID: sessionID, profile: profile, relativePath: path)
        let listing = try await directManagedDirectory(path: scope.target)
        guard Self.workspaceContains(root: scope.root, path: listing.path) else { throw DirectWorkspaceError.outsideWorkspace }
        let rows = listing.entries.filter { Self.workspaceContains(root: scope.root, path: $0.path) }.map { entry in
            WorkspaceEntry(name: entry.name, path: entry.path == scope.root ? "." : String(entry.path.dropFirst(scope.root == "/" ? 1 : scope.root.count + 1)),
                type: entry.isDirectory ? "dir" : "file", size: entry.size, modified: entry.mtime, isDirectory: entry.isDirectory)
        }
        let relative = listing.path == scope.root ? "." : String(listing.path.dropFirst(scope.root == "/" ? 1 : scope.root.count + 1))
        return DirectoryListResponse(entries: rows, path: relative, workspace: scope.root, error: nil)
    }

    func directWorkspaceFile(sessionID: String, profile: String, path: String, maximumBytes: Int) async throws -> DirectHermesManagedFile {
        let scope = try await directWorkspaceTarget(sessionID: sessionID, profile: profile, relativePath: path)
        let file = try await directReadManagedFile(path: scope.target, maximumBytes: maximumBytes)
        guard let returnedPath = file.path, Self.workspaceContains(root: scope.root, path: returnedPath) else {
            throw DirectWorkspaceError.outsideWorkspace
        }
        return file
    }

    func directWorkspaceDownload(sessionID: String, profile: String, path: String, maximumBytes: Int = 100 * 1_024 * 1_024) async throws -> Data {
        // The read envelope supplies a canonical returned path for containment
        // validation. Raw download does not. Base64 increases peak memory, so
        // both the envelope and decoded bytes remain explicitly bounded.
        // This is not an atomic filesystem snapshot: stock may race a file
        // replacement after resolving its path and before reading its bytes.
        try await directWorkspaceFile(sessionID: sessionID, profile: profile,
            path: path, maximumBytes: maximumBytes).data
    }
    func workspaces() async throws -> WorkspacesResponse {
        try await send(endpoint: .workspaces, method: "GET")
    }

    func workspaceSuggestions(prefix: String) async throws -> WorkspaceSuggestionsResponse {
        try await send(endpoint: .workspaceSuggestions(prefix: prefix), method: "GET")
    }

    func addWorkspace(path: String, name: String? = nil, create: Bool? = nil) async throws -> WorkspaceMutationResponse {
        try await send(
            endpoint: .workspaceAdd,
            method: "POST",
            body: AddWorkspaceRequest(path: path, name: name, create: create)
        )
    }

    func removeWorkspace(path: String) async throws -> WorkspaceMutationResponse {
        try await send(
            endpoint: .workspaceRemove,
            method: "POST",
            body: RemoveWorkspaceRequest(path: path)
        )
    }

    func renameWorkspace(path: String, name: String) async throws -> WorkspaceMutationResponse {
        try await send(
            endpoint: .workspaceRename,
            method: "POST",
            body: RenameWorkspaceRequest(path: path, name: name)
        )
    }

    func reorderWorkspaces(paths: [String]) async throws -> WorkspaceMutationResponse {
        try await send(
            endpoint: .workspaceReorder,
            method: "POST",
            body: ReorderWorkspacesRequest(paths: paths)
        )
    }

    func directoryList(sessionID: String, path: String? = nil) async throws -> DirectoryListResponse {
        try await send(
            endpoint: .directoryList(sessionID: sessionID, path: path),
            method: "GET"
        )
    }

    func file(sessionID: String, path: String) async throws -> FileResponse {
        try await send(endpoint: .file(sessionID: sessionID, path: path), method: "GET")
    }

    func rawFileData(sessionID: String, path: String) async throws -> Data {
        try await sendData(endpoint: .rawFile(sessionID: sessionID, path: path), method: "GET")
    }

    func rawFilePreviewData(
        sessionID: String,
        path: String,
        maximumBytes: Int
    ) async throws -> Data {
        try await boundedData(
            endpoint: .rawFile(sessionID: sessionID, path: path),
            maximumBytes: maximumBytes
        ).0
    }

    func mediaData(sessionID: String, path: String) async throws -> Data {
        try await mediaResponseData(
            endpoint: .media(sessionID: sessionID, path: path),
            maximumDecodedBytes: GatewayMediaResponseAdapter.defaultMaximumDecodedBytes,
            rawMaximumBytes: nil
        )
    }

    func mediaPreviewData(
        sessionID: String,
        path: String,
        maximumBytes: Int
    ) async throws -> Data {
        try await mediaResponseData(
            endpoint: .media(sessionID: sessionID, path: path),
            maximumDecodedBytes: maximumBytes,
            rawMaximumBytes: maximumBytes
        )
    }

    /// Reads one absolute path through the authenticated stock managed-files
    /// route. The server owns root/sensitive-file policy; the client only
    /// rejects empty/relative inputs so it never guesses a host path.
    func directReadManagedFile(path: String, maximumBytes: Int = 25 * 1_024 * 1_024) async throws -> DirectHermesManagedFile {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maximumBytes > 0, !trimmedPath.isEmpty,
              trimmedPath.hasPrefix("/"),
              !trimmedPath.contains("\0")
        else {
            throw APIError.invalidServerURL
        }

        let endpoint = baseURL.appending(path: "/api/files/read")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidServerURL
        }
        components.queryItems = [URLQueryItem(name: "path", value: trimmedPath)]
        guard let url = components.url else {
            throw APIError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        customHeaderProvider().apply(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let maximumDecodedBytes = min(maximumBytes, 100 * 1_024 * 1_024)
        let maximumEncodedBytes = GatewayMediaResponseAdapter.encodedEnvelopeMaximumBytes(
            for: maximumDecodedBytes
        )
        let protectedSession = URLSession(configuration: session.configuration,
            delegate: DirectHermesRedirectGuard(origin: baseURL), delegateQueue: nil)
        defer { protectedSession.invalidateAndCancel() }
        let data: Data
        do {
            (data, _) = try await boundedData(for: request, using: protectedSession,
                mapsUnauthorized: false, maximumBytes: maximumEncodedBytes)
        } catch let APIError.http(statusCode, body) {
            let bytes = Data((body ?? "").utf8)
            if DirectHermesAuthFailureClassifier.isSessionExpired(statusCode: statusCode, body: bytes) {
                throw DirectHermesAuthError.sessionExpired
            }
            throw DirectHermesRequestError.from(statusCode: statusCode, body: bytes)
        }
        let envelope = try decode(DirectHermesManagedFileEnvelope.self, from: data)
        guard let dataURL = envelope.dataURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dataURL.isEmpty
        else {
            throw APIError.decoding(
                underlying: DirectHermesManagedFileResponseAdapter.DecodeError.missingDataURL
            )
        }

        let bytes: Data
        do {
            bytes = try DirectHermesManagedFileResponseAdapter.decodeDataURL(
                dataURL,
                maximumDecodedBytes: maximumDecodedBytes
            )
        } catch let error as PreviewDownloadError {
            throw error
        } catch {
            throw APIError.decoding(underlying: error)
        }

        return DirectHermesManagedFile(
            data: bytes,
            mimeType: envelope.mimeType,
            name: envelope.name,
            path: envelope.path,
            size: envelope.size
        )
    }

    /// `/api/media` has two response contracts in the supported server fleet:
    /// legacy servers return the raw image bytes, while the pinned direct
    /// Hermes server returns an authenticated JSON envelope containing a data
    /// URL. Keep raw responses byte-for-byte compatible and only interpret a
    /// JSON response as the direct envelope.
    private func mediaResponseData(
        endpoint: Endpoint,
        maximumDecodedBytes: Int,
        rawMaximumBytes: Int?
    ) async throws -> Data {
        let encodedEnvelopeMaximum = GatewayMediaResponseAdapter.encodedEnvelopeMaximumBytes(
            for: maximumDecodedBytes
        )
        var request = URLRequest(url: endpoint.url(relativeTo: baseURL))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        customHeaderProvider().apply(to: &request)
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await boundedData(
            for: request,
            using: session,
            mapsUnauthorized: true,
            maximumBytes: max(encodedEnvelopeMaximum, rawMaximumBytes ?? 0),
            maximumBytesForResponse: { response in
                GatewayMediaResponseAdapter.isJSONResponse(response)
                    ? encodedEnvelopeMaximum
                    : (rawMaximumBytes ?? Int.max)
            }
        )
        return try GatewayMediaResponseAdapter.decode(
            data,
            response: response,
            maximumDecodedBytes: maximumDecodedBytes,
            decoder: JSONDecoder()
        )
    }

    func remoteTranscriptMediaData(from url: URL) async throws -> Data {
        try await remoteTranscriptMediaResource(from: url).0
    }

    func remoteTranscriptMediaResource(from url: URL) async throws -> (Data, HTTPURLResponse) {
        if Self.isSameOrigin(url, as: baseURL) {
            return try await downloadDataReturningResponse(from: url, using: session, mapsUnauthorized: true)
        }

        return try await downloadDataReturningResponse(
            from: url,
            using: publicMediaSession,
            mapsUnauthorized: false
        )
    }

    func remoteTranscriptMediaPreviewData(
        from url: URL,
        maximumBytes: Int
    ) async throws -> Data {
        try await remoteTranscriptMediaPreviewResource(
            from: url,
            maximumBytes: maximumBytes
        ).0
    }

    func remoteTranscriptMediaPreviewResource(
        from url: URL,
        maximumBytes: Int,
        documentMaximumBytes: Int? = nil,
        nameOrPath: String? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let isSameOrigin = Self.isSameOrigin(url, as: baseURL)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if isSameOrigin {
            customHeaderProvider().apply(to: &request)
        }
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        return try await boundedData(
            for: request,
            using: isSameOrigin ? session : publicMediaSession,
            mapsUnauthorized: isSameOrigin,
            maximumBytes: maximumBytes,
            maximumBytesForResponse: { response in
                guard let documentMaximumBytes,
                      DocumentPreviewKind.infer(
                        nameOrPath: nameOrPath,
                        mimeType: response.value(forHTTPHeaderField: "Content-Type")
                      ) != nil
                else {
                    return maximumBytes
                }
                return min(maximumBytes, documentMaximumBytes)
            }
        )
    }
}

struct DirectHermesManagedFile: Equatable, Sendable {
    let data: Data
    let mimeType: String?
    let name: String?
    let path: String?
    let size: Int?
}

private struct DirectHermesManagedFileEnvelope: Decodable {
    let dataURL: String?
    let mimeType: String?
    let name: String?
    let path: String?
    let size: Int?

    enum CodingKeys: String, CodingKey {
        // APIClient's shared decoder applies convertFromSnakeCase before
        // matching coding keys: data_url -> dataUrl, mime_type -> mimeType.
        case dataURL = "dataUrl"
        case mimeType
        case name
        case path
        case size
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dataURL = container.decodeLossyStringIfPresent(forKey: .dataURL)
        mimeType = container.decodeLossyStringIfPresent(forKey: .mimeType)
        name = container.decodeLossyStringIfPresent(forKey: .name)
        path = container.decodeLossyStringIfPresent(forKey: .path)
        size = container.decodeLossyIntIfPresent(forKey: .size)
    }
}

private enum DirectHermesManagedFileResponseAdapter {
    enum DecodeError: Error {
        case missingDataURL
        case malformedDataURL
        case invalidBase64
    }

    static let maximumDecodedBytes = GatewayMediaResponseAdapter.defaultMaximumDecodedBytes

    static func decodeDataURL(
        _ dataURL: String,
        maximumDecodedBytes: Int
    ) throws -> Data {
        guard let comma = dataURL.firstIndex(of: ",") else {
            throw DecodeError.malformedDataURL
        }

        let header = String(dataURL[..<comma])
        let lowercasedHeader = header.lowercased()
        let mimeType = String(header.dropFirst("data:".count).dropLast(";base64".count))
        guard lowercasedHeader.hasPrefix("data:"),
              lowercasedHeader.hasSuffix(";base64"),
              !mimeType.isEmpty,
              !mimeType.contains(";"),
              !mimeType.contains(where: { $0.isWhitespace })
        else {
            throw DecodeError.malformedDataURL
        }

        let payload = String(dataURL[dataURL.index(after: comma)...])
        guard payload.isEmpty || payload.count.isMultiple(of: 4),
              payload.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 65...90, 97...122, 48...57, 43, 47, 61:
                      return true
                  default:
                      return false
                  }
              }),
              let decoded = Data(base64Encoded: payload) ?? (payload.isEmpty ? Data() : nil)
        else {
            throw DecodeError.invalidBase64
        }

        guard decoded.count <= maximumDecodedBytes else {
            throw PreviewDownloadError.responseTooLarge(maximumBytes: maximumDecodedBytes)
        }
        return decoded
    }
}

/// Decoder for the pinned stock `/api/media` JSON response. This deliberately
/// lives at the API boundary: callers continue to receive image bytes and do
/// not need to know whether the server used the legacy or direct response.
private enum GatewayMediaResponseAdapter {
    private struct Envelope: Decodable {
        let dataURL: String?

        enum CodingKeys: String, CodingKey {
            case dataURL = "data_url"
        }
    }

    private enum DecodeError: Error {
        case missingDataURL
        case malformedDataURL
        case nonImageDataURL
        case invalidBase64
        case emptyImage
    }

    static let defaultMaximumDecodedBytes = 25 * 1_024 * 1_024

    static func isJSONResponse(_ response: HTTPURLResponse) -> Bool {
        guard let contentType = response.value(forHTTPHeaderField: "Content-Type") else {
            return false
        }
        let mediaType = contentType.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return mediaType == "application/json" || mediaType?.hasSuffix("+json") == true
    }

    /// Base64 expands bytes by 4/3. The additional allowance covers the data
    /// URL prefix and the small JSON envelope without allowing an unbounded
    /// response to be buffered before decoding.
    static func encodedEnvelopeMaximumBytes(for decodedMaximumBytes: Int) -> Int {
        precondition(decodedMaximumBytes >= 0)
        let (rounded, roundedOverflow) = decodedMaximumBytes.addingReportingOverflow(2)
        guard !roundedOverflow else { return Int.max }
        let groups = rounded / 3
        let (base64Bytes, multiplicationOverflow) = groups.multipliedReportingOverflow(by: 4)
        guard !multiplicationOverflow else { return Int.max }
        let (envelopeBytes, additionOverflow) = base64Bytes.addingReportingOverflow(512)
        return additionOverflow ? Int.max : envelopeBytes
    }

    static func decode(
        _ data: Data,
        response: HTTPURLResponse,
        maximumDecodedBytes: Int,
        decoder: JSONDecoder
    ) throws -> Data {
        guard isJSONResponse(response) else {
            return data
        }

        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }

        guard let dataURL = envelope.dataURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dataURL.isEmpty
        else {
            throw APIError.decoding(underlying: DecodeError.missingDataURL)
        }

        do {
            let imageData = try decodeImageDataURL(dataURL)
            guard imageData.count <= maximumDecodedBytes else {
                throw PreviewDownloadError.responseTooLarge(maximumBytes: maximumDecodedBytes)
            }
            return imageData
        } catch let error as PreviewDownloadError {
            throw error
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }

    private static func decodeImageDataURL(_ dataURL: String) throws -> Data {
        guard let comma = dataURL.firstIndex(of: ",") else {
            throw DecodeError.malformedDataURL
        }

        let header = String(dataURL[..<comma])
        let components = header.split(separator: ";", omittingEmptySubsequences: false)
        let mime = components.first.map(String.init)?.lowercased() ?? ""
        guard components.count == 2,
              mime.hasPrefix("data:image/"),
              mime.dropFirst("data:".count + "image/".count).isEmpty == false,
              !mime.contains(where: { $0.isWhitespace }),
              components[1].lowercased() == "base64"
        else {
            throw DecodeError.nonImageDataURL
        }

        let payload = String(dataURL[dataURL.index(after: comma)...])
        guard !payload.isEmpty,
              payload.count.isMultiple(of: 4),
              payload.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 65...90, 97...122, 48...57, 43, 47, 61:
                      return true
                  default:
                      return false
                  }
              }),
              let decoded = Data(base64Encoded: payload)
        else {
            throw DecodeError.invalidBase64
        }
        guard !decoded.isEmpty else {
            throw DecodeError.emptyImage
        }
        return decoded
    }
}
