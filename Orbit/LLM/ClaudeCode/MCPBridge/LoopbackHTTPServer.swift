import Foundation
import Network
import os

/// A small HTTP/1.1 server bound to 127.0.0.1 on a random port, serving the
/// MCP bridge to the Claude Code process. Persistent connections, one request
/// at a time per connection, strict size limits, a deadline for incomplete
/// requests, and handlers are cancelled when their client disconnects.
final class LoopbackHTTPServer: Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    struct Configuration: Sendable, Hashable {
        var limits = HTTPRequestParser.Limits()
        var maxConnections = 32
        /// A request that started arriving must be complete within this time.
        var requestTimeout: Duration = .seconds(30)
    }

    enum Failure: Error, Sendable {
        case listenerFailed
        case stopped
    }

    private struct State: Sendable {
        var listener: NWListener?
        var connections: [UUID: HTTPServerConnection] = [:]
        var port: UInt16?
        var isStopped = false
    }

    private let configuration: Configuration
    private let handler: Handler
    private let queue = DispatchQueue(label: "io.github.eric-volz.Orbit.claude-code.mcp-http")
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(configuration: Configuration = Configuration(), handler: @escaping Handler) {
        self.configuration = configuration
        self.handler = handler
    }

    var port: UInt16? {
        state.withLock { $0.port }
    }

    /// Starts listening on 127.0.0.1 and returns the port.
    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let isStopped = state.withLock { state -> Bool in
            if !state.isStopped { state.listener = listener }
            return state.isStopped
        }
        guard !isStopped else { throw Failure.stopped }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let resume: @Sendable (Result<UInt16, Error>) -> Void = { result in
                guard resumed.withLock({ done in
                    defer { done = true }
                    return !done
                }) else { return }
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { [weak listener] newState in
                switch newState {
                case .ready:
                    if let port = listener?.port?.rawValue, port != 0 {
                        resume(.success(port))
                    } else {
                        resume(.failure(Failure.listenerFailed))
                    }
                case .failed, .cancelled:
                    resume(.failure(Failure.listenerFailed))
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        state.withLock { $0.port = port }
        return port
    }

    /// Stops listening and closes all connections (running handlers are cancelled).
    func stop() {
        let (listener, connections) = state.withLock { state -> (NWListener?, [HTTPServerConnection]) in
            state.isStopped = true
            defer {
                state.listener = nil
                state.connections = [:]
            }
            return (state.listener, Array(state.connections.values))
        }
        listener?.cancel()
        for connection in connections {
            connection.abort()
        }
    }

    private func accept(_ connection: NWConnection) {
        let serverConnection = HTTPServerConnection(connection: connection, queue: queue, configuration: configuration,
                                                    handler: handler) { [weak self] id in
            self?.state.withLock { _ = $0.connections.removeValue(forKey: id) }
        }
        let accepted = state.withLock { state -> Bool in
            guard !state.isStopped, state.connections.count < configuration.maxConnections else { return false }
            state.connections[serverConnection.id] = serverConnection
            return true
        }
        guard accepted else {
            Log.llm.notice("claude-code bridge: connection refused (limit reached or stopped)")
            connection.cancel()
            return
        }
        Task { await serverConnection.start() }
    }
}

/// One client connection of `LoopbackHTTPServer`.
actor HTTPServerConnection {
    nonisolated let id = UUID()
    private nonisolated let connection: NWConnection
    private let queue: DispatchQueue
    private let configuration: LoopbackHTTPServer.Configuration
    private let handler: LoopbackHTTPServer.Handler
    private let onClose: @Sendable (UUID) -> Void

    private var parser: HTTPRequestParser
    private var isReceiving = false
    private var isClosed = false
    private var handling: Task<Void, Never>?
    private var deadline: Task<Void, Never>?

    init(connection: NWConnection, queue: DispatchQueue, configuration: LoopbackHTTPServer.Configuration,
         handler: @escaping LoopbackHTTPServer.Handler, onClose: @escaping @Sendable (UUID) -> Void) {
        self.connection = connection
        self.queue = queue
        self.configuration = configuration
        self.handler = handler
        self.onClose = onClose
        parser = HTTPRequestParser(limits: configuration.limits)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .failed, .cancelled:
                Task { await self?.close() }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    /// Immediate teardown from any thread (server stop, app termination).
    nonisolated func abort() {
        connection.cancel()
    }

    // MARK: Receiving

    private func receive() {
        guard !isReceiving, !isClosed else { return }
        isReceiving = true
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { await self?.didReceive(data, isComplete: isComplete, failed: error != nil) }
        }
    }

    private func didReceive(_ data: Data?, isComplete: Bool, failed: Bool) {
        isReceiving = false
        guard !isClosed else { return }
        if let data, !data.isEmpty {
            parser.append(data)
        }
        if isComplete || failed {
            // The client went away: a running handler (e.g. a tool call) is cancelled.
            close()
            return
        }
        let bufferCap = configuration.limits.maxHeaderBytes + configuration.limits.maxBodyBytes + 64 * 1024
        guard parser.bufferedByteCount <= bufferCap else {
            close()
            return
        }
        processBuffer()
        // Keep reading while a handler runs, to notice a disconnect.
        receive()
    }

    private func processBuffer() {
        guard handling == nil, !isClosed else { return }
        switch parser.next() {
        case .needsMoreData:
            if parser.bufferedByteCount > 0 {
                armDeadline()
            } else {
                deadline?.cancel()
                deadline = nil
            }
        case .failure(let status):
            deadline?.cancel()
            deadline = nil
            send(.empty(status), keepAlive: false)
        case .request(let request):
            deadline?.cancel()
            deadline = nil
            let handler = handler
            handling = Task { [weak self] in
                let response = await handler(request)
                await self?.finish(response, keepAlive: request.keepsAlive)
            }
        }
    }

    private func armDeadline() {
        guard deadline == nil else { return }
        let timeout = configuration.requestTimeout
        deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.requestTimedOut()
        }
    }

    private func requestTimedOut() {
        guard !isClosed, handling == nil else { return }
        deadline = nil
        send(.empty(408), keepAlive: false)
    }

    // MARK: Sending

    private func finish(_ response: HTTPResponse, keepAlive: Bool) {
        handling = nil
        guard !isClosed else { return }
        send(response, keepAlive: keepAlive)
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        connection.send(content: response.serialized(keepAlive: keepAlive),
                        completion: .contentProcessed { [weak self] error in
            Task { await self?.didSend(keepAlive: keepAlive && error == nil) }
        })
    }

    private func didSend(keepAlive: Bool) {
        guard keepAlive else {
            close()
            return
        }
        processBuffer()
        receive()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        handling?.cancel()
        handling = nil
        deadline?.cancel()
        deadline = nil
        connection.cancel()
        onClose(id)
    }
}
