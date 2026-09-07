import Foundation
import XCTest
@testable import HermesMobile

@MainActor
final class GatewayConversationAttachmentTests: XCTestCase {
    func testStageWritesMarkerBeforeDispatchAndSameRuntimeReopenBlocks() async throws {
        let fake = AttachmentFakeTransport()
        let gate = AttachmentGate()
        fake.setAttachmentGate("image.attach_bytes", gate)
        fake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        fake.setResponse("session.resume", .object([
            "session_id": .string("runtime-1"),
            "session_key": .string("durable-1")
        ]))
        let runtime = try makeRuntime(fake)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GatewayConversationAttachmentMarkerLifecycle-\(UUID().uuidString)", isDirectory: true)
        let store = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: root)
        let controller = makeController(runtime: runtime, markerStore: store)
        let image = DirectPendingAttachment(source: try .image(data: pngData, filename: "photo.png"))
        let stage = Task { try await controller.stageAttachment(image) }
        await waitUntil { fake.calls().contains { $0.method == "image.attach_bytes" } }
        let identity = try DirectGatewayAttachmentRecoveryIdentity(
            origin: runtime.origin,
            profile: "default",
            storedID: "durable-1",
            runtimeID: "runtime-1"
        )
        XCTAssertNotNil(try store.load(for: identity), "The marker must exist before RPC release")
        await gate.release()
        _ = try await stage.value

