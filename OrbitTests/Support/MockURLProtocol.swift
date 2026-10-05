import Foundation
import os
@testable import Orbit

/// A scripted HTTP endpoint for tests. Each server owns its own `URLSession`;
/// requests are routed to it by a session header, so tests that use different
/// servers can run in parallel.
///
///     let server = MockServer()
///     server.enqueue(.sse(["event: ping\ndata: {}\n\n"]))
///     let provider = try AnthropicProvider(configuration: …, transport: server.transport())
final class MockServer: Sendable {
    /// One scripted response. Chunks are delivered as separate loads, so they can
    /// split lines (or UTF-8 characters) anywhere.
    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        var chunks: [Data] = []
        /// Keeps the response open after the chunks until the client cancels.
        var stalls = false
        /// Never sends response headers (with `stalls`): the request hangs.
        var withholdsHeaders = false
        /// Fails the request with this transport error: right away without
        /// chunks, otherwise shortly after delivering them (a dropped connection).
        var failure: URLError.Code?
        /// With `failure` after chunks: the connection drops only once the test
        /// opens this gate (e.g. after the client consumed the data) instead of
        /// on a timer that a busy test run can make overtake the data.
        var failureGate: FailureGate? = nil

        /// A `text/event-stream` body, delivered in the given chunks.
        static func sse(_ chunks: [String], stalls: Bool = false) -> Response {
            Response(chunks: chunks.map { Data($0.utf8) }, stalls: stalls)
        }

        /// A JSON body.
        static func json(status: Int = 200, _ body: String, headers: [String: String] = [:]) -> Response {
            Response(
                status: status,
                headers: headers.merging(["Content-Type": "application/json"]) { current, _ in current },
                chunks: [Data(body.utf8)]
            )
        }

        /// A plain-text body (what a web server without the API route sends).
        static func text(status: Int, _ body: String) -> Response {
            Response(status: status, headers: ["Content-Type": "text/plain"], chunks: [Data(body.utf8)])
        }

        static func failure(_ code: URLError.Code) -> Response {
            Response(failure: code)
        }

        /// A request that never gets an answer until it is cancelled.
        static let hang = Response(stalls: true, withholdsHeaders: true)
    }

    /// A request as the server received it.
    struct Request: Sendable {
        var method: String
        var url: URL
        /// Header names are lowercased.
        var headers: [String: String]
        var body: Data

        var bodyText: String { String(decoding: body, as: UTF8.self) }
        var bodyJSON: JSONValue? { try? JSONValue.parse(body) }
    }

    private struct State: Sendable {
        var queue: [Response] = []
        var requests: [Request] = []
        var openStalls: Set<ObjectIdentifier> = []
        var cancelledStalls = 0
    }

    let id = UUID().uuidString
    let session: URLSession
    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpAdditionalHeaders = [MockURLProtocol.serverHeader: id]
        configuration.timeoutIntervalForRequest = 30
        session = URLSession(configuration: configuration)
        MockURLProtocol.register(self)
    }

    /// Responses are served in order, one per request. Without a scripted
    /// response the server answers 599.
    func enqueue(_ responses: Response...) {
        state.withLock { $0.queue += responses }
    }

    var requests: [Request] { state.withLock { $0.requests } }

    /// How many stalled responses were ended by the client (cancellation).
    var cancelledStalls: Int { state.withLock { $0.cancelledStalls } }

    /// A transport for providers under test: this server's session, instant
    /// retries (recorded by `sleeps`) and the given feature memory.
    func transport(sleeps: SleepRecorder = SleepRecorder(), memory: ProviderFeatureMemory = ProviderFeatureMemory()) -> ProviderTransport {
        ProviderTransport(session: session, sleep: { await sleeps.record($0) }, featureMemory: memory)
    }

    // MARK: Used by MockURLProtocol

    fileprivate func respond(to request: Request, token: ObjectIdentifier) -> Response {
        state.withLock { state in
            state.requests.append(request)
            let response = state.queue.isEmpty
                ? Response.text(status: 599, "No scripted response")
                : state.queue.removeFirst()
            if response.stalls {
                state.openStalls.insert(token)
            }
            return response
        }
    }

    fileprivate func stopped(_ token: ObjectIdentifier) {
        state.withLock { state in
            if state.openStalls.remove(token) != nil {
                state.cancelledStalls += 1
            }
        }
    }
}

