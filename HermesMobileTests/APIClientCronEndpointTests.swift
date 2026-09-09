import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class APIClientCronEndpointTests: APIClientTestCase {
    func testDirectCreateUsesOwningProfileQueryAndNoLegacyNotificationFields() async throws {
        var methods: [String] = []
        let client = makeClient { request in
            methods.append(request.httpMethod ?? "")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "profile" }?.value, "work")
            if request.httpMethod == "POST" {
                XCTAssertEqual(request.url?.path, "/api/cron/jobs")
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(apiTestBodyData(from: request))) as? [String: Any])
                XCTAssertEqual(body["prompt"] as? String, "run")
                XCTAssertEqual(body["schedule"] as? String, "0 7 * * *")
                XCTAssertEqual(body["skills"] as? [String], ["inspect"])
                XCTAssertNil(body["profile"])
                XCTAssertNil(body["toast_notifications"])
            } else { XCTAssertEqual(request.url?.path, "/api/cron/jobs/new-job") }
            return apiTestJSONResponse(#"{"id":"new-job","profile":"work","prompt":"run","skills":["inspect"]}"#, for: request)
        }
        let result = try await client.directCreateCron(draft: CronJobEditorDraft(prompt: "run", schedule: "0 7 * * *", skillsText: "inspect"), profile: "work")
        XCTAssertEqual(result.jobId, "new-job")
        XCTAssertEqual(methods, ["POST", "GET"])
    }

    func testDirectUpdateUsesSparseUpdatesAndConfirmsSameOwnedJob() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/cron/jobs/job1")
            if request.httpMethod == "PUT" {
                let data = try XCTUnwrap(apiTestBodyData(from: request))
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let updates = try XCTUnwrap(body["updates"] as? [String: Any])
                XCTAssertEqual(Set(body.keys), ["updates"])
                XCTAssertEqual(updates["prompt"] as? String, "updated")
                XCTAssertTrue(updates["model"] is NSNull)
                for retained in ["profile", "toast_notifications", "script", "context_from", "enabled_toolsets", "workdir", "no_agent"] {
                    XCTAssertNil(updates[retained])
                }
            } else { XCTAssertEqual(request.httpMethod, "GET") }
            return apiTestJSONResponse(#"{"id":"job1","profile":"work","prompt":"updated","script":"existing.py"}"#, for: request)
        }
        let result = try await client.directUpdateCron(jobID: "job1", profile: "work",
            draft: CronJobEditorDraft(prompt: "updated", schedule: "0 8 * * *", profile: "work"))
        XCTAssertEqual(result.prompt, "updated")
    }

    func testDirectUpdateRejectsProfileMoveBeforeAnyRequest() async throws {
        let client = makeClient { _ in XCTFail("No implicit profile move"); throw URLError(.badURL) }
        do {
            _ = try await client.directUpdateCron(jobID: "job1", profile: "work", draft: CronJobEditorDraft(prompt: "run", schedule: "0 7 * * *", profile: "other"))
            XCTFail("Expected unsupported move")
        } catch DirectCronMutationError.unsupportedProfileMove { }
    }

    func testDirectDeleteRequiresConfirmedAbsenceAndNeverRetriesReceiptFailure() async throws {
        var deletes = 0
        let client = makeClient { request in
            if request.httpMethod == "DELETE" { deletes += 1; return apiTestJSONResponse(#"{"ok":true}"#, for: request) }
            return apiTestJSONResponse(#"[{"id":"job1","profile":"work"}]"#, for: request)
        }
        do { try await client.directDeleteCron(jobID: "job1", profile: "work"); XCTFail("Existing job is not confirmed deleted") }
        catch DirectCronMutationError.unconfirmed { }
        XCTAssertEqual(deletes, 1)
    }

    func testDirectPauseResumeUseBodylessScopedPostAndRawJobReceipt() async throws {
        for paused in [true, false] {
            let client = makeClient { request in
                XCTAssertEqual(request.url?.path, "/api/cron/jobs/job1/\(paused ? "pause" : "resume")")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertNil(apiTestBodyData(from: request))
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                               [URLQueryItem(name: "profile", value: "work")])
                return apiTestJSONResponse("""
                {"id":"job1","profile":"work","enabled":\(!paused),"state":"\(paused ? "paused" : "scheduled")"}
                """, for: request)
            }
            let job = try await (paused ? client.directPauseCron(jobID: "job1", profile: "work")
                                 : client.directResumeCron(jobID: "job1", profile: "work"))
            XCTAssertEqual(job.enabled, !paused)
        }
    }

    func testDirectPauseRejectsUnsupportedReasonBeforeRequest() async throws {
        let client = makeClient { request in
            XCTFail("Unsupported reason must not be discarded")
            return apiTestJSONResponse("{}", for: request)
        }
        do {
            _ = try await client.directPauseCron(jobID: "job1", profile: "work", reason: "vacation")
            XCTFail("Expected unsupported reason")
        } catch DirectCronMutationError.unsupportedPauseReason { }
    }

    func testDirectPauseRejectsIdentityAndStateMismatchWithoutRetry() async throws {
        for body in [#"{"id":"other","profile":"work","enabled":false,"state":"paused"}"#,
                     #"{"id":"job1","profile":"other","enabled":false,"state":"paused"}"#,
                     #"{"id":"job1","profile":"work","enabled":true,"state":"paused"}"#,
                     #"{"id":"job1","profile":"work","enabled":false,"state":"scheduled"}"#,
                     #"{"ok":true,"job":{"id":"job1"}}"#] {
            var calls = 0
            let client = makeClient { request in
                calls += 1
                return apiTestJSONResponse(body, for: request)
            }
            do {
                _ = try await client.directPauseCron(jobID: "job1", profile: "work")
                XCTFail("Expected unconfirmed receipt")
            } catch DirectCronMutationError.unconfirmedResponse { }
            XCTAssertEqual(calls, 1)
        }
    }

    func testDirectResumeTransportFailureIsNotRetried() async throws {
        var calls = 0
        let client = makeClient { _ in
            calls += 1
            throw URLError(.networkConnectionLost)
        }
        do {
            _ = try await client.directResumeCron(jobID: "job1", profile: "work")
            XCTFail("Expected failure")
        } catch { }
        XCTAssertEqual(calls, 1)
    }

    func testDirectCronListUsesExplicitProfileAndStockBareArray() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/cron/jobs")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "profile", value: "work")])
            return apiTestJSONResponse("""
            [{"id":"job1","profile":"work","name":"Digest","enabled":false,
              "schedule":{"kind":"cron","expr":"0 9 * * *"},
              "latest_execution":{"status":"running","started_at":"2026-09-07T00:00:00+00:00"}}]
            """, for: request)
        }
        let jobs = try await client.directCronJobs(profile: "work")
        XCTAssertEqual(jobs.first?.jobId, "job1")
        XCTAssertEqual(jobs.first?.enabled, false)
        XCTAssertEqual(jobs.first?.scheduleText, "0 9 * * *")
        XCTAssertEqual(jobs.first?.latestExecution?.status, "running")
        XCTAssertNotNil(jobs.first?.latestExecution?.startedAt)
    }

    func testDirectCronDetailUsesExactIDAndProfile() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/cron/jobs/job1")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "profile", value: "work")])
            return apiTestJSONResponse(#"{"id":"job1","profile":"work","prompt":"fixture","state":"paused"}"#, for: request)
        }
        let job = try await client.directCronJob(jobID: "job1", profile: "work")
        XCTAssertEqual(job.prompt, "fixture")
        XCTAssertEqual(job.status, .paused)
    }

    func testDirectCronRunsUsesBoundedProfileQueryAndSessionMetadata() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/cron/jobs/job1/runs")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
                           [URLQueryItem(name: "profile", value: "work"), URLQueryItem(name: "limit", value: "5")])
            return apiTestJSONResponse(#"{"runs":[{"id":"cron_job1_20260907","profile":"work","title":"Run","started_at":1788739200,"is_active":false}],"limit":5}"#, for: request)
        }
        let runs = try await client.directCronRuns(jobID: "job1", profile: "work")
        XCTAssertEqual(runs.first?.id, "cron_job1_20260907")
        XCTAssertEqual(runs.first?.title, "Run")
        XCTAssertNotNil(runs.first?.startedAt)
    }

    func testDirectCronDeliveryTargetsMapsGlobalStockFields() async throws {
        let client = makeClient { request in
            XCTAssertEqual(request.url?.path, "/api/cron/delivery-targets")
            XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.httpMethod, "GET")
            return apiTestJSONResponse(#"{"targets":[{"id":"local","name":"Local (save only)","home_target_set":true}]}"#, for: request)
        }
        let options = try await client.directCronDeliveryOptions()
        XCTAssertEqual(options, [CronDeliveryOption(value: "local", label: "Local (save only)")])
    }
}