        let reopened = makeController(runtime: runtime, storedID: "durable-1", markerStore: store)
        try await reopened.open()
        XCTAssertTrue(reopened.attachmentRecoveryNeedsReset)
        do {
            _ = try await reopened.stageAttachment(DirectPendingAttachment(source: try .image(data: pngData, filename: "again.png")))
            XCTFail("A reopened same-runtime controller must block unresolved staging")
        } catch DirectGatewayAttachmentStageError.definiteBeforeStage(.image, .unresolvedAttachment) { }
        await runtime.stop()
    }

    func testTerminalKnownImageDetachesThenClearsMarker() async throws {
        let fake = AttachmentFakeTransport()
        fake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        let runtime = try makeRuntime(fake)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GatewayConversationAttachmentMarkerTerminal-\(UUID().uuidString)", isDirectory: true)
        let store = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: root)
        let controller = makeController(runtime: runtime, markerStore: store)
        var image = DirectPendingAttachment(source: try .image(data: pngData, filename: "photo.png"))
        let staged = try await controller.stageAttachment(image)
        XCTAssertTrue(image.confirm(scope: staged.scope, serverDetachPaths: staged.receipt.detachPaths))
        try await controller.submit("consume", stagedAttachments: [image])
        fake.emit(HermesGatewayEvent(
            method: "event",
            type: "message.complete",
            sessionID: "runtime-1",
            sequence: 1,
            payload: .object(["status": .string("complete")]),
            params: nil,
            connectionGeneration: 1
        ))
        let identity = try DirectGatewayAttachmentRecoveryIdentity(
            origin: runtime.origin,
            profile: "default",
            storedID: "durable-1",
            runtimeID: "runtime-1"
        )
        XCTAssertNotNil(try store.load(for: identity), "ACK alone must retain the marker")
        XCTAssertFalse(fake.calls().contains { $0.method == "image.detach" })
        await waitUntil { (try? store.load(for: identity)) == nil }
        XCTAssertEqual(fake.calls().filter { $0.method == "image.detach" }.count, 1)
        XCTAssertEqual(fake.calls().last?.method, "image.detach")
        await runtime.stop()
    }

    func testTerminalWithRunningStatusRetainsMarkerWithoutDetach() async throws {
        let fake = AttachmentFakeTransport()
        fake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        fake.setResponse("session.status", .object(["output": .string("Agent Running: Yes")]))
        let runtime = try makeRuntime(fake)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GatewayConversationAttachmentMarkerRunning-\(UUID().uuidString)", isDirectory: true)
        let store = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: root)
        let controller = makeController(runtime: runtime, markerStore: store)
        var image = DirectPendingAttachment(source: try .image(data: pngData, filename: "photo.png"))
        let staged = try await controller.stageAttachment(image)
        XCTAssertTrue(image.confirm(scope: staged.scope, serverDetachPaths: staged.receipt.detachPaths))
        try await controller.submit("running", stagedAttachments: [image])
        fake.emit(HermesGatewayEvent(
            method: "event",
            type: "message.complete",
            sessionID: "runtime-1",
            sequence: 1,
            payload: .object(["status": .string("complete")]),
            params: nil,
            connectionGeneration: 1
        ))
        await waitUntil { fake.calls().contains { $0.method == "session.status" } }
        XCTAssertTrue(controller.attachmentRecoveryNeedsReset)
        XCTAssertFalse(fake.calls().contains { $0.method == "image.detach" })
        await runtime.stop()
    }

    func testExplicitResetClosesOnlyTargetAndRemovesMarker() async throws {
        let fake = AttachmentFakeTransport()
        fake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        let runtime = try makeRuntime(fake)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GatewayConversationAttachmentMarkerReset-\(UUID().uuidString)", isDirectory: true)
        let store = DirectGatewayAttachmentRecoveryMarkerStore(rootURL: root)
        let controller = makeController(runtime: runtime, markerStore: store)
        _ = try await controller.stageAttachment(DirectPendingAttachment(source: try .image(data: pngData, filename: "photo.png")))
        let token = try XCTUnwrap(controller.unresolvedAttachmentMarkerToken)
        try await controller.resetPendingAttachments(expectedToken: token)
        XCTAssertFalse(controller.attachmentRecoveryNeedsReset)
        XCTAssertNil(controller.binding)
        XCTAssertEqual(fake.calls().filter { $0.method == "session.close" }.count, 1)
        await runtime.stop()
    }

    func testStageImageFileAndPDFUseExactRPCShapesAndScope() async throws {
        let fake = AttachmentFakeTransport()
        fake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        fake.setResponse("file.attach", .object([
            "attached": .bool(true),
            "name": .string("notes.txt"),
            "path": .string("/profile/attachments/notes.txt"),
            "ref_path": .string("/profile/attachments/notes.txt"),
            "ref_text": .string("@file:/profile/attachments/notes.txt"),
            "uploaded": .bool(true)
        ]))
        fake.setResponse("pdf.attach", .object([
            "attached": .bool(true),
            "filename": .string("report.pdf"),
            "pages_attached": .number(1),
            "pages": .array([
                .object(["path": .string("/profile/images/pdf_p1.png"), "page": .number(1)])
            ])
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)

        var image = DirectPendingAttachment(source: try DirectGatewayAttachment.image(
            data: pngData,
            filename: "photo.png"
        ))
        let imageResult = try await controller.stageAttachment(image, create: [
            "cwd": .string("/workspace"),
            "model": .string("fixture-model")
        ])
        XCTAssertEqual(imageResult.scope.origin, "https://fixture.example")
        XCTAssertEqual(imageResult.scope.runtimeID, "runtime-1")
        XCTAssertEqual(imageResult.receipt.detachPaths, ["/profile/images/photo.png"])
        XCTAssertTrue(image.confirm(
            scope: imageResult.scope,
            serverDetachPaths: imageResult.receipt.detachPaths
        ))

        let file = DirectPendingAttachment(source: try DirectGatewayAttachment.file(
            data: Data("notes".utf8),
            filename: "notes.txt"
        ))
        let fileResult = try await controller.stageAttachment(file)
        XCTAssertEqual(fileResult.receipt.referenceText, "@file:/profile/attachments/notes.txt")

        let pdf = DirectPendingAttachment(source: try .pdf(data: Data("%PDF-1.4\n".utf8), filename: "report.pdf"))
        let pdfResult = try await controller.stageAttachment(pdf)
        XCTAssertEqual(pdfResult.receipt.pdfPageCount, 1)

        let calls = fake.calls()
        XCTAssertEqual(calls.map(\.method), ["session.create", "image.attach_bytes", "file.attach", "pdf.attach"])
        let imageFields = try XCTUnwrap(objectFields(calls[1].params))
        XCTAssertNil(calls[1].timeout)
        XCTAssertEqual(imageFields["session_id"], .string("runtime-1"))
        XCTAssertEqual(imageFields["profile"], .string("default"))
        XCTAssertEqual(imageFields["filename"], .string("photo.png"))
        XCTAssertNotNil(imageFields["content_base64"])
        XCTAssertNil(imageFields["path"])

        let fileFields = try XCTUnwrap(objectFields(calls[2].params))
        XCTAssertNil(calls[2].timeout)
        XCTAssertEqual(fileFields["name"], .string("notes.txt"))
        XCTAssertNotNil(fileFields["data_url"])
        XCTAssertNil(fileFields["path"])

        let pdfFields = try XCTUnwrap(objectFields(calls[3].params))
        XCTAssertEqual(calls[3].timeout, .seconds(135))
        XCTAssertEqual(pdfFields["filename"], .string("report.pdf"))
        XCTAssertNotNil(pdfFields["content_base64"])
        XCTAssertNil(pdfFields["path"])
        XCTAssertFalse(calls.contains { $0.method == "prompt.submit" })
        await runtime.stop()
    }

    func testSubmitUsesExactConfirmedFileReference() async throws {
        let fake = AttachmentFakeTransport()
        fake.setResponse("file.attach", .object([
            "attached": .bool(true),
            "name": .string("notes.txt"),
            "path": .string("/profile/attachments/notes.txt"),
            "ref_path": .string("/profile/attachments/notes.txt"),
            "ref_text": .string("@file:/profile/attachments/notes.txt"),
            "uploaded": .bool(true)
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        var file = DirectPendingAttachment(source: try .file(data: Data("notes".utf8), filename: "notes.txt"))
        let result = try await controller.stageAttachment(file)
        XCTAssertTrue(file.confirm(scope: result.scope, referenceText: result.receipt.referenceText))

        try await controller.submit("read this", stagedAttachments: [file])
        let prompt = try XCTUnwrap(fake.calls().first { $0.method == "prompt.submit" })
        let fields = try XCTUnwrap(objectFields(prompt.params))
        XCTAssertEqual(fields["text"], .string("read this\n@file:/profile/attachments/notes.txt"))
        await runtime.stop()
    }

    func testSubmitRejectsPendingUnknownAndMismatchedStagesWithoutPrompt() async throws {
        let fake = AttachmentFakeTransport()
        fake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        let pending = DirectPendingAttachment(source: try .image(data: pngData, filename: "photo.png"))

        do {
            try await controller.submit("pending", stagedAttachments: [pending])
            XCTFail("Pending attachments must not submit")
        } catch DirectSessionError.invalidResponse { }

        var unknown = pending
        let staged = try await controller.stageAttachment(unknown)
        XCTAssertTrue(unknown.markUnknown(scope: staged.scope))
        do {
            try await controller.submit("unknown", stagedAttachments: [unknown])
            XCTFail("Unknown attachment outcomes must not submit")
        } catch DirectSessionError.invalidResponse { }

        var mismatched = pending
        let wrongScope = DirectPendingAttachmentStageScope(
            binding: GatewaySessionBinding(storedID: "durable-1", runtimeID: "runtime-1", profile: "default"),
            connectionGeneration: staged.scope.connectionGeneration,
            origin: URL(string: "https://other.example")!,
            turnEpoch: staged.scope.turnEpoch
        )
        XCTAssertTrue(mismatched.confirm(scope: wrongScope))
        do {
            try await controller.submit("mismatch", stagedAttachments: [mismatched])
            XCTFail("Mismatched attachment scope must not submit")
        } catch DirectSessionError.invalidResponse { }

        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })
        await runtime.stop()
    }

    func testConfirmedStageCannotBeReusedAfterExternalTurn() async throws {
        let fake = AttachmentFakeTransport()
        fake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        var image = DirectPendingAttachment(source: try .image(data: pngData, filename: "photo.png"))
        let staged = try await controller.stageAttachment(image)
        XCTAssertTrue(image.confirm(scope: staged.scope, serverDetachPaths: staged.receipt.detachPaths))
        try await controller.submit("first", stagedAttachments: [image])

        fake.emit(HermesGatewayEvent(
            method: "event",
            type: "error",
            sessionID: "runtime-1",
            sequence: 2,
            payload: .object(["message": .string("Turn cancelled before the agent was ready")]),
            params: nil,
            connectionGeneration: 1
        ))
        await waitUntil { controller.runState == .idle }
        do {
            try await controller.submit("reuse", stagedAttachments: [image])
            XCTFail("A confirmed stage from an earlier turn must not be reused")
        } catch DirectSessionError.invalidResponse { }
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        await runtime.stop()
    }

    func testStagedSubmitAcceptsNormalEventsBeforeAcknowledgement() async throws {
        for eventType in ["message.start", "error"] {
            let fake = AttachmentFakeTransport()
            let gate = AttachmentGate()
            fake.setRequestGate("prompt.submit", gate)
            fake.setResponse("image.attach_bytes", .object([
                "attached": .bool(true),
                "path": .string("/profile/images/photo.png"),
                "name": .string("photo.png")
            ]))
            let runtime = try makeRuntime(fake)
            let controller = makeController(runtime: runtime)
            var image = DirectPendingAttachment(source: try .image(data: pngData, filename: "photo.png"))
            let staged = try await controller.stageAttachment(image)
            XCTAssertTrue(image.confirm(scope: staged.scope, serverDetachPaths: staged.receipt.detachPaths))
            let submit = Task { try await controller.submit("event-safe", stagedAttachments: [image]) }
            await waitUntil { fake.calls().contains { $0.method == "prompt.submit" } }

            let payload: JSONValue? = eventType == "error"
                ? .object(["message": .string("Turn cancelled before the agent was ready")])
                : nil
            fake.emit(HermesGatewayEvent(
                method: "event",
                type: eventType,
                sessionID: "runtime-1",
                sequence: 3,
                payload: payload,
                params: nil,
                connectionGeneration: 1
            ))
            if eventType == "message.start" {
                await waitUntil { controller.runState == .running }
            } else {
                await waitUntil { controller.runState == .idle }
            }
            await gate.release()
            try await submit.value
            XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
            await runtime.stop()
        }
    }

    func testLateSubmitErrorAfterTerminalEventSetsStickyAmbiguousBarrier() async throws {
        let fake = AttachmentFakeTransport()
        let gate = AttachmentGate()
        fake.setRequestGate("prompt.submit", gate)
        fake.setServerError("prompt.submit", .transport("late prompt failure"))
        fake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        var image = DirectPendingAttachment(source: try .image(data: pngData, filename: "photo.png"))
        let staged = try await controller.stageAttachment(image)
        XCTAssertTrue(image.confirm(scope: staged.scope, serverDetachPaths: staged.receipt.detachPaths))

        let submit = Task { try await controller.submit("late", stagedAttachments: [image]) }
        await waitUntil { fake.calls().contains { $0.method == "prompt.submit" } }
        fake.emit(HermesGatewayEvent(
            method: "event",
            type: "message.complete",
            sessionID: "runtime-1",
            sequence: 3,
            payload: .object(["text": .string("terminal from another queued turn")]),
            params: nil,
            connectionGeneration: 1
        ))
        await waitUntil { controller.runState == .idle }
        await gate.release()

        do {
            _ = try await submit.value
            XCTFail("The late submit transport failure must remain observable")
        } catch HermesGatewayError.transport { }
        XCTAssertTrue(controller.hasAmbiguousPromptDelivery)
        XCTAssertEqual(controller.runState, .idle, "Terminal display state must remain idle")

        fake.emit(HermesGatewayEvent(
            method: "event",
            type: "message.start",
            sessionID: "runtime-1",
            sequence: 4,
            payload: nil,
            params: nil,
            connectionGeneration: 1
        ))
        fake.emit(HermesGatewayEvent(
            method: "event",
            type: "message.complete",
            sessionID: "runtime-1",
            sequence: 5,
            payload: .object(["text": .string("later terminal")]),
            params: nil,
            connectionGeneration: 1
        ))
        await Task.yield()
        XCTAssertTrue(controller.hasAmbiguousPromptDelivery)

        fake.setResponse("session.resume", .object([
            "session_id": .string("runtime-1"),
            "session_key": .string("durable-1")
        ]))
        try await runtime.reconnect()
        XCTAssertTrue(
            controller.hasAmbiguousPromptDelivery,
            "A canonical resume must not clear an unresolved delivery without exact acceptance proof"
        )

        do {
            try await controller.submit("must not retry")
            XCTFail("The sticky barrier must block a later prompt")
        } catch DirectSessionError.ambiguousPrompt { }
        let retryImage = DirectPendingAttachment(source: try .image(data: pngData, filename: "retry.png"))
        do {
            _ = try await controller.stageAttachment(retryImage)
            XCTFail("The sticky barrier must block a later attachment stage")
        } catch DirectGatewayAttachmentStageError.definiteBeforeStage(
            .image,
            .ambiguousPromptDelivery
        ) { }
        XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
        XCTAssertEqual(fake.calls().filter { $0.method == "image.attach_bytes" }.count, 1)
        await runtime.stop()
    }

    func testDefinitivePromptServerRejectionDoesNotSetAmbiguousBarrier() async throws {
        let fake = AttachmentFakeTransport()
        fake.setServerError("prompt.submit", .server(
            code: 4090,
            message: "Another prompt is already running for this session.",
            data: nil,
            method: "prompt.submit",
            requestID: "prompt-rejected",
            server: "fixture"
        ))
        fake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        var image = DirectPendingAttachment(source: try .image(data: pngData, filename: "photo.png"))
        let staged = try await controller.stageAttachment(image)
        XCTAssertTrue(image.confirm(scope: staged.scope, serverDetachPaths: staged.receipt.detachPaths))

        do {
            try await controller.submit("rejected", stagedAttachments: [image])
            XCTFail("The definite server rejection must be surfaced")
        } catch HermesGatewayError.server { }
        XCTAssertFalse(controller.hasAmbiguousPromptDelivery)
        XCTAssertEqual(controller.runState, .idle)
        await runtime.stop()
    }

    func testInternalUnknownAndMismatchedPromptErrorsSetAmbiguousBarrier() async throws {
        let cases: [(code: Int, message: String, method: String)] = [
            (-32603, "internal error", "prompt.submit"),
            (5070, "storage full after inflight", "prompt.submit"),
            (5071, "storage failure after inflight", "prompt.submit"),
            (5072, "storage unavailable after inflight", "prompt.submit"),
            (5008, "history truncation persistence failed", "prompt.submit"),
            (4999, "future server error", "prompt.submit"),
            (4090, "wrong RPC method", "file.attach")
        ]

        for (index, testCase) in cases.enumerated() {
            let fake = AttachmentFakeTransport()
            fake.setServerError("prompt.submit", .server(
                code: testCase.code,
                message: testCase.message,
                data: nil,
                method: testCase.method,
                requestID: "ambiguous-\(index)",
                server: "fixture"
            ))
            let runtime = try makeRuntime(fake)
            let controller = makeController(runtime: runtime)

            do {
                try await controller.submit("ambiguous-\(index)")
                XCTFail("The configured server error must be surfaced")
            } catch HermesGatewayError.server { }

            XCTAssertTrue(controller.hasAmbiguousPromptDelivery, "case \(index)")
            XCTAssertEqual(controller.runState, .deliveryUnknown, "case \(index)")
            XCTAssertEqual(fake.calls().filter { $0.method == "prompt.submit" }.count, 1)
            do {
                try await controller.submit("must not retry")
                XCTFail("The sticky barrier must block case \(index) retry")
            } catch DirectSessionError.ambiguousPrompt { }
            await runtime.stop()
        }
    }

    func testValidationAndMalformedStageFailuresNeverSubmit() async throws {
        let fake = AttachmentFakeTransport()
        fake.setServerError("image.attach_bytes", .server(
            code: 4016,
            message: "unsupported image extension",
            data: nil,
            method: "image.attach_bytes",
            requestID: "2",
            server: "fixture"
        ))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        let image = DirectPendingAttachment(source: try DirectGatewayAttachment.image(
            data: pngData,
            filename: "photo.png"
        ))

        do {
            _ = try await controller.stageAttachment(image)
            XCTFail("Expected a definite image validation rejection")
        } catch DirectGatewayAttachmentStageError.definiteBeforeStage(
            let kind,
            .serverRejected(let code, _)
        ) {
            XCTAssertEqual(kind, .image)
            XCTAssertEqual(code, 4016)
        }
        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })

        await runtime.stop()

        let mismatchFake = AttachmentFakeTransport()
        mismatchFake.setServerError("image.attach_bytes", .server(
            code: 4016,
            message: "unsupported image extension",
            data: nil,
            method: "file.attach",
            requestID: "2-mismatch",
            server: "fixture"
        ))
        let mismatchRuntime = try makeRuntime(mismatchFake)
        let mismatchController = makeController(runtime: mismatchRuntime)
        let mismatchImage = DirectPendingAttachment(source: try DirectGatewayAttachment.image(
            data: pngData,
            filename: "photo.png"
        ))
        do {
            _ = try await mismatchController.stageAttachment(mismatchImage)
            XCTFail("A mismatched server method must not be treated as definite")
        } catch DirectGatewayAttachmentStageError.unknown(
            .image,
            _,
            .server(let code, _)
        ) {
            XCTAssertEqual(code, 4016)
        }
        await mismatchRuntime.stop()

        let malformedFake = AttachmentFakeTransport()
        malformedFake.setResponse("image.attach_bytes", .object(["attached": .bool(true)]))
        let malformedRuntime = try makeRuntime(malformedFake)
        let malformedController = makeController(runtime: malformedRuntime)
        let malformedImage = DirectPendingAttachment(source: try DirectGatewayAttachment.image(
            data: pngData,
            filename: "photo.png"
        ))
        do {
            _ = try await malformedController.stageAttachment(malformedImage)
            XCTFail("Expected malformed receipt")
        } catch DirectGatewayAttachmentStageError.unknown(_, let scope, .malformedResponse) {
            XCTAssertEqual(scope.runtimeID, "runtime-1")
        }
        await malformedRuntime.stop()

        let transportFake = AttachmentFakeTransport()
        transportFake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        transportFake.setServerError("image.attach_bytes", .timeout(
            method: "image.attach_bytes",
            requestID: "3"
        ))
        let transportRuntime = try makeRuntime(transportFake)
        let transportController = makeController(runtime: transportRuntime)
        let transportImage = DirectPendingAttachment(source: try DirectGatewayAttachment.image(
            data: pngData,
            filename: "photo.png"
        ))
        do {
            _ = try await transportController.stageAttachment(transportImage)
            XCTFail("Expected a transport failure with unknown stage outcome")
        } catch DirectGatewayAttachmentStageError.unknown(_, _, .transport) { }
        do {
            try await transportController.submit("must stay blocked")
            XCTFail("Unknown image staging must block plain sends")
        } catch DirectSessionError.unresolvedAttachment { }
        do {
            _ = try await transportController.stageAttachment(DirectPendingAttachment(source: try .image(data: pngData, filename: "again.png")))
            XCTFail("Unknown image staging must block another stage")
        } catch DirectGatewayAttachmentStageError.definiteBeforeStage(.image, .unresolvedAttachment) { }
        await transportRuntime.stop()

        let pdfFake = AttachmentFakeTransport()
        pdfFake.setServerError("pdf.attach", .server(
            code: 5028,
            message: "pdftoppm unavailable",
            data: nil,
            method: "pdf.attach",
            requestID: "4",
            server: "fixture"
        ))
        let pdfRuntime = try makeRuntime(pdfFake)
        let pdfController = makeController(runtime: pdfRuntime)
        let pdf = DirectPendingAttachment(source: try DirectGatewayAttachment.pdf(
            data: Data("%PDF-1.4\n".utf8), filename: "report.pdf"
        ))
        do {
            _ = try await pdfController.stageAttachment(pdf)
            XCTFail("Expected pinned PDF 5028 pre-queue rejection")
        } catch DirectGatewayAttachmentStageError.definiteBeforeStage(
            .pdf,
            .serverRejected(let code, _)
        ) {
            XCTAssertEqual(code, 5028)
        }
        XCTAssertFalse(pdfFake.calls().contains { $0.method == "prompt.submit" })
        await pdfRuntime.stop()
    }

    func testConcurrentStageAndSubmitAreRejectedWithoutDuplicateStage() async throws {
        let fake = AttachmentFakeTransport()
        let gate = AttachmentGate()
        fake.setAttachmentGate("image.attach_bytes", gate)
        fake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        let image = DirectPendingAttachment(source: try DirectGatewayAttachment.image(
            data: pngData,
            filename: "photo.png"
        ))
        let first = Task { try await controller.stageAttachment(image) }
        await waitUntil { fake.calls().contains { $0.method == "image.attach_bytes" } }

        do {
            _ = try await controller.stageAttachment(image)
            XCTFail("A second stage must not share or duplicate the first request")
        } catch DirectGatewayAttachmentStageError.definiteBeforeStage(_, .controllerBusy) { }

        do {
            try await controller.submit("must wait")
            XCTFail("Submit must remain blocked while attachment staging is in flight")
        } catch DirectSessionError.ambiguousPrompt { }

        await gate.release()
        _ = try await first.value
        XCTAssertEqual(fake.calls().filter { $0.method == "image.attach_bytes" }.count, 1)
        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })
        await runtime.stop()
    }

    func testGenerationChangeAfterDispatchMakesStageUnknownAndDoesNotRetry() async throws {
        let fake = AttachmentFakeTransport()
        let gate = AttachmentGate()
        fake.setAttachmentGate("image.attach_bytes", gate)
        fake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        let image = DirectPendingAttachment(source: try DirectGatewayAttachment.image(
            data: pngData,
            filename: "photo.png"
        ))
        let stage = Task { try await controller.stageAttachment(image) }
        await waitUntil { fake.calls().contains { $0.method == "image.attach_bytes" } }

        try await runtime.reconnect()
        await gate.release()
        do {
            _ = try await stage.value
            XCTFail("A stage crossing a socket generation must not be confirmed")
        } catch DirectGatewayAttachmentStageError.unknown(_, let scope, .staleAfterDispatch) {
            XCTAssertEqual(scope.connectionGeneration, 1)
        }
        XCTAssertEqual(fake.calls().filter { $0.method == "image.attach_bytes" }.count, 1)
        await runtime.stop()
    }

    func testTurnChangeAfterDispatchMakesStageUnknownAndDoesNotRetry() async throws {
        let fake = AttachmentFakeTransport()
        let gate = AttachmentGate()
        fake.setAttachmentGate("image.attach_bytes", gate)
        fake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        let image = DirectPendingAttachment(source: try .image(data: pngData, filename: "photo.png"))
        let stage = Task { try await controller.stageAttachment(image) }
        await waitUntil { fake.calls().contains { $0.method == "image.attach_bytes" } }

        fake.emit(HermesGatewayEvent(
            method: "event",
            type: "message.start",
            sessionID: "runtime-1",
            sequence: 1,
            payload: nil,
            params: nil,
            connectionGeneration: 1
        ))
        await waitUntil { controller.runState == .running }
        await gate.release()
        do {
            _ = try await stage.value
            XCTFail("A stage crossing a new turn must not be confirmed")
        } catch DirectGatewayAttachmentStageError.unknown(_, _, .staleAfterDispatch) { }
        XCTAssertEqual(fake.calls().filter { $0.method == "image.attach_bytes" }.count, 1)
        await runtime.stop()
    }

    func testDisposalAfterDispatchMakesStageUnknownAndDoesNotReviveRuntime() async throws {
        let fake = AttachmentFakeTransport()
        let gate = AttachmentGate()
        fake.setAttachmentGate("image.attach_bytes", gate)
        fake.setResponse("image.attach_bytes", .object([
            "attached": .bool(true),
            "path": .string("/profile/images/photo.png"),
            "name": .string("photo.png")
        ]))
        let runtime = try makeRuntime(fake)
        let controller = makeController(runtime: runtime)
        let image = DirectPendingAttachment(source: try .image(data: pngData, filename: "photo.png"))
        let stage = Task { try await controller.stageAttachment(image) }
        await waitUntil { fake.calls().contains { $0.method == "image.attach_bytes" } }

        try await controller.dispose()
        await gate.release()
        do {
            _ = try await stage.value
            XCTFail("Disposed controller must not accept a stage acknowledgement")
        } catch DirectGatewayAttachmentStageError.unknown(_, _, .staleAfterDispatch) { }
        XCTAssertEqual(fake.calls().filter { $0.method == "image.attach_bytes" }.count, 1)
        XCTAssertFalse(fake.calls().contains { $0.method == "prompt.submit" })
        XCTAssertTrue(fake.calls().contains { $0.method == "session.close" })
        await runtime.stop()
    }

    private func makeRuntime(_ fake: AttachmentFakeTransport) throws -> HermesServerRuntime {
        try HermesServerRuntime(origin: URL(string: "https://fixture.example")!) { sink in
            fake.installSink(sink)
            return fake
        }
    }

    private func makeController(
        runtime: HermesServerRuntime,
        storedID: String? = nil,
        markerStore: DirectGatewayAttachmentRecoveryMarkerStore? = nil
    ) -> GatewayConversationController {
        let store = markerStore ?? DirectGatewayAttachmentRecoveryMarkerStore(
            rootURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("GatewayConversationAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        )
        return GatewayConversationController(runtime: runtime, storedID: storedID, recoveryMarkerStore: store) { id, _, _, _ in
            DirectHermesTranscriptPage(sessionID: id, messages: [], pagination: nil)
        }
    }

    private func objectFields(_ value: JSONValue?) -> [String: JSONValue]? {
        guard let value, case .object(let fields) = value else { return nil }
        return fields
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }

    private var pngData: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }
}

