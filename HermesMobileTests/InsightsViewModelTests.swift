import XCTest
@testable import HermesMobile

final class InsightsViewModelTests: XCTestCase {
    func testAggregateMathToleratesMissingUsageFields() throws {
        let sessions = try decodeSessions([
            sessionJSON(title: "Complete", inputTokens: 10, outputTokens: 20, estimatedCost: 0.12),
            sessionJSON(title: "Input only", inputTokens: 7, outputTokens: nil, estimatedCost: nil),
            sessionJSON(title: "Cost only", inputTokens: nil, outputTokens: nil, estimatedCost: 0.03)
        ])

        let analytics = SessionUsageAnalytics(sessions: sessions)

        XCTAssertEqual(analytics.sessionCount, 3)
        XCTAssertEqual(analytics.totalInputTokens, 17)
        XCTAssertEqual(analytics.totalOutputTokens, 20)
        XCTAssertEqual(analytics.totalTokens, 37)
        XCTAssertEqual(analytics.estimatedCost, 0.15, accuracy: 0.0001)
    }

    func testTimeframeFilteringUsesMostRecentSessionTimestamp() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessions = try decodeSessions([
            sessionJSON(title: "Today", createdAt: now.addingTimeInterval(-60).timeIntervalSince1970),
            sessionJSON(title: "Updated recently", createdAt: now.addingTimeInterval(-100 * 24 * 60 * 60).timeIntervalSince1970, updatedAt: now.addingTimeInterval(-3 * 24 * 60 * 60).timeIntervalSince1970),
            sessionJSON(title: "Last message recently", createdAt: now.addingTimeInterval(-100 * 24 * 60 * 60).timeIntervalSince1970, updatedAt: now.addingTimeInterval(-40 * 24 * 60 * 60).timeIntervalSince1970, lastMessageAt: now.addingTimeInterval(-20 * 24 * 60 * 60).timeIntervalSince1970),
            sessionJSON(title: "Old", createdAt: now.addingTimeInterval(-45 * 24 * 60 * 60).timeIntervalSince1970),
            sessionJSON(title: "No timestamp", createdAt: nil)
        ])

        let today = sessions.filter { AnalyticsTimeframe.today.contains($0, now: now, calendar: calendar) }
        let last7Days = sessions.filter { AnalyticsTimeframe.last7Days.contains($0, now: now, calendar: calendar) }
        let last30Days = sessions.filter { AnalyticsTimeframe.last30Days.contains($0, now: now, calendar: calendar) }
        let allTime = sessions.filter { AnalyticsTimeframe.allTime.contains($0, now: now, calendar: calendar) }

