import Foundation

extension APIClient {
    nonisolated func chatStreamURL(streamID: String, replayAfterSeq: Int? = nil) -> URL {
        let url = Endpoint.chatStream(streamID: streamID).url(relativeTo: baseURL)
        guard let replayAfterSeq,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return url
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "replay", value: "1"))
        queryItems.append(URLQueryItem(name: "after_seq", value: "\(max(0, replayAfterSeq))"))
        components.queryItems = queryItems
        return components.url ?? url
    }

    func cancelChat(streamID: String) async throws -> ChatCancelResponse {
        return try await send(endpoint: .chatCancel(streamID: streamID), method: "GET")
    }

    func chatStreamStatus(streamID: String) async throws -> ChatStreamStatusResponse {
        return try await send(endpoint: .chatStreamStatus(streamID: streamID), method: "GET")
    }

    func approvalPending(sessionID: String) async throws -> ApprovalPendingResponse {
        try await send(endpoint: .approvalPending(sessionID: sessionID), method: "GET")
    }

    nonisolated func approvalStreamURL(sessionID: String) -> URL {
        Endpoint.approvalStream(sessionID: sessionID).url(relativeTo: baseURL)
    }

    func respondApproval(
        sessionID: String,
        choice: ApprovalChoice,
        approvalID: String?
    ) async throws -> ApprovalRespondResponse {
        try await send(
            endpoint: .approvalRespond,
            method: "POST",
            body: ApprovalRespondRequest(
                sessionId: sessionID,
                choice: choice,
                approvalId: approvalID
            )
        )
    }

    func clarifyPending(sessionID: String) async throws -> ClarificationPendingResponse {
        try await send(endpoint: .clarifyPending(sessionID: sessionID), method: "GET")
    }

    nonisolated func clarifyStreamURL(sessionID: String) -> URL {
        Endpoint.clarifyStream(sessionID: sessionID).url(relativeTo: baseURL)
    }

    func respondClarification(
        sessionID: String,
        response: String,
        clarifyID: String?
    ) async throws -> ClarificationRespondResponse {
        try await send(
            endpoint: .clarifyRespond,
            method: "POST",
            body: ClarificationRespondRequest(
                sessionId: sessionID,
                response: response,
                clarifyId: clarifyID
            )
        )
    }

    func submitNativeAuth(
        sessionID: String,
        streamID: String,
        envelope: NativeAuthWireEnvelope
    ) async throws -> NativeAuthControlResponse {
        try await sendNativeAuthControl(
            endpoint: .nativeAuthSubmit,
            expectedSuccessState: "submitted",
            body: NativeAuthSubmitRequest(
                sessionID: sessionID,
                streamID: streamID,
                envelope: envelope
            )
        )
    }

    func cancelNativeAuth(
        sessionID: String,
        streamID: String,
        contextID: String
    ) async throws -> NativeAuthControlResponse {
        try await sendNativeAuthControl(
            endpoint: .nativeAuthCancel,
            expectedSuccessState: "cancelled",
            body: NativeAuthCancelRequest(
                sessionID: sessionID,
                streamID: streamID,
                componentID: contextID
            )
        )
    }

    func websiteLoginStatus(requestID: String, sessionID: String) async throws -> WebsiteLoginResultResponse {
        try await send(
            endpoint: .workLoginStatus(requestID: requestID, sessionID: sessionID),
            method: "GET"
        )
    }

    func finishWebsiteLogin(
        requestID: String,
        sessionID: String,
        result: WebsiteLoginResult
    ) async throws -> WebsiteLoginResultResponse {
        try await send(
            endpoint: .workLoginResult,
            method: "POST",
            body: WebsiteLoginResultRequest(
                requestID: requestID,
                sessionID: sessionID,
                result: result
            )
        )
    }

    func steerChat(sessionID: String, text: String) async throws -> ChatSteerResponse {
        try await send(
            endpoint: .chatSteer,
            method: "POST",
            body: ChatSteerRequest(sessionId: sessionID, text: text)
        )
    }

    func submitGoal(
        sessionID: String,
        args: String,
        workspace: String?,
        model: String?,
        modelProvider: String?,
        profile: String?
    ) async throws -> GoalSubmissionResponse {
        try await send(
            endpoint: .submitGoal,
            method: "POST",
            body: GoalSubmissionRequest(
                sessionId: sessionID,
                args: args,
                workspace: workspace,
                model: model,
                modelProvider: modelProvider,
                profile: profile
            )
        )
    }

    func startBtw(sessionID: String, question: String) async throws -> BtwStartResponse {
        try await send(
            endpoint: .btw,
            method: "POST",
            body: BtwRequest(sessionId: sessionID, question: question)
        )
    }

    func startBackground(sessionID: String, prompt: String) async throws -> BackgroundStartResponse {
        try await send(
            endpoint: .background,
            method: "POST",
            body: BackgroundRequest(sessionId: sessionID, prompt: prompt)
        )
    }

    func backgroundStatus(sessionID: String) async throws -> BackgroundStatusResponse {
        try await send(endpoint: .backgroundStatus(sessionID: sessionID), method: "GET")
    }

    private func sendNativeAuthControl<Body: Encodable>(
        endpoint: Endpoint,
        expectedSuccessState: String,
        body: Body
    ) async throws -> NativeAuthControlResponse {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        var request = URLRequest(url: endpoint.url(relativeTo: baseURL))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        customHeaderProvider().apply(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("native-auth-v1", forHTTPHeaderField: "X-Semreh-Client")
        request.httpBody = try encoder.encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.network(underlying: error)
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.http(statusCode: -1, body: nil)
        }
        if httpResponse.statusCode == 401 {
            throw APIError.unauthorized
        }
        if !(200..<300).contains(httpResponse.statusCode) {
            if let outcome = try? decodeNativeAuthControlResponse(from: data),
               outcome.expectedHTTPStatus == httpResponse.statusCode,
               !outcome.ok {
                throw NativeAuthControlError(outcome: outcome, statusCode: httpResponse.statusCode)
            }
            throw APIError.http(statusCode: httpResponse.statusCode, body: String(data: data, encoding: .utf8))
        }
        let outcome = try decodeNativeAuthControlResponse(from: data)
        guard outcome.ok,
              outcome.expectedHTTPStatus == httpResponse.statusCode,
              outcome.state == expectedSuccessState
        else {
            throw APIError.decoding(underlying: WebsiteLoginSecurityError.invalidPolicy)
        }
        return outcome
    }

    private func decodeNativeAuthControlResponse(from data: Data) throws -> NativeAuthControlResponse {
        // Native-auth response decoding is deliberately closed over the exact
        // metadata-only wire keys. The client-wide decoder's snake-case strategy
        // would transform those keys before NativeAuthControlResponse can reject
        // unknown or credential-bearing fields.
        do {
            return try JSONDecoder().decode(NativeAuthControlResponse.self, from: data)
        } catch {
            throw APIError.decoding(underlying: error)
        }
    }
}