private actor AttachmentGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private final class AttachmentFakeTransport: HermesGatewayTransport, @unchecked Sendable {
    struct Call: Sendable {
        let method: String
        let params: JSONValue?
        let timeout: Duration?
    }

    private let lock = NSLock()
    private var sink: (@Sendable (HermesGatewayEvent) -> Void)?
    private var callsValue: [Call] = []
    private var generationValue = 0
    private var connected = false
    private var responses: [String: JSONValue] = [:]
    private var serverErrors: [String: HermesGatewayError] = [:]
    private var attachmentGates: [String: AttachmentGate] = [:]
    private var requestGates: [String: AttachmentGate] = [:]

    func installSink(_ sink: @escaping @Sendable (HermesGatewayEvent) -> Void) {
        withLock { self.sink = sink }
    }

    func emit(_ event: HermesGatewayEvent) {
        let sink = withLock { self.sink }
        sink?(event)
    }

    func setResponse(_ method: String, _ response: JSONValue) {
        withLock { responses[method] = response }
    }

    func setServerError(_ method: String, _ error: HermesGatewayError?) {
        withLock { serverErrors[method] = error }
    }

    func setAttachmentGate(_ method: String, _ gate: AttachmentGate) {
        withLock { attachmentGates[method] = gate }
    }

    func setRequestGate(_ method: String, _ gate: AttachmentGate) {
        withLock { requestGates[method] = gate }
    }

    func calls() -> [Call] {
        withLock { callsValue }
    }

    func connect() async throws {
        withLock {
            generationValue += 1
            connected = true
        }
    }

    func close() async {
        withLock { connected = false }
    }

    func connectionIdentifier() async -> Int? {
        withLock { connected ? generationValue : nil }
    }

    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue? {
        let (response, error, gate) = withLock {
            callsValue.append(Call(method: method, params: params, timeout: timeout))
            return (responses[method], serverErrors[method], requestGates[method] ?? attachmentGates[method])
        }
        if let gate { await gate.wait() }
        if let error { throw error }
        switch method {
        case "session.create":
            return .object([
                "session_id": .string("runtime-1"),
                "session_key": .string("durable-1")
            ])
        case "session.close":
            return response ?? .object(["closed": .bool(true)])
        case "image.detach":
            return .object(["detached": .bool(false), "count": .number(0)])
        case "session.status":
            return response ?? .object(["output": .string("Agent Running: No")])
        default:
            return response ?? .object(["status": .string("streaming")])
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