/// Holds back a scripted connection drop until the test opens it
/// (`MockServer.Response.failureGate`). Opening runs what waits, once; what
/// arrives after it runs at once.
///
/// `@unchecked Sendable`: the state is guarded by `lock`; the actions only
/// schedule work on the URL loading thread (`perform(_:on:with:waitUntilDone:modes:)`,
/// which may be called from any thread).
final class FailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiting: [() -> Void] = []

    init() {}

    func whenOpen(_ action: @escaping () -> Void) {
        let runsNow = lock.withLock { () -> Bool in
            if isOpen { return true }
            waiting.append(action)
            return false
        }
        if runsNow { action() }
    }

    func open() {
        let actions = lock.withLock { () -> [() -> Void] in
            isOpen = true
            defer { waiting = [] }
            return waiting
        }
        actions.forEach { $0() }
    }
}

/// Records the delays providers wait before retries, without waiting.
final class SleepRecorder: Sendable {
    private let delays = OSAllocatedUnfairLock<[Duration]>(initialState: [])

    init() {}

    var recorded: [Duration] { delays.withLock { $0 } }

    func record(_ delay: Duration) async {
        delays.withLock { $0.append(delay) }
    }
}

/// Serves `MockServer` responses to sessions created by `MockServer`.
final class MockURLProtocol: URLProtocol {
    static let serverHeader = "X-Orbit-Mock-Server"
    private static let servers = OSAllocatedUnfairLock<[String: MockServer]>(initialState: [:])

    static func register(_ server: MockServer) {
        servers.withLock { $0[server.id] = server }
    }

    private static func server(for request: URLRequest) -> MockServer? {
        guard let id = request.value(forHTTPHeaderField: serverHeader) else { return nil }
        return servers.withLock { $0[id] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: serverHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let server = Self.server(for: request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = server.respond(to: Self.record(request, url: url), token: ObjectIdentifier(self))
        if let failure = response.failure, response.chunks.isEmpty {
            client?.urlProtocol(self, didFailWithError: URLError(failure))
            return
        }
        if response.withholdsHeaders { return }
        guard let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        for chunk in response.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        if let failure = response.failure, let gate = response.failureGate {
            // On this loading thread, as URLSession expects its client to be called.
            let thread = Thread.current
            let code = NSNumber(value: failure.rawValue)
            gate.whenOpen { [self] in
                perform(#selector(fail(with:)), on: thread, with: code, waitUntilDone: false, modes: [RunLoop.Mode.common.rawValue])
            }
        } else if let failure = response.failure {
            // Like a real connection drop, the error arrives after the data (an
            // immediate error could overtake the chunks inside URLSession).
            perform(#selector(fail(with:)), with: NSNumber(value: failure.rawValue), afterDelay: 0.2, inModes: [.common])
        } else if !response.stalls {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    @objc private func fail(with code: NSNumber) {
        client?.urlProtocol(self, didFailWithError: URLError(URLError.Code(rawValue: code.intValue)))
    }

    override func stopLoading() {
        Self.server(for: request)?.stopped(ObjectIdentifier(self))
    }

    private static func record(_ request: URLRequest, url: URL) -> MockServer.Request {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
        }
        var headers: [String: String] = [:]
        for (name, value) in request.allHTTPHeaderFields ?? [:]
        where name.caseInsensitiveCompare(serverHeader) != .orderedSame {
            headers[name.lowercased()] = value
        }
        return MockServer.Request(method: request.httpMethod ?? "GET", url: url, headers: headers, body: body)
    }
}
