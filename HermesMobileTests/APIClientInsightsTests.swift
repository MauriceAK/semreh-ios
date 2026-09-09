import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientInsightsTests: APIClientTestCase {
    func testInsightSessionsUsesExactScopedDirectInventory() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/profiles/sessions")

            let components = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(query, ["profile": "work", "limit": "500", "offset": "0", "order": "recent", "archived": "exclude"])

            return apiTestJSONResponse("""
            {
              "sessions": [{"id":"s1","title":"Scoped","profile":"work","message_count":12,"input_tokens":1200,"output_tokens":450,"estimated_cost":0.0323}],
              "total": 501,
              "limit": 500,
              "offset": 0,
              "profile_totals": {"work":501},
              "errors": []
            }
            """, for: request)
        }

        let response = try await client.insightSessions(profile: "work", limit: 500, offset: 0)
        XCTAssertEqual(response.sessions.first?.title, "Scoped")
        XCTAssertEqual(response.total, 501)
    }

    func testInsightsResponseToleratesMissingArraysAndLossyCounts() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(
            InsightsResponse.self,
            from: Data("""
            {
              "period_days": "30",
              "total_sessions": "4",
              "total_cost": "$1.25",
              "models": "not an array",
              "daily_tokens": null,
              "activity_by_day": { "unexpected": true }
            }
            """.utf8)
        )

        XCTAssertEqual(response.periodDays, 30)
        XCTAssertEqual(response.totalSessions, 4)
        XCTAssertEqual(try XCTUnwrap(response.totalCost), 1.25, accuracy: 0.0001)
        XCTAssertNil(response.totalCacheReadTokens)
        XCTAssertNil(response.totalCacheHitPercent)
        XCTAssertNil(response.models)
        XCTAssertNil(response.dailyTokens)
        XCTAssertNil(response.activityByDay)
        XCTAssertNil(response.activityByHour)
    }

    func testInsightsResponseDecodesLossyCacheEfficiencyFields() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(
            InsightsResponse.self,
            from: Data("""
            {
              "total_cache_read_tokens": "900",
              "total_cache_hit_percent": "87.5",
              "models": [
                { "model": "gpt-5.5", "cache_hit_percent": 12 }
              ]
            }
            """.utf8)
        )

        XCTAssertEqual(response.totalCacheReadTokens, 900)
        XCTAssertEqual(try XCTUnwrap(response.totalCacheHitPercent), 87.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(response.models?.first?.cacheHitPercent), 12, accuracy: 0.0001)
    }

    func testInsightsFormattedPercentUsesAtMostOneFractionDigit() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(insightsFormattedPercent(87.5, locale: locale), "87.5%")
        XCTAssertEqual(insightsFormattedPercent(12, locale: locale), "12%")
        XCTAssertEqual(insightsFormattedPercent(0.19, locale: locale), "0.2%")
    }
}
