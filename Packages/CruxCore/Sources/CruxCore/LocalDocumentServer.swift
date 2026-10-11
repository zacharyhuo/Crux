import Foundation
import Network

/// Where the running document server can be reached for this launch.
public struct DocumentServerEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let token: String
}

public protocol DocumentServer: Actor {
    func start() async throws -> DocumentServerEndpoint
    /// Begins stopping immediately. Retained for source compatibility with
    /// existing server implementations and callers.
    func stop()
    /// Stops and waits for listener and connection-handler teardown.
    func shutdownAndWait() async
    func update(roots: [DocumentRoot]) async
    func url(forDocset identifier: String, relativePath: String, fragment: String?) async -> URL?
}

public extension DocumentServer {
    func shutdownAndWait() async {
        stop()
    }
}

public enum DocumentServerError: Error, Equatable, LocalizedError, Sendable {
    case notRunning
    case listenerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:
            "The local document server is not running."
        case let .listenerFailed(message):
            "The local document server could not start: \(message)"
        }
    }
}

/// Serves docset files over HTTP on `127.0.0.1` for the lifetime of one launch.
///
/// Binding to loopback keeps the service unreachable from other hosts, and the
/// per-run token in every path keeps other local processes from guessing valid
/// URLs. All request policy lives in `DocumentRouter`; this actor only owns the
/// socket lifecycle and byte framing.
public actor LocalDocumentServer: DocumentServer {
    private static let host = "127.0.0.1"
    private static let fileChunkSize = 256 * 1024

    private var router: DocumentRouter
    private let connectionIdleTimeout: Duration
    private let maximumRequestsPerConnection: Int
    private let listenerConnectionLimit: Int
    private var endpoint: DocumentServerEndpoint?
    private var listenerTask: Task<Void, Never>?
    private var startContinuation: CheckedContinuation<UInt16, any Error>?
    private var idleTimeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var isStopping = false

    public init(
        token: String = LocalDocumentServer.makeToken(),
        roots: [DocumentRoot] = [],
        connectionIdleTimeout: Duration = .seconds(15),
        maximumRequestsPerConnection: Int = 256,
        listenerConnectionLimit: Int = 64
    ) {
        router = DocumentRouter(token: token, roots: roots)
        self.connectionIdleTimeout = max(.milliseconds(1), connectionIdleTimeout)
        self.maximumRequestsPerConnection = max(1, maximumRequestsPerConnection)
        self.listenerConnectionLimit = max(1, listenerConnectionLimit)
    }

    /// 192 bits of randomness, encoded so it is safe in a URL path component.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public func start() async throws -> DocumentServerEndpoint {
        if let endpoint { return endpoint }
        isStopping = false

        // Binding the listener to the loopback address is what makes the service
        // unreachable from other hosts; no firewall or interface rule is relied on.
        let listener = try NetworkListener(
            using: NWParametersBuilder { TCP() }
                .localEndpoint(.hostPort(host: .init(Self.host), port: .any))
        )
        listener.newConnectionLimit = listenerConnectionLimit

        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            startContinuation = continuation
            listenerTask = Task { [weak self] in
                do {
                    try await listener
                        .onStateUpdate { [weak self] listener, state in
                            Task { await self?.handle(state: state, of: listener) }
                        }
                        .run { [weak self] connection in
                            await self?.serve(connection: connection)
                        }
                    await self?.failStart(with: CancellationError())
                } catch {
                    await self?.failStart(with: error)
                }
            }
        }

        let endpoint = DocumentServerEndpoint(host: Self.host, port: port, token: router.token)
        self.endpoint = endpoint
        return endpoint
    }

    public func stop() {
        let (task, timeouts) = beginStopping()
        timeouts.forEach { $0.cancel() }
        task?.cancel()
    }

    public func shutdownAndWait() async {
        let (task, timeouts) = beginStopping()
        timeouts.forEach { $0.cancel() }
        for timeout in timeouts {
            await timeout.value
        }
        task?.cancel()
        // `NetworkListener.run` owns its accepted connection handlers. Waiting
        // for it prevents a handler from touching an invalidated connection
        // after the server (or a test fixture) has already been torn down.
        await task?.value
    }

    private func beginStopping() -> (Task<Void, Never>?, [Task<Void, Never>]) {
        let task = listenerTask
        listenerTask = nil
        endpoint = nil
        isStopping = true
        let timeouts = Array(idleTimeoutTasks.values)
        idleTimeoutTasks.removeAll()
        return (task, timeouts)
    }

    public func update(roots: [DocumentRoot]) {
        router = DocumentRouter(token: router.token, roots: roots)
    }

    public func url(forDocset identifier: String, relativePath: String, fragment: String?) -> URL? {
        guard let endpoint else { return nil }
        return router.url(
            host: endpoint.host,
            port: endpoint.port,
            docsetIdentifier: identifier,
            relativePath: relativePath,
            fragment: fragment
        )
    }

    public var currentEndpoint: DocumentServerEndpoint? { endpoint }

    // MARK: - Listener lifecycle

    private func handle(state: NetworkListener<TCP>.State, of listener: NetworkListener<TCP>) {
        switch state {
        case .ready:
            guard let continuation = startContinuation, let port = listener.port else { return }
            startContinuation = nil
            continuation.resume(returning: port.rawValue)
        case let .failed(error):
            failStart(with: error)
        default:
            break
        }
    }

    private func failStart(with error: any Error) {
        guard let continuation = startContinuation else { return }
        startContinuation = nil
        continuation.resume(
            throwing: DocumentServerError.listenerFailed(error.localizedDescription)
        )
    }

    // MARK: - Connection handling

    private func serve(connection: NetworkConnection<TCP>) async {
        var buffer = Data()
        for _ in 0..<maximumRequestsPerConnection {
            let head: HTTPRequestHead
            do {
                head = try await readHead(from: connection, buffer: &buffer)
            } catch ConnectionLifecycleError.idleTimeout {
                // The timeout task already sent TCP end-of-stream. Sending it a
                // second time is invalid in Network.framework.
                return
            } catch {
                // A failed receive means Network.framework has already ended
                // or invalidated this connection. A second send is not merely
                // redundant: the macOS 26 wrapper traps when its nw handle has
                // already been cleared.
                return
            }

            let response = router.response(for: head)
            do {
                try await send(response, for: head, over: connection)
            } catch {
                // The failed send is the terminal event for this stream.
                return
            }
            guard head.wantsKeepAlive, response.status != .badRequest else {
                await finish(connection)
                return
            }
        }

        // A connection that reaches the request budget is closed even when its
        // final request asked for keep-alive. This bounds per-client resource use.
        await finish(connection)
    }

    private func readHead(
        from connection: NetworkConnection<TCP>,
        buffer: inout Data
    ) async throws -> HTTPRequestHead {
        while true {
            do {
                let (head, consumed) = try HTTPRequestParser.parse(buffer)
                buffer.removeFirst(consumed)
                return head
            } catch HTTPRequestParseError.incomplete {
                let content = try await receiveWithIdleTimeout(from: connection)
                guard !content.isEmpty else { throw HTTPRequestParseError.malformed }
                buffer.append(content)
            }
        }
    }

    /// Races an inbound read against the idle budget. The listener otherwise
    /// keeps a WebKit keep-alive socket forever, eventually exhausting the
    /// finite connection slots even though no useful work remains on it.
    private func receiveWithIdleTimeout(from connection: NetworkConnection<TCP>) async throws -> Data {
        guard !isStopping else { throw CancellationError() }
        let race = IdleReadRace()
        let timeoutID = UUID()
        let timeoutTask = Task { [connectionIdleTimeout] in
            do {
                try await Task.sleep(for: connectionIdleTimeout)
                guard await race.claimTimeout() else { return }
                try? await connection.send(Data(), endOfStream: true)
            } catch is CancellationError {
                // The receive won and cancelled this harmless timer.
            } catch {
                // Closing an already failed client is best-effort.
            }
        }
        idleTimeoutTasks[timeoutID] = timeoutTask
        defer {
            timeoutTask.cancel()
            idleTimeoutTasks[timeoutID] = nil
        }

        let content = try await connection.receive(atLeast: 1, atMost: 32 * 1_024).content
        guard await race.claimReceive() else {
            throw ConnectionLifecycleError.idleTimeout
        }
        return content
    }

    /// Sends TCP end-of-stream for normal server-initiated closes. Failed or
    /// cancelled streams are already invalid and must not receive a second send.
    private func finish(_ connection: NetworkConnection<TCP>) async {
        try? await connection.send(Data(), endOfStream: true)
    }

    private func send(
        _ response: HTTPResponseHead,
        for head: HTTPRequestHead,
        over connection: NetworkConnection<TCP>
    ) async throws {
        var headers = response.headers
        headers["Connection"] = head.wantsKeepAlive ? "keep-alive" : "close"
        let framed = HTTPResponseHead(status: response.status, headers: headers, body: response.body)
        try await connection.send(framed.serializedHead())

        guard head.method != "HEAD" else { return }
        switch response.body {
        case .empty:
            break
        case let .text(text):
            try await connection.send(Data(text.utf8))
        case let .file(url, range):
            try await sendFile(at: url, range: range, over: connection)
        }
    }

    /// Streams a file range so a large document never has to be fully resident.
    private func sendFile(
        at url: URL,
        range: ClosedRange<Int>,
        over connection: NetworkConnection<TCP>
    ) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))

        var remaining = range.count
        while remaining > 0 {
            try Task.checkCancellation()
            let chunkSize = min(remaining, Self.fileChunkSize)
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { return }
            try await connection.send(chunk)
            remaining -= chunk.count
        }
    }
}

private enum ConnectionLifecycleError: Error {
    case idleTimeout
}

/// Arbitrates the receive and timer without cancelling an in-flight Network
/// receive. Network.framework treats cancellation of that async receive as a
/// programmer error in some teardown races, so the timeout closes the stream
/// and lets the read complete normally instead.
private actor IdleReadRace {
    private var hasWinner = false

    func claimReceive() -> Bool { claim() }
    func claimTimeout() -> Bool { claim() }

    private func claim() -> Bool {
        guard !hasWinner else { return false }
        hasWinner = true
        return true
    }
}
