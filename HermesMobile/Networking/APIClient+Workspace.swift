import Foundation

extension APIClient {
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