private struct ChatStartRequest: Encodable {
    let sessionId: String
    let message: String
    let workspace: String?
    let model: String?
    let modelProvider: String?
    let profile: String?
    let explicitModelPick: Bool?
    let attachments: [JSONValue]?
}

private struct ChatSteerRequest: Encodable {
    let sessionId: String
    let text: String
}

private struct GoalSubmissionRequest: Encodable {
    let sessionId: String
    let args: String
    let workspace: String?
    let model: String?
    let modelProvider: String?
    let profile: String?
}

private struct ApprovalRespondRequest: Encodable {
    let sessionId: String
    let choice: ApprovalChoice
    let approvalId: String?
}

private struct ClarificationRespondRequest: Encodable {
    let sessionId: String
    let response: String
    let clarifyId: String?
}

private struct NativeAuthSubmitRequest: Encodable {
    let sessionID: String
    let streamID: String
    let envelope: NativeAuthWireEnvelope

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case streamID = "stream_id"
        case envelope
    }
}

private struct NativeAuthCancelRequest: Encodable {
    let sessionID: String
    let streamID: String
    let componentID: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case streamID = "stream_id"
        case componentID = "component_id"
    }
}

private struct WebsiteLoginResultRequest: Encodable {
    let requestID: String
    let sessionID: String
    let result: WebsiteLoginResult

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case sessionID = "session_id"
        case result
    }
}

private struct BtwRequest: Encodable {
    let sessionId: String
    let question: String
}

private struct BackgroundRequest: Encodable {
    let sessionId: String
    let prompt: String
}
