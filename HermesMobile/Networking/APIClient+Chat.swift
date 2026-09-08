import Foundation

extension APIClient {
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

}

private struct GoalSubmissionRequest: Encodable {
    let sessionId: String
    let args: String
    let workspace: String?
    let model: String?
    let modelProvider: String?
    let profile: String?
}
