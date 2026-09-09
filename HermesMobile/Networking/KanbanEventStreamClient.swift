import Foundation

enum KanbanStreamFrame: Equatable, Sendable {
    case connected
    // Retained for lab/test compatibility. The stock WebSocket never emits it.
    case hello(cursor: Int, board: String)
    case events(events: [KanbanEvent], cursor: Int, frameID: Int?)
    case ignored
    case malformed
}

enum KanbanStreamFrameDecoder {
    static func decode(data: Data) -> KanbanStreamFrame {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(Events.self, from: data),
              let events = payload.events, let cursor = payload.cursor, cursor >= 0 else { return .malformed }
        return .events(events: events, cursor: cursor, frameID: nil)
    }

    private struct Events: Decodable { let events: [KanbanEvent]?; let cursor: Int? }

    // Legacy fixture decoder retained while the Kanban lab still models SSE.
    static func decode(eventType: String, data: String, frameID: String?) -> KanbanStreamFrame {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if eventType == "hello",
           let hello = try? decoder.decode(Hello.self, from: Data(data.utf8)),
           let cursor = hello.cursor, cursor >= 0,
           let board = hello.board?.trimmingCharacters(in: .whitespacesAndNewlines), !board.isEmpty {
            return .hello(cursor: cursor, board: board)
        }
        if eventType == "events" {
            guard case let .events(events, cursor, _) = decode(data: Data(data.utf8)),
                  frameID == nil || frameID.flatMap(Int.init) != nil else { return .malformed }
            return .events(events: events, cursor: cursor, frameID: frameID.flatMap(Int.init))
        }
        return .ignored
    }

    private struct Hello: Decodable { let cursor: Int?; let board: String? }
}

@MainActor
protocol KanbanEventStreamingClient: AnyObject {
    func start(url: URL, onFrame: @escaping @MainActor (KanbanStreamFrame) -> Void,
               onFailure: @escaping @MainActor () -> Void)
    func stop()
}

protocol KanbanWebSocket: AnyObject, Sendable {
    func resume()
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel()
}

@MainActor
final class KanbanEventStreamClient: KanbanEventStreamingClient {
    typealias TicketProvider = (URL) async throws -> String
    typealias SocketFactory = (URLRequest, @escaping @Sendable () -> Void) -> any KanbanWebSocket
    private let ticketProvider: TicketProvider
    private let socketFactory: SocketFactory
    private let customHeaderProvider: @Sendable () -> [CustomHeader]
    private var socket: (any KanbanWebSocket)?
    private var receiveTask: Task<Void, Never>?
    private var generation = 0

    init(urlSessionConfiguration: URLSessionConfiguration = .default,
         customHeaderProvider: @escaping @Sendable () -> [CustomHeader] = { CustomHeaderStore.shared.snapshot() },
         ticketProvider: TicketProvider? = nil, socketFactory: SocketFactory? = nil) {
        self.customHeaderProvider = customHeaderProvider
        self.ticketProvider = ticketProvider ?? { streamURL in
            guard let origin = Self.httpsOrigin(for: streamURL) else { throw KanbanStreamError.invalidURL }
            let response = try await APIClient(
                baseURL: origin,
                customHeaderProvider: customHeaderProvider
            ).directWSTicket()
            guard let ticket = response.ticket,
                  !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KanbanStreamError.invalidTicket
            }
            return ticket
        }
        self.socketFactory = socketFactory ?? { request, onOpen in
            URLSessionKanbanWebSocket(configuration: urlSessionConfiguration, request: request, onOpen: onOpen)
        }
    }

    func start(url: URL, onFrame: @escaping @MainActor (KanbanStreamFrame) -> Void,
               onFailure: @escaping @MainActor () -> Void) {
        stop()
        generation &+= 1
        let attempt = generation
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard Self.isValidStreamURL(url) else { throw KanbanStreamError.invalidURL }
                let ticket = try await ticketProvider(url)
                try Task.checkCancellation()
                guard generation == attempt,
                      let socketURL = Self.authenticatedSocketURL(from: url, ticket: ticket) else {
                    throw KanbanStreamError.invalidURL
                }
                var request = URLRequest(url: socketURL)
                request.allHTTPHeaderFields = customHeaderProvider().merged(under: [:])
                let newSocket = socketFactory(request) { [weak self] in
                    Task { @MainActor in
                        guard let self, self.generation == attempt, self.socket != nil else { return }
                        onFrame(.connected)
                    }
                }
                socket = newSocket
                newSocket.resume()
                while generation == attempt, !Task.isCancelled {
                    let message = try await newSocket.receive()
                    guard generation == attempt else { return }
                    switch message {
                    case .data(let data): onFrame(KanbanStreamFrameDecoder.decode(data: data))
                    case .string(let text): onFrame(KanbanStreamFrameDecoder.decode(data: Data(text.utf8)))
                    @unknown default: onFrame(.ignored)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == attempt else { return }
                socket?.cancel()
                socket = nil
                onFailure()
            }
        }
    }

    func stop() {
        generation &+= 1
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel()
        socket = nil
    }

    private static func httpsOrigin(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host != nil,
              components.user == nil, components.password == nil, components.fragment == nil else { return nil }
        components.path = ""
        components.query = nil
        return components.url
    }

    private static func authenticatedSocketURL(from url: URL, ticket: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false), isValidStreamURL(url),
              !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let items = components.queryItems ?? []
        components.scheme = "wss"
        components.queryItems = items + [URLQueryItem(name: "ticket", value: ticket)]
        return components.url
    }

    private static func isValidStreamURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.host != nil,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.path == "/api/plugins/kanban/events" else { return false }
        let items = components.queryItems ?? []
        let names = items.map(\.name)
        return items.allSatisfy { $0.name == "board" || $0.name == "since" }
            && names.filter { $0 == "board" }.count <= 1
            && names.filter { $0 == "since" }.count <= 1
    }
}

private enum KanbanStreamError: Error { case invalidURL, invalidTicket }

private final class URLSessionKanbanWebSocket: NSObject, KanbanWebSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let onOpen: @Sendable () -> Void
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!

    init(configuration: URLSessionConfiguration, request: URLRequest, onOpen: @escaping @Sendable () -> Void) {
        self.onOpen = onOpen
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: request)
    }

    func resume() { task.resume() }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func cancel() { task.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) { onOpen() }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
