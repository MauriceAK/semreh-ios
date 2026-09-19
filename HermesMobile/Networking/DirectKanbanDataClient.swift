import Foundation

enum DirectKanbanError: LocalizedError, Equatable, Sendable {
    case pluginUnavailable
    case unsupportedOperation
    case createStatusNotRepresentable(String)
    case createStatusMismatch(expected: String, actual: String?)
    case tenantMutationNotSupported

    var errorDescription: String? {
        switch self {
        case .pluginUnavailable:
            "The Hermes Kanban plugin is not available on this server."
        case .unsupportedOperation:
            "That Kanban operation is not available through the stock Hermes plugin."
        case .createStatusNotRepresentable:
            "The stock Hermes plugin cannot create a task with that exact initial status."
        case .createStatusMismatch:
            "Hermes created the task with a different status. Refresh the board before continuing."
        case .tenantMutationNotSupported:
            "The stock Hermes plugin cannot change a task's tenant."
        }
    }
}

/// Typed adapter for the stock dashboard plugin mounted at
/// `/api/plugins/kanban`. Authentication and redirect protection stay inside
/// APIClient's first-party direct request boundary.
struct DirectKanbanDataClient: KanbanDataClient {
    private static let root = "/api/plugins/kanban"
    private static let stockColumns = [
        "triage", "todo", "scheduled", "ready", "running", "blocked", "review", "done"
    ]
    private let apiClient: APIClient

    init(apiClient: APIClient) { self.apiClient = apiClient }

    func kanbanConfiguration() async throws -> KanbanConfiguration {
        do { return try await get("/config", preflight: false) }
        catch let error as DirectHermesRequestError {
            if case .http(statusCode: 404, reason: _) = error { throw DirectKanbanError.pluginUnavailable }
            throw error
        }
    }

    func kanbanBoards() async throws -> KanbanBoardsResponse { try await get("/boards") }
    func kanbanBoard(_ request: KanbanBoardRequest) async throws -> KanbanBoardSnapshot {
        if request.onlyMine, normalized(request.assignee) == nil {
            throw DirectKanbanError.unsupportedOperation
        }
        var query = [URLQueryItem(name: "board", value: request.board)]
        if let tenant = request.tenant, !tenant.isEmpty { query.append(.init(name: "tenant", value: tenant)) }
        if request.includeArchived { query.append(.init(name: "include_archived", value: "true")) }
        let snapshot: KanbanBoardSnapshot = try await get("/board", query: query)
        let assignee = normalized(request.assignee)
        let columns = snapshot.columns?.map { column in
            KanbanColumn(name: column.name, cards: column.cards?.filter {
                assignee == nil || normalized($0.assignee) == assignee
            })
        }
        // Stock `/board` is always a complete authoritative snapshot; it has
        // no `since` short-circuit. Mark it changed rather than preserving the
        // legacy bridge's optional delta vocabulary.
        return KanbanBoardSnapshot(columns: columns, tenants: snapshot.tenants,
            assignees: snapshot.assignees, filters: snapshot.filters, changed: true,
            latestEventID: snapshot.latestEventID, readOnly: snapshot.readOnly)
    }
    func kanbanStats(board: String) async throws -> KanbanStats {
        try await get("/stats", query: [.init(name: "board", value: board)])
    }
    func kanbanAssignees(board: String) async throws -> KanbanAssigneeHistory {
        try await get("/assignees", query: [.init(name: "board", value: board)])
    }
    func kanbanEvents(_ request: KanbanEventsRequest) async throws -> KanbanEventsEnvelope {
        throw DirectKanbanError.unsupportedOperation // Stock events are WebSocket-only.
    }
    func kanbanCardDetail(_ request: KanbanCardDetailRequest) async throws -> KanbanCardDetailEnvelope {
        try await get("/tasks/\(segment(request.cardID))", query: boardQuery(request.board))
    }
    func kanbanWorkerLog(_ request: KanbanWorkerLogRequest) async throws -> KanbanWorkerLog {
        try await get("/tasks/\(segment(request.cardID))/log", query: request.queryItems)
    }

