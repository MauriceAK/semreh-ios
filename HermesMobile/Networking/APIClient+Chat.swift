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

private struct BtwRequest: Encodable {
    let sessionId: String
    let question: String
}

private struct BackgroundRequest: Encodable {
    let sessionId: String
    let prompt: String
}
