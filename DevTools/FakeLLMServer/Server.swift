import Foundation
import Network
import os

struct ServerOptions: Sendable {
    var port: UInt16 = 8765
    var logURL: URL?
    var chunkDelay: Duration = ScenarioBuilder.defaultChunkDelay
}

/// A minimal HTTP/1.1 server (loopback only) that imitates the Anthropic
/// Messages API and the OpenAI Chat Completions API with scripted scenarios.
final class FakeLLMServer: Sendable {
    let options: ServerOptions
    let state: ServerState
    private let listener: NWListener
    private let queue = DispatchQueue(label: "FakeLLMServer")

    static let models: [(id: String, name: String)] = [
        ("claude-sonnet-5-5", "Claude Sonnet 5.5 (fake)"),
        ("claude-opus-5-5", "Claude Opus 5.5 (fake)"),
        ("fake-model", "Fake Model"),
    ]

    enum StartError: Error, CustomStringConvertible {
        case invalidPort(UInt16)
        case failed(String)

        var description: String {
            switch self {
            case .invalidPort(let port): "invalid port \(port)"
            case .failed(let reason): reason
            }
        }
    }

    init(options: ServerOptions, state: ServerState) throws {
        self.options = options
        self.state = state
        guard let port = NWEndpoint.Port(rawValue: options.port), options.port != 0 else {
            throw StartError.invalidPort(options.port)
        }
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: port)
    }

    /// Starts listening and returns once the listener is ready.
    func start() async throws {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            @Sendable func resume(_ result: Result<Void, Error>) {
                guard resumed.withLock({ wasResumed in
                    defer { wasResumed = true }
                    return !wasResumed
                }) else { return }
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resume(.success(()))
                case .failed(let error):
                    if resumed.withLock({ $0 }) {
                        // The listener died after startup: stop, so scripts notice.
                        printError("FakeLLMServer: listener failed: \(error)")
                        exit(1)
                    }
                    resume(.failure(StartError.failed("listener failed: \(error)")))
                case .waiting(let error):
                    resume(.failure(StartError.failed("cannot listen: \(error)")))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [self] connection in
                Task { await self.handle(connection) }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    // MARK: Connections

    private func handle(_ connection: NWConnection) async {
        connection.start(queue: queue)
        defer { connection.cancel() }
        // Drop clients that never finish sending a request.
        let readTimeout = Task {
            try await Task.sleep(for: .seconds(30))
            connection.cancel()
        }
        defer { readTimeout.cancel() }
        let request: HTTPRequest
        do {
            request = try await HTTP.readRequest(from: connection)
            readTimeout.cancel()
        } catch let error as HTTPError {
            if let status = error.status {
                printError("request rejected → \(status) (\(error))")
                await sendJSON(status, sharedError(type: "invalid_request_error", message: "\(error)"), on: connection)
                await finish(connection)
            }
            return
        } catch {
            return
        }
        await route(request, on: connection)
        await finish(connection)
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) async {
        let path = request.path
        let isKnownRoute = ["/v1/messages", "/v1/chat/completions", "/v1/models"].contains(path) || path.hasPrefix("/v1/models/")
        guard isKnownRoute else {
            printError("\(request.method) \(path) → 404")
            await sendJSON(404, sharedError(type: "not_found_error", message: "Unknown route \(path)"), on: connection)
            return
        }
        switch (request.method, path) {
        case ("POST", "/v1/messages"):
            await handleChat(request, flavor: .anthropic, on: connection)
        case ("POST", "/v1/chat/completions"):
            await handleChat(request, flavor: .openAI, on: connection)
        case ("GET", "/v1/models"):
            guard await authorize(request, on: connection) else { return }
            let data = Self.models.map { Self.modelObject(id: $0.id, name: $0.name) }
            printError("GET /v1/models → 200")
            await sendJSON(200, [
                "object": "list",
                "data": .array(data),
                "has_more": false,
                "first_id": .optional(Self.models.first?.id),
                "last_id": .optional(Self.models.last?.id),
            ], on: connection)
        case ("GET", _) where path.hasPrefix("/v1/models/"):
            guard await authorize(request, on: connection) else { return }
            let rawID = String(path.dropFirst("/v1/models/".count))
            let id = rawID.removingPercentEncoding ?? rawID
            if id.isEmpty || id.hasPrefix("missing") {
                printError("GET \(path) → 404")
                await sendJSON(404, sharedError(type: "not_found_error", message: "model: \(id)", code: "model_not_found"),
                               on: connection)
            } else {
                printError("GET \(path) → 200")
                let name = Self.models.first(where: { $0.id == id })?.name ?? id
                await sendJSON(200, Self.modelObject(id: id, name: name), on: connection)
            }
        default:
            printError("\(request.method) \(path) → 405")
            await sendJSON(405, sharedError(type: "invalid_request_error", message: "Method \(request.method) not allowed"),
                           extraHeaders: [("Allow", path.hasPrefix("/v1/models") ? "GET" : "POST")], on: connection)
        }
    }

    /// Keys starting with "invalid" are rejected (to test the settings check).
    private func authorize(_ request: HTTPRequest, on connection: NWConnection) async -> Bool {
        guard let key = request.apiKey, key.hasPrefix("invalid") else { return true }
        printError("\(request.method) \(request.path) → 401 (invalid key)")
        await sendJSON(401, sharedError(type: "authentication_error", message: "invalid x-api-key", code: "invalid_api_key"),
                       on: connection)
        return false
    }

    // MARK: Chat

    private func handleChat(_ request: HTTPRequest, flavor: Flavor, on connection: NWConnection) async {
        let parsed = try? JSON.parse(request.body)
        await state.logRequestBody(request.body, parsed: parsed)
        guard await authorize(request, on: connection) else { return }
        let chat: ChatRequest
        do {
            guard let parsed else { throw JSON.ParseError(description: "request body is not valid JSON") }
            chat = try ChatRequest(flavor: flavor, body: parsed)
        } catch {
            printError("POST \(request.path) → 400 (\(error))")
            await sendError(status: 400, message: "\(error)", flavor: flavor, model: "", on: connection)
            return
        }

        let scenario = ScenarioBuilder.scenario(for: chat, chunkDelay: options.chunkDelay)
        printError("POST \(request.path) [\(flavor.rawValue)] model=\(chat.model) messages=\(chat.messageCount) tools=\(chat.toolCount) stream=\(chat.stream) → \(scenario.name)")

        if flavor == .anthropic, let problems = await state.verifyThinkingEcho(in: chat.body) {
            if problems.isEmpty {
                printError("THINKING_ECHO_OK")
                await state.logEvent("THINKING_ECHO_OK")
            } else {
                printError("THINKING_ECHO_MISMATCH: " + problems.joined(separator: "; "))
                await state.logEvent("THINKING_ECHO_MISMATCH", details: [(key: "problems", value: .array(problems.map(JSON.string)))])
            }
        }
        let inputTokens = estimatedTokens(request.body.count)
        switch scenario {
        case .httpError(let status, let message):
            await sendError(status: status, message: message, flavor: flavor, model: chat.model, on: connection)
        case .turn(let turn, _):
            await state.registerIssued(turn: turn)
            switch (flavor, chat.stream) {
            case (.anthropic, true):
                let events = AnthropicRenderer.events(for: turn, request: chat, messageID: ScenarioBuilder.identifier(for: flavor, tool: false),
                                                      inputTokens: inputTokens)
                await stream(events, delay: turn.chunkDelay, flavor: flavor, path: request.path, on: connection)
            case (.openAI, true):
                let events = OpenAIRenderer.events(for: turn, request: chat, completionID: ScenarioBuilder.identifier(for: flavor, tool: false),
                                                   inputTokens: inputTokens)
                await stream(events, delay: turn.chunkDelay, flavor: flavor, path: request.path, on: connection)
            case (.anthropic, false):
                if turn.stop == nil {
                    await sendError(status: 529, message: nil, flavor: flavor, model: chat.model, on: connection)
                } else {
                    let message = AnthropicRenderer.message(for: turn, request: chat, messageID: ScenarioBuilder.identifier(for: flavor, tool: false),
                                                            inputTokens: inputTokens)
                    await sendJSON(200, message, extraHeaders: requestIDHeader(flavor), on: connection)
                }
            case (.openAI, false):
                if turn.stop == nil {
                    await sendError(status: 529, message: nil, flavor: flavor, model: chat.model, on: connection)
                } else {
                    let completion = OpenAIRenderer.completion(for: turn, request: chat, completionID: ScenarioBuilder.identifier(for: flavor, tool: false),
                                                               inputTokens: inputTokens)
                    await sendJSON(200, completion, extraHeaders: requestIDHeader(flavor), on: connection)
                }
            }
        }
    }

    private func stream(_ events: [SSEEvent], delay: Duration, flavor: Flavor, path: String, on connection: NWConnection) async {
        let monitor = DisconnectMonitor()
        monitor.watch(connection)
        var headers = [("Content-Type", "text/event-stream; charset=utf-8"), ("Cache-Control", "no-cache")]
        headers += requestIDHeader(flavor)
        do {
            try await connection.sendData(HTTP.head(status: 200, headers: headers))
            for event in events {
                if event.paced {
                    try await Task.sleep(for: delay)
                }
                if monitor.isDisconnected { throw CancellationError() }
                try await connection.sendData(event.wireFormat)
            }
        } catch {
            printError("POST \(path): client disconnected, streaming stopped")
            await state.logEvent("CLIENT_DISCONNECTED", details: [(key: "path", value: .string(path))])
        }
    }

    // MARK: Responses

    private func sendError(status: Int, message: String?, flavor: Flavor, model: String, on connection: NWConnection) async {
        let description = errorDescription(status: status, model: model)
        let text = message ?? description.message
        let body: JSON
        switch flavor {
        case .anthropic:
            body = AnthropicRenderer.errorBody(type: description.type, message: text, requestID: "req_fake_" + ScenarioBuilder.randomHex(20))
        case .openAI:
            body = OpenAIRenderer.errorBody(type: description.type, message: text, code: description.code)
        }
        var headers = requestIDHeader(flavor)
        if status == 429 {
            headers.append(("retry-after", "2"))
        }
        await sendJSON(status, body, extraHeaders: headers, on: connection)
    }

    /// An error body both dialects can read (for the shared routes).
    private func sharedError(type: String, message: String, code: String? = nil) -> JSON {
        [
            "type": "error",
            "error": ["type": .string(type), "message": .string(message), "param": nil, "code": .optional(code)],
            "request_id": .string("req_fake_" + ScenarioBuilder.randomHex(20)),
        ]
    }

    private func requestIDHeader(_ flavor: Flavor) -> [(String, String)] {
        switch flavor {
        case .anthropic: [("request-id", "req_fake_" + ScenarioBuilder.randomHex(20))]
        case .openAI: [("x-request-id", "req_fake_" + ScenarioBuilder.randomHex(20))]
        }
    }

    private func sendJSON(_ status: Int, _ body: JSON, extraHeaders: [(String, String)] = [], on connection: NWConnection) async {
        let data = body.serializedData
        let headers = [("Content-Type", "application/json"), ("Content-Length", "\(data.count)")] + extraHeaders
        try? await connection.sendData(HTTP.head(status: status, headers: headers) + data)
    }

    /// Half-closes the connection after the response so the client sees EOF.
    private func finish(_ connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }

    static func modelObject(id: String, name: String) -> JSON {
        [
            "type": "model",
            "id": .string(id),
            "display_name": .string(name),
            "created_at": "2026-01-01T00:00:00Z",
            "object": "model",
            "created": 1_767_225_600,
            "owned_by": "fake-llm-server",
        ]
    }
}