    func createKanbanBoard(_ request: KanbanCreateBoardRequest) async throws -> KanbanBoardMutationEnvelope {
        try await send("/boards", method: "POST", body: DirectCreateBoardBody(request))
    }
    func editKanbanBoard(_ request: KanbanEditBoardRequest) async throws -> KanbanBoardMutationEnvelope {
        try await send("/boards/\(segment(request.slug))", method: "PATCH", body: DirectEditBoardBody(request))
    }
    func archiveKanbanBoard(_ request: KanbanBoardMutationRequest) async throws -> KanbanBoardMutationEnvelope {
        // Omitting `delete=true` is the stock route's explicit archive mode.
        try await send("/boards/\(segment(request.slug))", method: "DELETE")
    }
    func makeKanbanBoardActive(_ request: KanbanBoardMutationRequest) async throws -> KanbanBoardMutationEnvelope {
        try await send("/boards/\(segment(request.slug))/switch", method: "POST")
    }
    func dispatchKanban(_ request: KanbanDispatchRequest) async throws -> KanbanDispatchResult {
        let result: KanbanDispatchResult = try await send("/dispatch", method: "POST", query: request.queryItems)
        guard result.hasKnownCategory else { throw KanbanDispatchResponseError.missingResultCategories }
        return result
    }

    func createKanbanCard(_ request: KanbanCreateCardRequest) async throws -> KanbanCardMutationEnvelope {
        switch request.status {
        case "triage":
            break
        case "ready", "todo":
            guard let parentID = request.prerequisiteID else {
                if request.status == "todo" { throw DirectKanbanError.createStatusNotRepresentable(request.status) }
                break // No parents is atomically `ready` in stock create_task.
            }
            let parent = try await kanbanCardDetail(.init(cardID: parentID, board: request.board))
            let parentDone = parent.card?.status?.rawValue == "done"
            guard (request.status == "ready") == parentDone else {
                throw DirectKanbanError.createStatusNotRepresentable(request.status)
            }
        default:
            throw DirectKanbanError.createStatusNotRepresentable(request.status)
        }
        let response: KanbanCardMutationEnvelope = try await send("/tasks", method: "POST", query: boardQuery(request.board),
            body: DirectCreateTaskBody(request))
        guard response.card?.status?.rawValue == request.status else {
            throw DirectKanbanError.createStatusMismatch(
                expected: request.status, actual: response.card?.status?.rawValue
            )
        }
        return response
    }

    func editKanbanCard(_ request: KanbanEditCardRequest) async throws -> KanbanCardMutationEnvelope {
        let detail = try await kanbanCardDetail(.init(cardID: request.cardID, board: request.board))
        guard normalized(detail.card?.tenant) == normalized(request.tenant) else {
            throw DirectKanbanError.tenantMutationNotSupported
        }
        return try await send("/tasks/\(segment(request.cardID))", method: "PATCH",
            query: boardQuery(request.board), body: DirectEditTaskBody(request))
    }

    func setKanbanCardStatus(_ request: KanbanCardStatusRequest) async throws -> KanbanCardMutationEnvelope {
        guard request.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "running" else {
            throw KanbanRequestError.runningStatusRequiresDispatcher
        }
        return try await patchTask(request.cardID, board: request.board,
            body: DirectTaskStatusBody(status: request.status, blockReason: nil))
    }
    func blockKanbanCard(_ request: KanbanCardActionRequest) async throws -> KanbanCardMutationEnvelope {
        try await patchTask(request.cardID, board: request.board,
            body: DirectTaskStatusBody(status: "blocked", blockReason: request.reason))
    }
    func unblockKanbanCard(_ request: KanbanCardActionRequest) async throws -> KanbanCardMutationEnvelope {
        try await patchTask(request.cardID, board: request.board,
            body: DirectTaskStatusBody(status: "ready", blockReason: nil))
    }
    func addKanbanComment(_ request: KanbanAddCommentRequest) async throws -> KanbanAddCommentResponse {
        try await send("/tasks/\(segment(request.cardID))/comments", method: "POST",
            query: boardQuery(request.board), body: DirectCommentBody(body: request.body))
    }
    func performKanbanBulkAction(_ request: KanbanBulkActionRequest) async throws -> KanbanBulkActionEnvelope {
        try await send("/tasks/bulk", method: "POST", query: boardQuery(request.board),
            body: DirectBulkTaskBody(request))
    }
    func addKanbanDependency(_ request: KanbanDependencyMutationRequest) async throws -> KanbanDependencyMutationEnvelope {
        try await mutateLink(request, method: "POST")
    }
    func removeKanbanDependency(_ request: KanbanDependencyMutationRequest) async throws -> KanbanDependencyMutationEnvelope {
        try await mutateLink(request, method: "DELETE")
    }

