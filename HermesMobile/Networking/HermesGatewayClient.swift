import Foundation

/// A decoded TUI Gateway event. The gateway may add fields to `params` or the
/// payload; callers should use only the fields they understand.
struct HermesGatewayEvent: Equatable, Sendable {
    let method: String
    let type: String
    let sessionID: String?
    let sequence: Int?
    let payload: JSONValue?
    let params: JSONValue?
}

/// Errors surfaced by the minimal direct-Hermes JSON-RPC transport.
enum HermesGatewayError: Error, Equatable, Sendable {
    case invalidGatewayURL
    case notConnected
    case notReady
    case closed
    case cancelled(method: String, requestID: String)
    case timeout(method: String, requestID: String)
    case transport(String)
    case invalidMessage
    case server(
        code: Int,
        message: String,
        data: JSONValue?,
        method: String,
        requestID: String,
        server: String?
    )
}

/// The small seam used by tests. Production uses `URLSessionWebSocketTask`.
protocol HermesGatewayWebSocket: AnyObject, Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

private final class URLSessionHermesGatewayWebSocket: HermesGatewayWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func resume() {
        task.resume()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }
}

private final class URLSessionHermesGatewayWebSocketFactory: @unchecked Sendable {
    private let session: URLSession

    init(configuration: URLSessionConfiguration) {
        session = URLSession(configuration: configuration)
    }

    func make(request: URLRequest) -> HermesGatewayWebSocket {
        URLSessionHermesGatewayWebSocket(task: session.webSocketTask(with: request))
    }
}

private struct HermesGatewayRPCError: Codable {
    let code: Int?
    let message: String?
    let data: JSONValue?
}

private struct HermesGatewayEnvelope: Codable {
    let jsonrpc: String?
    let id: JSONValue?
    let method: String?
    let params: JSONValue?
    let result: JSONValue?
    let error: HermesGatewayRPCError?
    let resultPresent: Bool
    let errorPresent: Bool

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, method, params, result, error
    }

    init(
        jsonrpc: String?,
        id: JSONValue?,
        method: String?,
        params: JSONValue?,
        result: JSONValue?,
        error: HermesGatewayRPCError?,
        resultPresent: Bool? = nil,
        errorPresent: Bool? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
        self.result = result
        self.error = error
        self.resultPresent = resultPresent ?? (result != nil)
        self.errorPresent = errorPresent ?? (error != nil)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jsonrpc = try container.decodeIfPresent(String.self, forKey: .jsonrpc)
        id = try container.decodeIfPresent(JSONValue.self, forKey: .id)
        method = try container.decodeIfPresent(String.self, forKey: .method)
        params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
        result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try container.decodeIfPresent(HermesGatewayRPCError.self, forKey: .error)
        resultPresent = container.contains(.result)
        errorPresent = container.contains(.error)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(jsonrpc, forKey: .jsonrpc)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(error, forKey: .error)
    }
}

// Accessed only within HermesGatewayClient's actor isolation.
private final class HermesPendingRequest {
    let method: String
    let continuation: CheckedContinuation<JSONValue?, Error>
    var timeoutTask: Task<Void, Never>?

    init(method: String, continuation: CheckedContinuation<JSONValue?, Error>) {
        self.method = method
        self.continuation = continuation
    }
}

