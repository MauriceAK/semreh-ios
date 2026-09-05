import Foundation
import Observation

/// A binding is deliberately not Codable: runtime IDs never belong in disk state.
struct GatewaySessionBinding: Equatable, Sendable {
    let storedID: String
    let runtimeID: String
    let profile: String

    static func resolve(_ result: JSONValue?, requestedID: String? = nil, profile: String) throws -> Self {
        guard case .object(let fields) = result,
              let runtimeID = fields["session_id"]?.gatewayString else {
            throw DirectSessionError.invalidBinding
        }
        let aliases = ["stored_session_id", "session_key", "resumed"].compactMap { fields[$0]?.gatewayString }
        guard Set(aliases).count <= 1 else { throw DirectSessionError.conflictingDurableIDs }
        guard let storedID = aliases.first ?? requestedID, !storedID.isEmpty else {
            throw DirectSessionError.invalidBinding
        }
        return Self(storedID: storedID, runtimeID: runtimeID, profile: profile)
    }
}

enum DirectSessionError: Error, Equatable {
    case invalidBinding
    case conflictingDurableIDs
    case stopped
    case staleOperation
    case invalidOrigin
    case eventBufferOverflow
    case ambiguousPrompt
    case invalidResponse
    case stopUnconfirmed
    case draftCleanupUnconfirmed
}

protocol HermesGatewayTransport: Sendable {
    func connect() async throws
    func close() async
    func connectionIdentifier() async -> Int?
    func request(method: String, params: JSONValue?, timeout: Duration?) async throws -> JSONValue?
}

extension HermesGatewayClient: HermesGatewayTransport {}

/// One owner per active server. Conversations share this connection and register
/// resume/reconcile hooks; neither conversations nor transport run reconnect loops.
@MainActor
@Observable
final class HermesServerRuntime {
    enum State: Equatable { case disconnected, connecting, ready, stopped }
    typealias EventSink = @MainActor (HermesGatewayEvent) -> Void
    typealias Recovery = @MainActor (any HermesGatewayTransport) async throws -> Void

    let origin: URL
    private(set) var state: State = .disconnected
    private(set) var connectionGeneration = 0
    @ObservationIgnored private let transport: any HermesGatewayTransport
    @ObservationIgnored private var connectTask: Task<Void, Error>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var observers: [UUID: (event: EventSink, recover: Recovery, ready: @MainActor () -> Void)] = [:]
    @ObservationIgnored private var pendingEvents: [HermesGatewayEvent] = []
    @ObservationIgnored private var bufferOverflowed = false
    @ObservationIgnored private var acceptedTransportGeneration: Int?
    @ObservationIgnored private var bindingBarrierDepth = 0
    private static let maximumBufferedEvents = 1024

