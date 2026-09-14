import XCTest
import AVFoundation
import ImageIO
import SwiftData
import UIKit
import UniformTypeIdentifiers
@testable import HermesMobile

final class CronManagementModelTests: XCTestCase {
    func testCronMutationResponseDecodesAliasesAndStringSchedule() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let response = try decoder.decode(
            CronMutationResponse.self,
            from: Data("""
            {
              "ok": true,
              "job": {
                "job_id": "job-aliased",
                "name": "Aliased task",
                "prompt": 42,
                "schedule": "0 9 * * *",
                "enabled": "true",
                "state": "scheduled",
                "model": "@openai:gpt-5.5",
                "profile": "work",
                "toast_notifications": "yes"
              }
            }
            """.utf8)
        )

        let job = try XCTUnwrap(response.job)
        XCTAssertEqual(job.jobId, "job-aliased")
        XCTAssertEqual(job.prompt, "42")
        XCTAssertEqual(job.scheduleText, "0 9 * * *")
        XCTAssertEqual(job.status, .active)
        XCTAssertEqual(job.model, "@openai:gpt-5.5")
        XCTAssertEqual(job.profile, "work")
        XCTAssertEqual(job.toastNotifications, true)
    }

    func testCronJobEditorDraftNormalizesFieldsAndSkills() {
        let draft = CronJobEditorDraft(
            name: "  Morning digest  ",
            prompt: "  Summarize updates  ",
            schedule: "  0 7 * * *  ",
            deliver: "  local  ",
            skillsText: "summarize, notify\nswift",
            model: "  @openai:gpt-5.5  ",
            provider: "  openai  ",
            profile: "  work  ",
            toastNotifications: true
        )

        XCTAssertEqual(draft.trimmedName, "Morning digest")
        XCTAssertEqual(draft.trimmedPrompt, "Summarize updates")
        XCTAssertEqual(draft.trimmedSchedule, "0 7 * * *")
        XCTAssertEqual(draft.trimmedDeliver, "local")
        XCTAssertEqual(draft.skills, ["summarize", "notify", "swift"])
        XCTAssertEqual(draft.trimmedModel, "@openai:gpt-5.5")
        XCTAssertEqual(draft.trimmedProvider, "openai")
        XCTAssertEqual(draft.trimmedProfile, "work")
        XCTAssertNil(draft.validationMessage)
    }

    func testCronJobEditorDraftRoundTripsUnknownDeliverAndProvider() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let job = try decoder.decode(
            CronJob.self,
            from: Data("""
            {
              "id": "job-legacy",
              "prompt": "Run it",
              "schedule": "0 7 * * *",
              "deliver": "legacy-target",
              "provider": "openai"
            }
            """.utf8)
        )

        let draft = CronJobEditorDraft(job: job)

        XCTAssertEqual(draft.deliver, "legacy-target")
        XCTAssertEqual(draft.trimmedDeliver, "legacy-target")
        XCTAssertEqual(draft.provider, "openai")
    }

    func testCronDeliverPickerFallsBackWithoutUsableOptions() {
        XCTAssertNil(CronDeliverPicker.options(serverOptions: nil, currentValue: "local"))
        XCTAssertNil(CronDeliverPicker.options(serverOptions: [], currentValue: "local"))
        XCTAssertNil(
            CronDeliverPicker.options(
                serverOptions: [CronDeliveryOption(value: "  ", label: "Blank"), CronDeliveryOption(value: nil, label: "No value")],
                currentValue: "local"
            )
        )
        XCTAssertNil(
            CronDeliverPicker.options(
                serverOptions: [CronDeliveryOption(value: "local", label: "Local")],
                currentValue: "   "
            ),
            "A blank draft value has nothing safe to select, so free text is kept."
        )
    }

    func testCronDeliverPickerKeepsUnknownValueAsCustomRow() throws {
        let serverOptions = [
            CronDeliveryOption(value: "local", label: "Local (save output only)"),
            CronDeliveryOption(value: "origin", label: "Origin (reply to creator)"),
            CronDeliveryOption(value: "origin", label: "Duplicate ignored"),
            CronDeliveryOption(value: "telegram", label: nil)
        ]

        let options = try XCTUnwrap(
            CronDeliverPicker.options(serverOptions: serverOptions, currentValue: "legacy-target")
        )

        XCTAssertEqual(options.map(\.value), ["local", "origin", "telegram", "legacy-target"])
        XCTAssertEqual(options.map(\.isCustom), [false, false, false, true])
        XCTAssertEqual(options.first?.label, "Local (save output only)")
        XCTAssertEqual(options[2].label, "telegram", "Missing labels fall back to the raw value.")

        let knownValue = try XCTUnwrap(
            CronDeliverPicker.options(serverOptions: serverOptions, currentValue: "origin")
        )
        XCTAssertEqual(knownValue.map(\.value), ["local", "origin", "telegram"])
        XCTAssertFalse(knownValue.contains(where: \.isCustom))
    }

    func testCronDeliverPickerPreservesInitialAndLiveCustomValues() throws {
        let serverOptions = [
            CronDeliveryOption(value: "local", label: "Local"),
            CronDeliveryOption(value: "telegram", label: "Telegram")
        ]

        // The editor's initial legacy value keeps its custom row even after
        // the user selects a server option (currentValue moved on).
        let afterSelection = try XCTUnwrap(
            CronDeliverPicker.options(
                serverOptions: serverOptions,
                currentValue: "telegram",
                initialValue: "legacy-target"
            )
        )
        XCTAssertEqual(afterSelection.map(\.value), ["local", "telegram", "legacy-target"])
        XCTAssertEqual(afterSelection.map(\.isCustom), [false, false, true])

        // A value typed into the free-text fallback while options were still
        // loading gets its own row alongside the initial value's row, so the
        // picker selection always has a matching tag.
        let typedWhileLoading = try XCTUnwrap(
            CronDeliverPicker.options(
                serverOptions: serverOptions,
                currentValue: "typed-target",
                initialValue: "local"
            )
        )
        XCTAssertEqual(typedWhileLoading.map(\.value), ["local", "telegram", "typed-target"])
        XCTAssertEqual(typedWhileLoading.map(\.isCustom), [false, false, true])

        // Identical initial and current custom values collapse to one row.
        let sameCustom = try XCTUnwrap(
            CronDeliverPicker.options(
                serverOptions: serverOptions,
                currentValue: "legacy-target",
                initialValue: "legacy-target"
            )
        )
        XCTAssertEqual(sameCustom.map(\.value), ["local", "telegram", "legacy-target"])
        XCTAssertEqual(sameCustom.filter(\.isCustom).count, 1)

        // A blank initial value adds no row.
        let blankInitial = try XCTUnwrap(
            CronDeliverPicker.options(
                serverOptions: serverOptions,
                currentValue: "local",
                initialValue: "   "
            )
        )
        XCTAssertEqual(blankInitial.map(\.value), ["local", "telegram"])
    }

    func testCronJobEditorDraftRequiresPromptAndSchedule() {
        XCTAssertEqual(
            CronJobEditorDraft(prompt: "", schedule: "0 7 * * *").validationMessage,
            "Prompt is required."
        )
        XCTAssertEqual(
            CronJobEditorDraft(prompt: "Run it", schedule: "   ").validationMessage,
            "Schedule is required."
        )
    }
}