    private func patchTask<Body: Encodable>(_ id: String, board: String, body: Body) async throws -> KanbanCardMutationEnvelope {
        try await send("/tasks/\(segment(id))", method: "PATCH", query: boardQuery(board), body: body)
    }

    private func mutateLink(_ request: KanbanDependencyMutationRequest, method: String) async throws -> KanbanDependencyMutationEnvelope {
        let query = method == "DELETE"
            ? boardQuery(request.board) + [.init(name: "parent_id", value: request.prerequisiteID), .init(name: "child_id", value: request.dependentID)]
            : boardQuery(request.board)
        let acknowledgement: DirectOK
        if method == "DELETE" {
            acknowledgement = try await send("/links", method: method, query: query)
        } else {
            acknowledgement = try await send("/links", method: method, query: query,
                body: DirectLinkBody(parentID: request.prerequisiteID, childID: request.dependentID))
        }
        let bytes = try JSONSerialization.data(withJSONObject: [
            "ok": acknowledgement.ok == true,
            "parent_id": request.prerequisiteID,
            "child_id": request.dependentID
        ])
        return try await apiClient.decode(KanbanDependencyMutationEnvelope.self, from: bytes)
    }

    private func get<Response: Decodable>(_ suffix: String, query: [URLQueryItem] = [], preflight: Bool = true) async throws -> Response {
        try await send(suffix, method: "GET", query: query, preflight: preflight)
    }
    private func send<Response: Decodable>(_ suffix: String, method: String,
        query: [URLQueryItem] = [], preflight: Bool = true) async throws -> Response {
        do {
            let data = try await apiClient.sendDirectData(path: path(suffix, query: query), method: method,
                classifyStructuredAuthExpiry: true)
            return try await apiClient.decode(Response.self, from: adaptStockResponse(in: data, suffix: suffix))
        } catch let error as DirectHermesRequestError {
            if !preflight, case .http(statusCode: 404, reason: _) = error { throw error }
            guard preflight, case .http(statusCode: 404, reason: _) = error else {
                throw retainedAPIError(error)
            }
            _ = try await kanbanConfiguration()
            throw retainedAPIError(error) // Plugin exists: preserve the original resource 404.
        }
    }
    private func send<Response: Decodable, Body: Encodable>(_ suffix: String, method: String,
        query: [URLQueryItem] = [], body: Body) async throws -> Response {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        do {
            let data = try await apiClient.sendDirectData(path: path(suffix, query: query), method: method,
                encodedBody: encoder.encode(body), classifyStructuredAuthExpiry: true)
            return try await apiClient.decode(Response.self, from: adaptStockResponse(in: data, suffix: suffix))
        } catch let error as DirectHermesRequestError {
            guard case .http(statusCode: 404, reason: _) = error else {
                throw retainedAPIError(error)
            }
            _ = try await kanbanConfiguration()
            throw retainedAPIError(error) // No mutation retry; config only distinguishes route absence.
        }
    }
    private func retainedAPIError(_ error: DirectHermesRequestError) -> APIError {
        switch error {
        case let .http(statusCode, reason):
            if statusCode == 401 || reason == .invalidCredentials || reason == .unauthorized {
                return .unauthorized
            }
            return .http(statusCode: statusCode, body: nil)
        }
    }
    private func path(_ suffix: String, query: [URLQueryItem]) -> String {
        var components = URLComponents(); components.percentEncodedPath = Self.root + suffix
        components.queryItems = query.isEmpty ? nil : query
        return components.string!
    }
    private func segment(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
    private func boardQuery(_ board: String) -> [URLQueryItem] { [.init(name: "board", value: board)] }
    private func normalized(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private func adaptStockResponse(in data: Data, suffix: String) -> Data {
        let aged = adaptTaskAges(in: data)
        guard ["/config", "/boards", "/board", "/stats"].contains(suffix),
              var object = (try? JSONSerialization.jsonObject(with: aged)) as? [String: Any]
        else { return aged }

        switch suffix {
        case "/config":
            if object["columns"] == nil { object["columns"] = Self.stockColumns }
            if object["read_only"] == nil { object["read_only"] = false }
        case "/boards", "/board":
            if object["read_only"] == nil { object["read_only"] = false }
        case "/stats":
            let byStatus = object["by_status"] as? [String: Any] ?? [:]
            object["total"] = byStatus.values.reduce(0) { $0 + (($1 as? NSNumber)?.intValue ?? 0) }
            if let nested = object["by_assignee"] as? [String: Any] {
                object["by_assignee"] = nested.mapValues { value in
                    guard let counts = value as? [String: Any] else { return 0 }
                    return counts.values.reduce(0) { $0 + (($1 as? NSNumber)?.intValue ?? 0) }
                }
            }
        default:
            break
        }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? aged
    }

    /// Stock task payloads nest age metrics under `age`; the retained mobile
    /// card model has one display age. Running cards use started age when it is
    /// available, while waiting cards use created age.
    private func adaptTaskAges(in data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return data }
        func adapt(_ value: Any) -> Any {
            if let values = value as? [Any] { return values.map(adapt) }
            guard var fields = value as? [String: Any] else { return value }
            for (key, child) in fields { fields[key] = adapt(child) }
            if fields["id"] != nil, let age = fields["age"] as? [String: Any] {
                let running = fields["status"] as? String == "running"
                fields["age_seconds"] = (running ? age["started_age_seconds"] : nil)
                    ?? age["created_age_seconds"]
            }
            return fields
        }
        return (try? JSONSerialization.data(withJSONObject: adapt(object))) ?? data
    }
}

private struct DirectOK: Decodable { let ok: Bool? }
private struct DirectCreateBoardBody: Encodable {
    let slug, name, description, icon, color: String
    init(_ r: KanbanCreateBoardRequest) {
        slug = r.slug; name = r.name; description = r.description; icon = r.icon; color = r.color
    }
}
private struct DirectEditBoardBody: Encodable {
    let name, description, icon, color: String
    init(_ r: KanbanEditBoardRequest) {
        name = r.name; description = r.description; icon = r.icon; color = r.color
    }
}
private struct DirectCommentBody: Encodable { let body: String }
private struct DirectLinkBody: Encodable { let parentID, childID: String }
private struct DirectTaskStatusBody: Encodable { let status: String; let blockReason: String? }
private struct DirectCreateTaskBody: Encodable {
    let title: String; let body, assignee, tenant: String?; let priority: Int
    let workspaceKind: String; let workspacePath: String?; let parents: [String]
    let triage: Bool; let idempotencyKey: String; let maxRuntimeSeconds: Int?; let skills: [String]?
    init(_ r: KanbanCreateCardRequest) {
        title = r.title; body = r.body; assignee = r.assignee; tenant = r.tenant; priority = r.priority ?? 0
        workspaceKind = r.workspaceKind; workspacePath = r.workspacePath
        parents = r.prerequisiteID.map { [$0] } ?? []; triage = r.status == "triage"
        idempotencyKey = r.idempotencyKey; maxRuntimeSeconds = r.maxRuntimeSeconds; skills = r.skills
    }
}
private struct DirectEditTaskBody: Encodable {
    let title, body: String; let priority: Int; let assignee: String; let status: String?
    init(_ r: KanbanEditCardRequest) {
        title = r.title; body = r.body; priority = r.priority; assignee = r.assignee ?? ""; status = r.status
    }
}
private struct DirectBulkTaskBody: Encodable {
    let ids: [String]; let status, assignee: String?; let priority: Int?; let archive: Bool
    init(_ r: KanbanBulkActionRequest) {
        ids = r.cardIDs
        switch r.action {
        case .changeStatus(let value): (status, assignee, priority, archive) = (value, nil, nil, false)
        case .assignProfile(let value): (status, assignee, priority, archive) = (nil, value ?? "", nil, false)
        case .setPriority(let value): (status, assignee, priority, archive) = (nil, nil, value, false)
        case .archiveCards: (status, assignee, priority, archive) = (nil, nil, nil, true)
        }
    }
}