        XCTAssertEqual(today.map(\.title), ["Today"])
        XCTAssertEqual(last7Days.map(\.title), ["Today", "Updated recently"])
        XCTAssertEqual(last30Days.map(\.title), ["Today", "Updated recently", "Last message recently"])
        XCTAssertEqual(allTime.count, 5)
    }

    func testTopSessionsSortsByTotalTokensWithinFilteredData() throws {
        let sessions = try decodeSessions([
            sessionJSON(title: "Low", inputTokens: 5, outputTokens: 5),
            sessionJSON(title: "High", inputTokens: 20, outputTokens: 1),
            sessionJSON(title: "Medium", inputTokens: nil, outputTokens: 12)
        ])

        let analytics = SessionUsageAnalytics(sessions: sessions)

        XCTAssertEqual(analytics.topSessions.map(\.title), ["High", "Medium", "Low"])
    }

    func testTimeframesMapToServerInsightDays() {
        XCTAssertEqual(AnalyticsTimeframe.today.serverDays, 1)
        XCTAssertEqual(AnalyticsTimeframe.last7Days.serverDays, 7)
        XCTAssertEqual(AnalyticsTimeframe.last30Days.serverDays, 30)
        XCTAssertEqual(AnalyticsTimeframe.allTime.serverDays, 365)
    }

    func testModelDisplayShareFallsBackFromZeroCostShareToTokenShare() throws {
        let insights = try decodeInsights("""
        {
          "models": [
            {
              "model": "deepseek-v4-flash",
              "sessions": 25,
              "total_tokens": 3000000,
              "cost_share": 0,
              "token_share": 26,
              "session_share": 37
            }
          ]
        }
        """)

        XCTAssertEqual(insights.models?.first?.displayShare, 26)
    }

    @MainActor
    func testLoadAggregatesBoundedDirectProfileInventory() async throws {
        let now = Date().timeIntervalSince1970
        let sessions = try decodeSessions([
            sessionJSON(title: "Recent", createdAt: now - 60, messageCount: 4, inputTokens: 10, outputTokens: 20, estimatedCost: 0.12),
            sessionJSON(title: "Older", createdAt: now - 3_600, messageCount: 2, inputTokens: 5, outputTokens: 7, estimatedCost: 0.03)
        ])
        let client = StubInsightsClient(
            result: .success(DirectHermesSessionPage(
                sessions: sessions, total: 501, limit: 500, offset: 0,
                profileTotals: ["work": 501], errors: nil
            ))
        )
        let viewModel = InsightsViewModel(client: client, profile: "work")
        viewModel.selectedTimeframe = .last7Days

        await viewModel.load()

        XCTAssertEqual(client.requests, [.init(profile: "work", limit: 500, offset: 0)])
        XCTAssertEqual(viewModel.dataSource, .localFallback)
        XCTAssertEqual(viewModel.sessionCount, 2)
        XCTAssertEqual(viewModel.totalMessages, 6)
        XCTAssertEqual(viewModel.totalInputTokens, 15)
        XCTAssertEqual(viewModel.totalOutputTokens, 27)
        XCTAssertEqual(viewModel.totalTokens, 42)
        XCTAssertEqual(viewModel.estimatedCost, 0.15, accuracy: 0.0001)
        XCTAssertNil(viewModel.totalCacheReadTokens)
        XCTAssertNil(viewModel.totalCacheHitPercent)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.fallbackReason)
        XCTAssertEqual(viewModel.sourceDescription, "Source: newest 2 of 501 direct session metadata rows in the selected profile.")
    }

    @MainActor
    func testInitialDirectInventoryFailureDoesNotRetryLegacyInsightsOrSessions() async {
        let client = StubInsightsClient(result: .failure(StubInsightsError()))
        let viewModel = InsightsViewModel(client: client)

        await viewModel.load()

        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(viewModel.errorMessage, "Server insights unavailable")
        XCTAssertFalse(viewModel.hasLoadedAnalytics)
    }

    @MainActor
    func testProfileReadErrorRefusesRowsAndFullPageWithoutTotalIsLabeledPartial() async throws {
        let row = try decodeSessions([sessionJSON(title: "Do not publish")])
        let failed = StubInsightsClient(result: .success(DirectHermesSessionPage(
            sessions: row, total: 1, limit: 500, offset: 0, profileTotals: nil,
            errors: [.init(profile: "work", error: "unavailable")]
        )))
        let failedViewModel = InsightsViewModel(client: failed, profile: "work")
        await failedViewModel.load()
        XCTAssertTrue(failedViewModel.sessions.isEmpty)
        XCTAssertEqual(failedViewModel.errorMessage, "Hermes could not read the selected profile's session metadata.")

        let fullPage = Array(repeating: row[0], count: 500)
        let bounded = StubInsightsClient(result: .success(DirectHermesSessionPage(
            sessions: fullPage, total: nil, limit: 500, offset: 0, profileTotals: nil, errors: []
        )))
        let boundedViewModel = InsightsViewModel(client: bounded, profile: "work")
        await boundedViewModel.load()
        XCTAssertEqual(
            boundedViewModel.sourceDescription,
            "Source: newest 500 direct session metadata rows in the selected profile; more may exist."
        )
    }

    @MainActor
    func testLoadKeepsExistingAnalyticsVisibleWhileTimeframeRefreshes() async throws {
        let client = DelayedInsightsClient(
            firstResponse: DirectHermesSessionPage(
                sessions: try decodeSessions([sessionJSON(title: "Initial", createdAt: Date().timeIntervalSince1970, inputTokens: 100, outputTokens: 250)]),
                total: 1, limit: 500, offset: 0, profileTotals: nil, errors: nil
            )
        )
        let viewModel = InsightsViewModel(client: client)

        await viewModel.load()
        XCTAssertEqual(viewModel.totalTokens, 350)
        XCTAssertEqual(viewModel.periodTitle, "Last 30 Days")

        viewModel.selectedTimeframe = .last7Days
        let refreshTask = Task { await viewModel.load() }
        await client.waitForPendingRequest()

        XCTAssertTrue(viewModel.isLoading)
        XCTAssertEqual(viewModel.totalTokens, 350)
        XCTAssertEqual(viewModel.periodTitle, "Last 30 Days")

        client.completePendingRequest(with: .success(DirectHermesSessionPage(
            sessions: try decodeSessions([sessionJSON(title: "Refreshed", createdAt: Date().timeIntervalSince1970, inputTokens: 50, outputTokens: 75)]),
            total: 1, limit: 500, offset: 0, profileTotals: nil, errors: nil
        )))
        await refreshTask.value

        XCTAssertEqual(viewModel.totalTokens, 125)
        XCTAssertEqual(viewModel.periodTitle, "Last 7 Days")
        XCTAssertFalse(viewModel.isLoading)
    }

    private func decodeSessions(_ objects: [String]) throws -> [SessionSummary] {
        let json = "[\(objects.joined(separator: ","))]"
        return try JSONDecoder().decode([SessionSummary].self, from: Data(json.utf8))
    }

    private func decodeInsights(_ json: String) throws -> InsightsResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(InsightsResponse.self, from: Data(json.utf8))
    }

    private func sessionJSON(
        title: String,
        createdAt: Double? = 1_800_000_000,
        updatedAt: Double? = nil,
        lastMessageAt: Double? = nil,
        messageCount: Int? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        estimatedCost: Double? = nil
    ) -> String {
        var fields = [
            #""sessionId":"\#(UUID().uuidString)""#,
            #""title":"\#(title)""#
        ]

        append("createdAt", createdAt, to: &fields)
        append("updatedAt", updatedAt, to: &fields)
        append("lastMessageAt", lastMessageAt, to: &fields)
        append("messageCount", messageCount, to: &fields)
        append("inputTokens", inputTokens, to: &fields)
        append("outputTokens", outputTokens, to: &fields)
        append("estimatedCost", estimatedCost, to: &fields)

        return "{\(fields.joined(separator: ","))}"
    }

    private func append(_ key: String, _ value: Double?, to fields: inout [String]) {
        guard let value else { return }
        fields.append(#""\#(key)":\#(value)"#)
    }

    private func append(_ key: String, _ value: Int?, to fields: inout [String]) {
        guard let value else { return }
        fields.append(#""\#(key)":\#(value)"#)
    }
}

private final class StubInsightsClient: InsightsDataClient {
    struct Request: Equatable { let profile: String; let limit: Int; let offset: Int }
    private let result: Result<DirectHermesSessionPage, Error>
    private(set) var requests: [Request] = []

    init(result: Result<DirectHermesSessionPage, Error>) {
        self.result = result
    }

    func insightSessions(profile: String, limit: Int, offset: Int) async throws -> DirectHermesSessionPage {
        requests.append(.init(profile: profile, limit: limit, offset: offset))
        return try result.get()
    }
}

private struct StubInsightsError: LocalizedError {
    var errorDescription: String? {
        "Server insights unavailable"
    }
}

@MainActor
private final class DelayedInsightsClient: InsightsDataClient {
    private var firstResponse: DirectHermesSessionPage?
    private var pendingContinuation: CheckedContinuation<DirectHermesSessionPage, Error>?

    init(firstResponse: DirectHermesSessionPage) {
        self.firstResponse = firstResponse
    }

    func insightSessions(profile: String, limit: Int, offset: Int) async throws -> DirectHermesSessionPage {
        if let response = firstResponse {
            firstResponse = nil
            return response
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation
        }
    }

    func waitForPendingRequest() async {
        while pendingContinuation == nil {
            await Task.yield()
        }
    }

    func completePendingRequest(with result: Result<DirectHermesSessionPage, Error>) {
        pendingContinuation?.resume(with: result)
        pendingContinuation = nil
    }
}