final class CronManagementViewModelTests: XCTestCase {
    @MainActor
    func testPauseKeepsExecutingRunFromStockListEnrichment() async throws {
        let rawJob = #"{"id":"job1","profile":"default","enabled":false,"state":"paused"}"#
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/cron/jobs/job1/pause", "/api/cron/jobs/job1":
                return apiTestJSONResponse(rawJob, for: request)
            case "/api/cron/jobs":
                return apiTestJSONResponse(#"[{"id":"job1","profile":"default","enabled":false,"state":"paused","latest_execution":{"status":"running","started_at":"2026-01-01T00:00:00Z"}}]"#, for: request)
            case "/api/cron/jobs/job1/runs":
                return apiTestJSONResponse(#"{"runs":[],"limit":5}"#, for: request)
            case "/api/cron/delivery-targets":
                return apiTestJSONResponse(#"{"targets":[]}"#, for: request)
            default:
                XCTFail("Unexpected route")
                throw URLError(.badURL)
            }
        }
        let model = TaskDetailViewModel(job: try decodeCronJob(rawJob), runningElapsed: 12,
                                        server: URL(string: "https://example.test")!, client: client)
        let paused = await model.pause()
        XCTAssertTrue(paused)
        XCTAssertEqual(model.job.state, "paused")
        XCTAssertNil(model.job.latestExecution, "Stock detail does not enrich execution state")
        XCTAssertGreaterThan(try XCTUnwrap(model.runningElapsed), 0)
    }

    @MainActor
    func testExecutionInventoryFailurePreservesPreviousRunningBadgeAndReportsError() async throws {
        let rawJob = #"{"id":"job1","profile":"default","enabled":false,"state":"paused"}"#
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/cron/jobs/job1": return apiTestJSONResponse(rawJob, for: request)
            case "/api/cron/jobs/job1/runs": return apiTestJSONResponse(#"{"runs":[],"limit":5}"#, for: request)
            case "/api/cron/delivery-targets": return apiTestJSONResponse(#"{"targets":[]}"#, for: request)
            default: throw URLError(.networkConnectionLost)
            }
        }
        let model = TaskDetailViewModel(job: try decodeCronJob(rawJob), runningElapsed: 12,
                                        server: URL(string: "https://example.test")!, client: client)
        await model.load()
        XCTAssertEqual(model.runningElapsed, 12)
        XCTAssertNotNil(model.lastError)
        XCTAssertNotNil(model.errorMessage)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        CronReadGateURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    func testNewerTaskListLoadOwnsRowsAfterOlderResponseCompletes() async throws {
        let observed = expectation(description: "older list held")
        let client = makeGatedClient(path: "/api/cron/jobs",
                                    first: #"[{"id":"old","profile":"default","name":"Old"}]"#,
                                    later: #"[{"id":"new","profile":"default","name":"New"}]"#,
                                    observed: observed)
        let model = TasksViewModel(server: URL(string: "https://example.test")!, client: client)
        let oldLoad = Task { await model.load() }
        await fulfillment(of: [observed], timeout: 2)
        await model.load()
        XCTAssertEqual(model.jobs.first?.name, "New")
        XCTAssertFalse(model.isLoading)
        CronReadGateURLProtocol.release()
        await oldLoad.value
        XCTAssertEqual(model.jobs.first?.name, "New")
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testTaskListPublishesJobsBeforeOptionalDeliveryOptionsFinish() async throws {
        let observed = expectation(description: "delivery options held")
        let client = makeGatedClient(
            path: "/api/cron/delivery-targets",
            first: #"{"targets":[{"id":"local","name":"Local"}]}"#,
            later: #"{"id":"job-delayed","profile":"default","name":"Digest"}"#,
            observed: observed
        )
        let model = TasksViewModel(server: URL(string: "https://example.test")!, client: client)
        let load = Task { await model.load() }

        await fulfillment(of: [observed], timeout: 2)
        XCTAssertEqual(model.jobs.map(\.jobId), ["job-delayed"])
        XCTAssertFalse(model.isLoading, "Required jobs must be ready while optional discovery is pending.")
        XCTAssertNil(model.deliveryOptions)

        CronReadGateURLProtocol.release()
        await load.value
        XCTAssertEqual(model.deliveryOptions?.map(\.value), ["local"])
    }

    @MainActor
    func testCancelledTaskListLoadDoesNotPublishLateJobsOrRemainLoading() async throws {
        let observed = expectation(description: "jobs held")
        let client = makeGatedClient(
            path: "/api/cron/jobs",
            first: #"[{"id":"late","profile":"default","name":"Late"}]"#,
            later: #"{"id":"new","profile":"default","name":"New"}"#,
            observed: observed
        )
        let model = TasksViewModel(server: URL(string: "https://example.test")!, client: client)
        let load = Task { await model.load() }

        await fulfillment(of: [observed], timeout: 2)
        load.cancel()
        CronReadGateURLProtocol.release()
        await load.value

        XCTAssertTrue(model.jobs.isEmpty, "A cancelled request must not publish its late response.")
        XCTAssertFalse(model.isLoading)
    }

    @MainActor
    func testNewerTaskDetailLoadOwnsMetadataAndClearsCompletedRunningState() async throws {
        let observed = expectation(description: "older detail held")
        let client = makeGatedClient(path: "/api/cron/jobs/job1",
                                    first: #"{"id":"job1","profile":"default","name":"Old","latest_execution":{"status":"running","started_at":"2026-09-07T00:00:00Z"}}"#,
                                    later: #"{"id":"job1","profile":"default","name":"New","latest_execution":{"status":"completed"}}"#,
                                    observed: observed)
        let job = try decodeCronJob(#"{"id":"job1","profile":"default"}"#)
        let model = TaskDetailViewModel(job: job, runningElapsed: 42,
                                        server: URL(string: "https://example.test")!, client: client)
        let oldLoad = Task { await model.load() }
        await fulfillment(of: [observed], timeout: 2)
        await model.load()
        XCTAssertEqual(model.job.name, "New")
        XCTAssertNil(model.runningElapsed)
        CronReadGateURLProtocol.release()
        await oldLoad.value
        XCTAssertEqual(model.job.name, "New")
        XCTAssertNil(model.runningElapsed)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.errorMessage)
    }

    private func makeGatedClient(path: String, first: String, later: String,
                                 observed: XCTestExpectation) -> APIClient {
        CronReadGateURLProtocol.configure(path: path, first: first, later: later, observed: observed)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CronReadGateURLProtocol.self]
        return APIClient(baseURL: URL(string: "https://example.test")!, session: URLSession(configuration: configuration))
    }

    @MainActor
    func testCreatePartialRegistrationKeepsSavedJobAndPreventsDuplicateCreate() async throws {
        var writes = 0
        let client = makeClient { request in
            if request.httpMethod == "POST" {
                writes += 1
                let body = #"{"detail":{"job_id":"saved-job","job_saved":true,"scheduler_registered":false,"retry_create":false}}"#
                return (HTTPURLResponse(url: request.url!, statusCode: 424, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, Data(body.utf8))
            }
            if request.url?.path == "/api/cron/jobs" {
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "profile" })?.value, "default")
                return apiTestJSONResponse(#"[{"id":"saved-job","profile":"default","prompt":"run"}]"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/cron/jobs/saved-job")
            return apiTestJSONResponse(#"{"id":"saved-job","profile":"default","prompt":"run","state":"scheduled"}"#, for: request)
        }
        let model = TasksViewModel(server: URL(string: "https://example.test")!, client: client)
        let draft = CronJobEditorDraft(prompt: "run", schedule: "0 7 * * *")
        let created = await model.create(from: draft)
        XCTAssertFalse(created)
        XCTAssertEqual(model.jobs.map(\.jobId), ["saved-job"])
        XCTAssertTrue(model.creationNeedsInspection)
        let retried = await model.create(from: draft)
        XCTAssertFalse(retried)
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(model.actionErrorMessage?.contains("saved") == true)
        model.acknowledgeCreationInspection()
        XCTAssertTrue(model.creationNeedsInspection, "Acknowledgment before successful inspection must not unlock creation")
        await model.inspectCreationOutcome()
        XCTAssertEqual(model.creationInspectionJobs.map(\.jobId), ["saved-job"])
        XCTAssertTrue(model.creationInspectionReady)
        XCTAssertTrue(model.creationNeedsInspection, "Inspection alone must not unlock creation")
        model.acknowledgeCreationInspection()
        XCTAssertFalse(model.creationNeedsInspection)
        XCTAssertEqual(writes, 1, "Inspection and acknowledgment must never retry creation")
    }

    @MainActor
    func testAmbiguousCreateDoesNotRetryOrInventJob() async throws {
        var writes = 0
        let client = makeClient { _ in writes += 1; throw URLError(.networkConnectionLost) }
        let model = TasksViewModel(server: URL(string: "https://example.test")!, client: client)
        let draft = CronJobEditorDraft(prompt: "run", schedule: "0 7 * * *")
        let created = await model.create(from: draft)
        XCTAssertFalse(created)
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertTrue(model.creationNeedsInspection)
        let retried = await model.create(from: draft)
        XCTAssertFalse(retried)
        XCTAssertEqual(writes, 1)
        await model.inspectCreationOutcome()
        XCTAssertFalse(model.creationInspectionReady)
        model.acknowledgeCreationInspection()
        XCTAssertTrue(model.creationNeedsInspection, "Failed inspection must leave the safeguard intact")
    }

    @MainActor
    func testTriggerCompletedOneShotDoesNotInventRunningBadge() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/cron/jobs/job123/trigger" {
                return apiTestJSONResponse(#"{"id":"job123","profile":"default","state":"completed","enabled":false}"#, for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/cron/jobs")
            return apiTestJSONResponse("[]", for: request)
        }
        let model = TaskDetailViewModel(job: try decodeCronJob(#"{"id":"job123","profile":"default"}"#), runningElapsed: nil,
            server: URL(string: "https://example.test")!, client: client)
        let ran = await model.runNow()
        XCTAssertTrue(ran)
        XCTAssertNil(model.runningElapsed)
        XCTAssertEqual(model.job.state, "completed")
        XCTAssertEqual(model.lastMutation, .delete(jobID: "job123"))
    }

    @MainActor
    func testAmbiguousDeletePreservesRowAndBlocksRepeatedMutation() async throws {
        var writes = 0
        let client = makeClient { _ in writes += 1; throw URLError(.networkConnectionLost) }
        let model = TaskDetailViewModel(job: try decodeCronJob(#"{"id":"job123","profile":"default"}"#), runningElapsed: nil,
            server: URL(string: "https://example.test")!, client: client)
        let deleted = await model.delete()
        XCTAssertFalse(deleted)
        XCTAssertNil(model.lastMutation)
        XCTAssertEqual(model.job.jobId, "job123")
        let retried = await model.delete()
        XCTAssertFalse(retried)
        XCTAssertEqual(writes, 1)
    }

    @MainActor
    func testTasksViewModelCreateInsertsReturnedJob() async throws {
        let client = makeClient { request in
            XCTAssertTrue(["/api/cron/jobs", "/api/cron/jobs/job-created"].contains(request.url?.path ?? ""))

            return apiTestJSONResponse("""
            {
                "id": "job-created",
                "profile": "default",
                "name": "Created",
                "prompt": "Run it",
                "schedule": {"kind": "cron", "expr": "0 7 * * *"},
                "enabled": true,
                "state": "scheduled"
            }
            """, for: request)
        }
        let viewModel = TasksViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        let didCreate = await viewModel.create(
            from: CronJobEditorDraft(
                name: "Created",
                prompt: "Run it",
                schedule: "0 7 * * *"
            )
        )

        XCTAssertTrue(didCreate)
        XCTAssertEqual(viewModel.jobs.map(\.jobId), ["job-created"])
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    @MainActor
    func testTasksViewModelLoadPopulatesDeliveryOptions() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/cron/jobs":
                return apiTestJSONResponse("[]", for: request)
            case "/api/cron/delivery-targets":
                return apiTestJSONResponse(
                    #"{"targets": [{"id": "local", "name": "Local (save output only)"}]}"#,
                    for: request
                )
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = TasksViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        await viewModel.load()

        XCTAssertEqual(viewModel.deliveryOptions?.count, 1)
        XCTAssertEqual(viewModel.deliveryOptions?.first?.value, "local")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testTasksViewModelLoadToleratesDeliveryOptionsFailure() async throws {
        let client = makeClient { request in
            switch request.url?.path {
            case "/api/cron/jobs":
                return apiTestJSONResponse(#"[{"id": "job123", "name": "Digest", "profile": "default"}]"#, for: request)
            case "/api/cron/delivery-targets":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Data(#"{"error": "not found"}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                return apiTestJSONResponse("{}", for: request)
            }
        }
        let viewModel = TasksViewModel(server: try XCTUnwrap(URL(string: "https://example.test")), client: client)

        await viewModel.load()

        XCTAssertNil(viewModel.deliveryOptions, "Endpoint failure must fall back to free-text deliver entry.")
        XCTAssertEqual(viewModel.jobs.map(\.jobId), ["job123"], "Jobs must still load when delivery options fail.")
        XCTAssertNil(viewModel.errorMessage)
    }

    @MainActor
    func testTaskDetailViewModelPauseUpdatesJobAndPublishesMutation() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/cron/jobs" {
                return apiTestJSONResponse(#"[{"id":"job123","profile":"default","enabled":false,"state":"paused","latest_execution":{"status":"completed"}}]"#, for: request)
            }
            if request.url?.path == "/api/cron/delivery-targets" {
                return apiTestJSONResponse(#"{"targets":[]}"#, for: request)
            }
            if request.url?.path == "/api/cron/jobs/job123/runs" {
                return apiTestJSONResponse(#"{"runs":[],"limit":5}"#, for: request)
            }
            XCTAssertTrue(["/api/cron/jobs/job123/pause", "/api/cron/jobs/job123"].contains(request.url?.path ?? ""))
            return apiTestJSONResponse("""
            {
                "id": "job123",
                "profile": "default",
                "name": "Digest",
                "prompt": "Run it",
                "schedule": {"kind": "cron", "expr": "0 7 * * *"},
                "enabled": false,
                "state": "paused"
            }
            """, for: request)
        }
        let viewModel = TaskDetailViewModel(
            job: try decodeCronJob("""
            {
              "id": "job123",
              "name": "Digest",
              "prompt": "Run it",
              "schedule": {"kind": "cron", "expr": "0 7 * * *"},
              "enabled": true,
              "state": "scheduled"
            }
            """),
            runningElapsed: 12,
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        let didPause = await viewModel.pause()

        XCTAssertTrue(didPause)
        XCTAssertEqual(viewModel.job.status, .paused)
        XCTAssertNil(viewModel.runningElapsed)
        guard case .upsert(let updatedJob) = viewModel.lastMutation else {
            XCTFail("Expected upsert mutation.")
            return
        }
        XCTAssertEqual(updatedJob.jobId, "job123")
    }

    @MainActor
    func testPauseRejectsConcurrentResumeUntilReceiptArrives() async throws {
        let observed = expectation(description: "pause held")
        let paused = #"{"id":"job1","profile":"default","enabled":false,"state":"paused"}"#
        let client = makeGatedClient(path: "/api/cron/jobs/job1/pause", first: paused, later: paused, observed: observed)
        let model = TaskDetailViewModel(job: try decodeCronJob(#"{"id":"job1","profile":"default"}"#),
                                        runningElapsed: nil, server: URL(string: "https://example.test")!, client: client)
        let pause = Task { await model.pause() }
        await fulfillment(of: [observed], timeout: 2)
        let resumed = await model.resume()
        XCTAssertFalse(resumed)
        XCTAssertTrue(model.isMutating)
        CronReadGateURLProtocol.release()
        let result = await pause.value
        XCTAssertTrue(result)
        XCTAssertEqual(model.job.state, "paused")
        XCTAssertFalse(model.isMutating)
    }

    @MainActor
    func testPrePauseReadCannotOverwriteConfirmedPausedJob() async throws {
        let observed = expectation(description: "old detail held")
        let client = makeGatedClient(path: "/api/cron/jobs/job1",
                                    first: #"{"id":"job1","profile":"default","enabled":true,"state":"scheduled"}"#,
                                    later: #"{"id":"job1","profile":"default","enabled":false,"state":"paused"}"#,
                                    observed: observed)
        let model = TaskDetailViewModel(job: try decodeCronJob(#"{"id":"job1","profile":"default"}"#),
                                        runningElapsed: nil, server: URL(string: "https://example.test")!, client: client)
        let oldLoad = Task { await model.load() }
        await fulfillment(of: [observed], timeout: 2)
        let paused = await model.pause()
        XCTAssertTrue(paused)
        CronReadGateURLProtocol.release()
        await oldLoad.value
        XCTAssertEqual(model.job.state, "paused")
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testTaskDetailViewModelDeletePublishesDeleteMutation() async throws {
        let client = makeClient { request in
            if request.url?.path == "/api/cron/jobs" {
                XCTAssertEqual(request.httpMethod, "GET")
                return apiTestJSONResponse("[]", for: request)
            }
            XCTAssertEqual(request.url?.path, "/api/cron/jobs/job123")
            XCTAssertEqual(request.httpMethod, "DELETE")

            return apiTestJSONResponse("""
            {
              "ok": true,
              "job": {"id": "job123"}
            }
            """, for: request)
        }
        let viewModel = TaskDetailViewModel(
            job: try decodeCronJob(#"{"id": "job123", "name": "Digest"}"#),
            runningElapsed: nil,
            server: try XCTUnwrap(URL(string: "https://example.test")),
            client: client
        )

        let didDelete = await viewModel.delete()

        XCTAssertTrue(didDelete)
        XCTAssertEqual(viewModel.lastMutation, .delete(jobID: "job123"))
    }

    private func makeClient(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> APIClient {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)

        return APIClient(baseURL: URL(string: "https://example.test")!, session: session)
    }

    private func decodeCronJob(_ json: String) throws -> CronJob {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CronJob.self, from: Data(json.utf8))
    }
}

/// Holds only the first selected response without blocking URLProtocol's queue.
private final class CronReadGateURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var path = ""
    private static var first = ""
    private static var later = ""
    private static var observed: XCTestExpectation?
    private static var held: CronReadGateURLProtocol?
    private static var selectedCount = 0

    static func configure(path: String, first: String, later: String, observed: XCTestExpectation) {
        lock.lock()
        defer { lock.unlock() }
        self.path = path; self.first = first; self.later = later
        self.observed = observed; held = nil; selectedCount = 0
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        held = nil; observed = nil; selectedCount = 0
    }

    static func release() {
        lock.lock()
        let pending = held
        let payload = first
        held = nil
        lock.unlock()
        pending?.respond(payload)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() { }

    override func startLoading() {
        Self.lock.lock()
        if request.url?.path == Self.path {
            Self.selectedCount += 1
            if Self.selectedCount == 1 {
                Self.held = self
                let observed = Self.observed
                Self.lock.unlock()
                observed?.fulfill()
                return
            }
            let payload = Self.later
            Self.lock.unlock()
            respond(payload)
            return
        }
        let later = Self.later
        Self.lock.unlock()
        if request.url?.path == "/api/cron/jobs" {
            respond("[\(later)]")
        } else if request.url?.path.hasSuffix("/runs") == true {
            respond(#"{"runs":[],"limit":5}"#)
        } else if request.url?.path.hasPrefix("/api/cron/jobs/") == true {
            respond(later)
        } else {
            respond(#"{"targets":[]}"#)
        }
    }

    private func respond(_ payload: String) {
        let (response, data) = apiTestJSONResponse(payload, for: request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
