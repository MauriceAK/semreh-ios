import Foundation

/// Chat-only new-chat flow. The profile is already chosen on the bot list, so
/// this just asks the real session store for a session and hands it back for
/// navigation. Backend session creation is deferred until the first prompt is
/// submitted (see SessionListViewModel.createSession), so no workspace/session
/// network request happens here.
enum NewChatFlow {
    @MainActor
    static func createSession(
        profile: ProfileSummary,
        in viewModel: SessionListViewModel
    ) async -> SessionSummary? {
        await viewModel.createSession(profile: profile.normalizedName)
    }
}