    init(origin: URL, factory: (@Sendable @escaping (HermesGatewayEvent) -> Void) -> any HermesGatewayTransport) throws {
        guard origin.scheme == "https", origin.host?.isEmpty == false,
              origin.port == nil || origin.port == 443, origin.user == nil,
              origin.password == nil, origin.query == nil, origin.fragment == nil,
              origin.path.isEmpty || origin.path == "/" else { throw DirectSessionError.invalidOrigin }
        self.origin = origin
        // One ordered consumer, not an independent Task per incoming frame.
        let (stream, continuation) = AsyncStream<HermesGatewayEvent>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        transport = factory {
            // Overflow fails closed rather than silently dropping control events.
            if case .dropped = continuation.yield($0) { continuation.finish() }
        }
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                self?.receive(event)
            }
            if !Task.isCancelled { await self?.stop() }
        }
    }

    convenience init(origin: URL, client: APIClient) throws {
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)
        components?.scheme = "wss"
        components?.path = "/api/ws"
        guard let gatewayURL = components?.url else { throw DirectSessionError.invalidOrigin }
        try self.init(origin: origin) { sink in
            HermesGatewayClient(gatewayURL: gatewayURL, ticketProvider: {
                guard let ticket = try await client.directWSTicket().ticket, !ticket.isEmpty else {
                    throw DirectSessionError.invalidResponse
                }
                return ticket
            }, eventHandler: sink)
        }
    }

    deinit { eventTask?.cancel(); connectTask?.cancel(); recoveryTask?.cancel() }

    func observe(event: @escaping EventSink, recover: @escaping Recovery, ready: @escaping @MainActor () -> Void = {}) -> UUID {
        let id = UUID()
        observers[id] = (event, recover, ready)
        return id
    }

    func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }

    /// Deduplicates simultaneous foreground/send/connect requests. During rebind,
    /// session events wait until every registered recovery hook has reconciled.
    func connect() async throws {
        try await startConnection(forceReconnect: false)
    }

    func reconnect() async throws {
        try await startConnection(forceReconnect: true)
    }

    private func startConnection(forceReconnect: Bool) async throws {
        guard state != .stopped else { throw DirectSessionError.stopped }
        if let connectTask { return try await connectTask.value }
        if state == .ready, !forceReconnect { return }
        state = .connecting
        connectionGeneration &+= 1
        let generation = connectionGeneration
        pendingEvents.removeAll()
        bufferOverflowed = false
        acceptedTransportGeneration = nil
        bindingBarrierDepth = 0
        let task = Task { [weak self, transport] in
            // Close and connect are one deduplicated operation. No caller can
            // open a replacement socket in an await-close gap.
            if forceReconnect { await transport.close() }
            try Task.checkCancellation()
            try await transport.connect()
            guard let self else { throw DirectSessionError.stopped }
            try self.checkGeneration(generation)
            guard let transportGeneration = await transport.connectionIdentifier() else { throw HermesGatewayError.closed }
            try self.checkGeneration(generation)
            self.acceptedTransportGeneration = transportGeneration
            var recovered = Set<UUID>()
            // Include observers added while another recovery is suspended;
            // never invoke a removed observer's captured closure.
            while let id = self.observers.keys.first(where: { !recovered.contains($0) }) {
                recovered.insert(id)
                try self.checkGeneration(generation)
                if let recover = self.observers[id]?.recover { try await recover(transport) }
            }
            guard await transport.connectionIdentifier() == transportGeneration else { throw HermesGatewayError.closed }
            try self.checkGeneration(generation)
            guard !self.bufferOverflowed else { throw DirectSessionError.eventBufferOverflow }
            guard !self.pendingEvents.contains(where: {
                $0.method == "local" && $0.type == "transport.closed" && $0.connectionGeneration == transportGeneration
            }) else { throw HermesGatewayError.closed }
            self.state = .ready
            let buffered = self.pendingEvents
            self.pendingEvents.removeAll()
            for event in buffered { self.deliver(event) }
            // Read-only consumers can invalidate once the connection-wide
            // recovery barrier is complete; they need no polling/recovery loop.
            for id in Array(self.observers.keys) {
                try self.checkGeneration(generation)
                self.observers[id]?.ready()
            }
        }
        connectTask = task
        do {
            try await task.value
            try checkGeneration(generation)
            connectTask = nil
        } catch {
            if generation == connectionGeneration {
                pendingEvents.removeAll()
                await transport.close()
                // Keep the shared task installed until teardown has finished.
                if generation == connectionGeneration {
                    connectTask = nil
                    state = .disconnected
                }
            }
            throw error
        }
    }

    func stop() async {
        connectionGeneration &+= 1
        state = .stopped
        connectTask?.cancel()
        recoveryTask?.cancel()
        connectTask = nil
        eventTask?.cancel()
        pendingEvents.removeAll()
        bindingBarrierDepth = 0
        observers.removeAll()
        await transport.close()
    }

    /// Attachment on an already-ready socket also needs an ordered barrier:
    /// resume can emit events before its response supplies the runtime ID.
    /// Concurrent attachments share this one connection-wide queue.
    func withSessionEventsPaused(_ operation: @MainActor () async throws -> Void) async throws {
        try await connect()
        let generation = connectionGeneration
        bindingBarrierDepth += 1
        defer {
            if generation == connectionGeneration {
                bindingBarrierDepth -= 1
                if bindingBarrierDepth == 0, state == .ready, !bufferOverflowed {
                    let buffered = pendingEvents
                    pendingEvents.removeAll()
                    for event in buffered { deliver(event) }
                }
            }
        }
        do {
            try await operation()
            try checkGeneration(generation)
            guard !bufferOverflowed else { throw DirectSessionError.eventBufferOverflow }
        } catch {
            if bufferOverflowed { await stop() }
            throw error
        }
    }

    func request(_ method: String, params: [String: JSONValue], timeout: Duration? = nil) async throws -> JSONValue? {
        try await request(method, parameters: { params }, timeout: timeout)
    }

    /// Session-scoped callers resolve runtime IDs only after any shared reconnect
    /// has rebound them. Precomputed runtime IDs can belong to a dead socket.
    func request(_ method: String, parameters: @MainActor () throws -> [String: JSONValue], timeout: Duration? = nil) async throws -> JSONValue? {
        try await connect()
        let generation = connectionGeneration
        let params = try parameters()
        do {
            let result = try await transport.request(method: method, params: .object(params), timeout: timeout)
            try checkGeneration(generation)
            return result
        } catch {
            if generation == connectionGeneration, let failure = error as? HermesGatewayError {
                switch failure {
                case .notConnected, .notReady, .closed, .transport:
                    state = .disconnected
                default: break
                }
            }
            // In particular, never retry prompt.submit after a lost acknowledgement.
            throw error
        }
    }

    private func checkGeneration(_ generation: Int) throws {
        guard generation == connectionGeneration, state != .stopped else { throw DirectSessionError.staleOperation }
        try Task.checkCancellation()
    }

    private func receive(_ event: HermesGatewayEvent) {
        guard state != .stopped else { return }
        if event.method == "local", event.type == "transport.closed",
           event.connectionGeneration == acceptedTransportGeneration,
           state == .ready || state == .disconnected {
            state = .disconnected
            deliver(event)
            recoveryTask?.cancel()
            recoveryTask = Task { [weak self] in
                for _ in 0..<3 {
                    do {
                        try await Task.sleep(for: .seconds(1))
                        guard let self, !Task.isCancelled, self.state != .stopped else { return }
                        try await self.connect()
                        return
                    } catch is CancellationError { return }
                    catch { /* Leave disconnected on exhaustion; foreground can retry. */ }
                }
            }
            return
        }
        if state == .connecting || bindingBarrierDepth > 0 {
            if pendingEvents.count < Self.maximumBufferedEvents { pendingEvents.append(event) }
            else { bufferOverflowed = true }
        } else if state == .ready { deliver(event) }
    }

    private func deliver(_ event: HermesGatewayEvent) {
        guard event.connectionGeneration == acceptedTransportGeneration else { return }
        for sink in Array(observers.values.map(\.event)) { sink(event) }
    }
}

extension JSONValue {
    var gatewayString: String? {
        guard case .string(let value) = self else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    var gatewayFields: [String: JSONValue] {
        if case .object(let fields) = self { return fields }
        return [:]
    }
}