/// One JSON-RPC WebSocket for the active Hermes server.
///
/// The client deliberately contains transport primitives only. Session
/// identity, prompt replay, and recovery ownership belong to higher layers.
actor HermesGatewayClient {
    typealias TicketProvider = @Sendable () async throws -> String
    typealias EventHandler = @Sendable (HermesGatewayEvent) -> Void

    private let gatewayURL: URL
    private let ticketProvider: TicketProvider
    private let socketFactory: @Sendable (URLRequest) -> HermesGatewayWebSocket
    private let requestTimeout: Duration
    private let eventHandler: EventHandler?
    private let serverIdentity: String?

    private var socket: HermesGatewayWebSocket?
    private var receiveTask: Task<Void, Never>?
    private var generation = 0
    private var nextRequestID = 0
    private var pending: [String: HermesPendingRequest] = [:]
    private var readyGeneration: Int?
    private var readyWaiter: (generation: Int, continuation: CheckedContinuation<Void, Error>)?
    private var readyTimeoutTask: Task<Void, Never>?

    init(
        gatewayURL: URL,
        ticketProvider: @escaping TicketProvider,
        requestTimeout: Duration = .seconds(15),
        eventHandler: EventHandler? = nil,
        urlSessionConfiguration: URLSessionConfiguration = .default,
        socketFactory: (@Sendable (URLRequest) -> HermesGatewayWebSocket)? = nil
    ) {
        self.gatewayURL = gatewayURL
        self.ticketProvider = ticketProvider
        self.requestTimeout = requestTimeout
        self.eventHandler = eventHandler
        serverIdentity = gatewayURL.host
        if let socketFactory {
            self.socketFactory = socketFactory
        } else {
            let factory = URLSessionHermesGatewayWebSocketFactory(configuration: urlSessionConfiguration)
            self.socketFactory = { request in factory.make(request: request) }
        }
    }

    /// Mints a fresh one-use ticket and waits for `gateway.ready`.
    func connect() async throws {
        closeState(error: HermesGatewayError.closed)
        let ticketGeneration = generation
        let ticket = try await ticketProvider()
        try Task.checkCancellation()
        guard generation == ticketGeneration else {
            throw HermesGatewayError.closed
        }
        guard let requestURL = Self.ticketURL(base: gatewayURL, ticket: ticket) else {
            throw HermesGatewayError.invalidGatewayURL
        }

        generation &+= 1
        let connectionGeneration = generation
        readyGeneration = nil
        let request = URLRequest(url: requestURL)
        let newSocket = socketFactory(request)
        socket = newSocket
        newSocket.resume()
        receiveTask = Task { [weak self, newSocket] in
            await self?.receiveLoop(socket: newSocket, generation: connectionGeneration)
        }

        do {
            try await waitForReady(generation: connectionGeneration)
        } catch {
            if generation == connectionGeneration {
                closeState(error: error)
            }
            throw error
        }
    }

    /// Closes the socket and fails all in-flight requests.
    func close() {
        closeState(error: HermesGatewayError.closed)
    }

    /// Sends a JSON-RPC request and returns its arbitrary JSON result.
    /// Cancellation/timeout stops local waiting, not an already-submitted server
    /// operation. Callers must reconcile ambiguous sends, never blindly retry.
    func request(method: String, params: JSONValue? = nil, timeout: Duration? = nil) async throws -> JSONValue? {
        guard let socket else {
            throw HermesGatewayError.notConnected
        }
        guard readyGeneration == generation else {
            throw HermesGatewayError.notReady
        }
        try Task.checkCancellation()

        nextRequestID += 1
        let requestID = String(nextRequestID)
        let numericID = JSONValue.number(Double(nextRequestID))
        let envelope = HermesGatewayEnvelope(
            jsonrpc: "2.0",
            id: numericID,
            method: method,
            params: params,
            result: nil,
            error: nil
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(envelope)
        } catch {
            throw HermesGatewayError.transport("request encoding failed")
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let pendingRequest = HermesPendingRequest(method: method, continuation: continuation)
                pending[requestID] = pendingRequest
                if Task.isCancelled {
                    pending.removeValue(forKey: requestID)
                    continuation.resume(throwing: HermesGatewayError.cancelled(method: method, requestID: requestID))
                    return
                }

                let duration = timeout ?? requestTimeout
                pendingRequest.timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: duration)
                        await self?.timeOut(requestID: requestID)
                    } catch {
                        // A response or close cancels this task.
                    }
                }
                Task { [weak self, socket] in
                    await self?.sendIfPending(socket: socket, requestID: requestID, data: data)
                }
            }
        }, onCancel: { [weak self] in
            Task {
                await self?.cancelPending(requestID: requestID)
            }
        })
    }

    func ping(timeout: Duration? = nil) async throws -> JSONValue? {
        try await request(method: "gateway.ping", timeout: timeout)
    }

    private func receiveLoop(socket: HermesGatewayWebSocket, generation: Int) async {
        while self.generation == generation, self.socket === socket {
            do {
                let message = try await socket.receive()
                guard self.generation == generation, self.socket === socket else { return }
                guard let data = Self.data(from: message),
                      let envelope = try? JSONDecoder().decode(HermesGatewayEnvelope.self, from: data)
                else {
                    // A malformed/unknown frame must not tear down the socket.
                    continue
                }
                handle(envelope, generation: generation)
            } catch {
                guard self.generation == generation, self.socket === socket else { return }
                closeState(error: HermesGatewayError.transport("WebSocket receive failed"))
                return
            }
        }
    }

    private func handle(_ envelope: HermesGatewayEnvelope, generation: Int) {
        if envelope.method == "event",
           let params = envelope.params,
           let eventType = params.objectValue?["type"]?.stringValue {
            let sessionID = params.objectValue?["session_id"]?.stringValue
                ?? params.objectValue?["sessionId"]?.stringValue
            let sequence = params.objectValue?["seq"]?.intValue
            let payload = params.objectValue?["payload"]
            let event = HermesGatewayEvent(
                method: envelope.method ?? "event",
                type: eventType,
                sessionID: sessionID,
                sequence: sequence,
                payload: payload,
                params: params
            )
            eventHandler?(event)
            if eventType == "gateway.ready" {
                readyGeneration = generation
                readyTimeoutTask?.cancel()
                readyTimeoutTask = nil
                if let waiter = readyWaiter, waiter.generation == generation {
                    readyWaiter = nil
                    waiter.continuation.resume()
                }
            }
            return
        }

        guard let requestID = Self.idKey(envelope.id), let pendingRequest = pending.removeValue(forKey: requestID) else {
            return
        }
        pendingRequest.timeoutTask?.cancel()
        if let rpcError = envelope.error {
            pendingRequest.continuation.resume(throwing: HermesGatewayError.server(
                code: rpcError.code ?? 0,
                message: rpcError.message ?? "Hermes gateway request failed",
                data: rpcError.data,
                method: pendingRequest.method,
                requestID: requestID,
                server: serverIdentity
            ))
        } else if envelope.errorPresent {
            pendingRequest.continuation.resume(throwing: HermesGatewayError.invalidMessage)
        } else if envelope.resultPresent {
            pendingRequest.continuation.resume(returning: envelope.result)
        } else {
            pendingRequest.continuation.resume(throwing: HermesGatewayError.invalidMessage)
        }
    }

    private func waitForReady(generation: Int) async throws {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard self.generation == generation, self.socket != nil else {
                    continuation.resume(throwing: HermesGatewayError.closed)
                    return
                }
                if readyGeneration == generation {
                    continuation.resume()
                    return
                }
                if Task.isCancelled {
                    continuation.resume(throwing: HermesGatewayError.cancelled(method: "gateway.ready", requestID: "connection"))
                    return
                }
                readyWaiter = (generation, continuation)
                readyTimeoutTask?.cancel()
                readyTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: self?.requestTimeout ?? .seconds(15))
                        await self?.readyTimedOut(generation: generation)
                    } catch {
                        // Ready, close or cancellation cancels this timer.
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { await self?.cancelReady(generation: generation) }
        })
    }

    private func readyTimedOut(generation: Int) {
        guard let waiter = readyWaiter, waiter.generation == generation else { return }
        readyTimeoutTask = nil
        readyWaiter = nil
        waiter.continuation.resume(throwing: HermesGatewayError.timeout(method: "gateway.ready", requestID: "connection"))
    }

    private func cancelReady(generation: Int) {
        guard let waiter = readyWaiter, waiter.generation == generation else { return }
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        readyWaiter = nil
        waiter.continuation.resume(throwing: HermesGatewayError.cancelled(method: "gateway.ready", requestID: "connection"))
    }

    private func sendIfPending(socket: HermesGatewayWebSocket, requestID: String, data: Data) async {
        guard self.socket === socket, pending[requestID] != nil else { return }
        do {
            // Pinned Hermes uses receive_text(); binary JSON frames disconnect.
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            sendFailed(requestID: requestID)
        }
    }

    private func sendFailed(requestID: String) {
        guard let pendingRequest = pending.removeValue(forKey: requestID) else { return }
        pendingRequest.timeoutTask?.cancel()
        pendingRequest.continuation.resume(throwing: HermesGatewayError.transport("WebSocket send failed"))
    }

    private func timeOut(requestID: String) {
        guard let pendingRequest = pending.removeValue(forKey: requestID) else { return }
        pendingRequest.continuation.resume(throwing: HermesGatewayError.timeout(method: pendingRequest.method, requestID: requestID))
    }

    private func cancelPending(requestID: String) {
        guard let pendingRequest = pending.removeValue(forKey: requestID) else { return }
        pendingRequest.timeoutTask?.cancel()
        pendingRequest.continuation.resume(throwing: HermesGatewayError.cancelled(method: pendingRequest.method, requestID: requestID))
    }

    private func closeState(error: Error) {
        generation &+= 1
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        readyGeneration = nil
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        if let waiter = readyWaiter {
            readyWaiter = nil
            waiter.continuation.resume(throwing: error)
        }
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask?.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private static func ticketURL(base: URL, ticket: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.path == "/api/ws",
              !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        guard !queryItems.contains(where: { item in
            let name = item.name.lowercased()
            return name == "token" || name == "access_token" || name == "ticket"
        }) else {
            return nil
        }
        queryItems.append(URLQueryItem(name: "ticket", value: ticket))
        components.queryItems = queryItems
        return components.url
    }

    private static func data(from message: URLSessionWebSocketTask.Message) -> Data? {
        switch message {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: return nil
        }
    }

    private static func idKey(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let value): return value
        case .number(let value):
            guard let integer = Int(exactly: value) else { return nil }
            return String(integer)
        default: return nil
        }
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(exactly: value) }
        return nil
    }
}
