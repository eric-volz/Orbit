import Foundation
import os

/// Orbit's tools as a Streamable-HTTP MCP server for one Claude Code process.
///
/// JSON-RPC over POST (plain JSON responses, no SSE stream): `initialize`,
/// `ping`, `tools/list` (the conversation's frozen definitions) and
/// `tools/call`, which runs through the `ToolExecuting` of the turn that is
/// currently running: validation, confirmation cards, status rows and limits
/// are the agent loop's. Calls outside a running turn, and calls still pending
/// when a turn ends or is cancelled, get an error result.
///
/// Every request must carry the process's bearer token and target
/// `http://127.0.0.1:<port>/mcp`; browser requests (with an `Origin`) and other
/// hosts are refused (DNS rebinding).
final class OrbitMCPServer: Sendable {
    static let path = "/mcp"
    /// Newest first; an unknown client version gets the newest.
    static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    /// Model-facing results (English).
    static let noActiveTurnMessage = "No Orbit request is running, so the tool was not run."
    static let cancelledMessage = "The user stopped the request; the tool call was cancelled."
    static let finishedMessage = "The request already ended; the tool call was cancelled."

    let tools: [ToolDefinition]
    private let token: String
    private let onInitialize: @Sendable () -> Void
    private let toolsByName: [String: ToolDefinition]

    private struct PendingCall: Sendable {
        var turnID: UUID
        var requestID: JSONValue
        var promise: ToolCallPromise
        var task: Task<Void, Never>
    }

    private struct State: Sendable {
        var port: UInt16?
        var activeTurn: (id: UUID, executor: any ToolExecuting)?
        var pending: [UUID: PendingCall] = [:]
        var didInitialize = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(tools: [ToolDefinition], token: String, onInitialize: @escaping @Sendable () -> Void = {}) {
        self.tools = tools
        self.token = token
        self.onInitialize = onInitialize
        var byName: [String: ToolDefinition] = [:]
        for tool in tools {
            byName[tool.name] = tool
        }
        toolsByName = byName
    }

    /// The port the HTTP server listens on (for the Host check).
    func setPort(_ port: UInt16) {
        state.withLock { $0.port = port }
    }

    // MARK: Turns

    /// Routes tool calls to `executor` until the turn ends.
    func beginTurn(_ id: UUID, executor: (any ToolExecuting)?) {
        state.withLock { state in
            state.activeTurn = executor.map { (id, $0) }
        }
    }

    /// Ends the turn: pending calls of it are answered with `message` (as an
    /// error result) and their executions cancelled.
    func endTurn(_ id: UUID, message: String = OrbitMCPServer.finishedMessage) {
        let calls = state.withLock { state -> [PendingCall] in
            if state.activeTurn?.id == id { state.activeTurn = nil }
            let matching = state.pending.filter { $0.value.turnID == id }
            for key in matching.keys {
                state.pending.removeValue(forKey: key)
            }
            return Array(matching.values)
        }
        for call in calls {
            call.promise.fulfill(ToolResultBlock(toolCallID: "", content: message, isError: true))
            call.task.cancel()
        }
    }

    /// Number of tool calls waiting for a result (tests, diagnostics).
    var pendingCallCount: Int {
        state.withLock { $0.pending.count }
    }

    // MARK: HTTP

    func respond(to request: HTTPRequest) async -> HTTPResponse {
        if let failure = rejection(of: request) {
            return failure
        }
        guard request.method == "POST" else {
            return .empty(405, headers: [("Allow", "POST")])
        }
        guard (request.header("content-type") ?? "").lowercased().hasPrefix("application/json") else {
            return .empty(415)
        }
        let message: JSONValue
        do {
            message = try JSONValue.parse(request.body)
        } catch {
            return .json(Self.errorResponse(id: .null, code: -32700, message: "Parse error"), status: 400)
        }
        guard case .object(let object) = message else {
            // Batches are not part of the current protocol.
            return .json(Self.errorResponse(id: .null, code: -32600, message: "Invalid Request"), status: 400)
        }
        guard object["jsonrpc"]?.stringValue == "2.0" else {
            return .json(Self.errorResponse(id: object["id"] ?? .null, code: -32600, message: "Invalid Request"), status: 400)
        }
        guard let method = object["method"]?.stringValue else {
            // A response to a server request (Orbit sends none).
            return .empty(202)
        }
        guard let id = object["id"], id.stringValue != nil || id.doubleValue != nil else {
            handleNotification(method, params: object["params"])
            return .empty(202)
        }
        let params = object["params"] ?? .object([:])
        switch method {
        case "initialize":
            return .json(Self.resultResponse(id: id, result: initializeResult(params)))
        case "ping":
            return .json(Self.resultResponse(id: id, result: .object([:])))
        case "tools/list":
            return .json(Self.resultResponse(id: id, result: .object(["tools": .array(tools.map(Self.definition))])))
        case "tools/call":
            return .json(await callTool(id: id, params: params))
        default:
            return .json(Self.errorResponse(id: id, code: -32601, message: "Method not found"))
        }
    }

    /// Transport-level checks: route, host, origin, token.
    private func rejection(of request: HTTPRequest) -> HTTPResponse? {
        let port = state.withLock { $0.port }
        if request.header("origin") != nil {
            return .empty(403)
        }
        let host = (request.header("host") ?? "").lowercased()
        let allowedHosts = port.map { ["127.0.0.1:\($0)", "localhost:\($0)"] } ?? []
        guard allowedHosts.contains(host) else {
            return .empty(403)
        }
        guard Self.constantTimeEquals(request.header("authorization") ?? "", "Bearer \(token)") else {
            return .empty(401, headers: [("WWW-Authenticate", "Bearer")])
        }
        guard request.path == Self.path, !request.target.contains("?") else {
            return .empty(404)
        }
        return nil
    }

    // MARK: JSON-RPC

    private func initializeResult(_ params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.supportedProtocolVersions[0]
        let isFirst = state.withLock { state -> Bool in
            defer { state.didInitialize = true }
            return !state.didInitialize
        }
        if isFirst { onInitialize() }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": false])]),
            "serverInfo": .object(["name": .string(ClaudeCodeLaunch.mcpServerName), "version": .string(appVersion)]),
        ])
    }

    private func handleNotification(_ method: String, params: JSONValue?) {
        guard method == "notifications/cancelled", let requestID = params?["requestId"] else { return }
        let calls = state.withLock { state -> [PendingCall] in
            let matching = state.pending.filter { $0.value.requestID == requestID }
            for key in matching.keys {
                state.pending.removeValue(forKey: key)
            }
            return Array(matching.values)
        }
        for call in calls {
            call.promise.fulfill(ToolResultBlock(toolCallID: "", content: Self.cancelledMessage, isError: true))
            call.task.cancel()
        }
    }

    private func callTool(id: JSONValue, params: JSONValue) async -> JSONValue {
        guard let rawName = params["name"]?.stringValue else {
            return Self.errorResponse(id: id, code: -32602, message: "Invalid params: name is required")
        }
        let name = rawName.hasPrefix(ClaudeCodeLaunch.mcpToolPrefix)
            ? String(rawName.dropFirst(ClaudeCodeLaunch.mcpToolPrefix.count)) : rawName
        let arguments = params["arguments"] ?? .object([:])
        let input: JSONValue
        switch arguments {
        case .object: input = arguments
        case .null: input = .object([:])
        default: return Self.errorResponse(id: id, code: -32602, message: "Invalid params: arguments must be an object")
        }
        guard toolsByName[name] != nil else {
            return Self.resultResponse(id: id, result: Self.toolResult("Unknown tool: \(name)", isError: true))
        }
        let callID = Self.toolUseID(params["_meta"]?["claudecode/toolUseId"]) ?? "mcp_\(UUID().uuidString)"
        let call = ToolCall(id: callID, name: name, input: input, rawInput: input.jsonString())

        let promise = ToolCallPromise()
        let key = UUID()
        let registered = state.withLock { state -> Bool in
            guard let turn = state.activeTurn else { return false }
            let executor = turn.executor
            let task = Task {
                let result = await executor.execute(call)
                promise.fulfill(result)
            }
            state.pending[key] = PendingCall(turnID: turn.id, requestID: id, promise: promise, task: task)
            return true
        }
        guard registered else {
            return Self.resultResponse(id: id, result: Self.toolResult(Self.noActiveTurnMessage, isError: true))
        }
        Log.llm.info("claude-code bridge: tool call started")
        let result = await withTaskCancellationHandler {
            await promise.value
        } onCancel: {
            // The client disconnected: stop the execution.
            let call = state.withLock { $0.pending.removeValue(forKey: key) }
            call?.task.cancel()
            promise.fulfill(ToolResultBlock(toolCallID: callID, content: Self.cancelledMessage, isError: true))
        }
        state.withLock { _ = $0.pending.removeValue(forKey: key) }
        return Self.resultResponse(id: id, result: Self.toolResult(result.content, isError: result.isError))
    }

    // MARK: Encoding

    static func definition(_ tool: ToolDefinition) -> JSONValue {
        var schema = tool.inputSchema
        if case .object(var object) = schema, object["type"] == nil {
            object["type"] = "object"
            schema = .object(object)
        } else if schema.objectValue == nil {
            schema = .object(["type": "object"])
        }
        return .object([
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": schema,
        ])
    }

    static func toolResult(_ text: String, isError: Bool) -> JSONValue {
        .object([
            "content": .array([.object(["type": "text", "text": .string(text)])]),
            "isError": .bool(isError),
        ])
    }

    static func resultResponse(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": "2.0", "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }

    /// Claude Code's tool use id (`toolu_…`), so the call matches `.toolCallStarted`.
    private static func toolUseID(_ value: JSONValue?) -> String? {
        guard let id = value?.stringValue, (1...200).contains(id.count),
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) else { return nil }
        return id
    }

    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= a ^ b
        }
        return difference == 0
    }
}

/// A result that is delivered once (by the execution or by a cancellation).
final class ToolCallPromise: Sendable {
    private struct State: Sendable {
        var value: ToolResultBlock?
        var waiters: [CheckedContinuation<ToolResultBlock, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func fulfill(_ value: ToolResultBlock) {
        let waiters = state.withLock { state -> [CheckedContinuation<ToolResultBlock, Never>] in
            guard state.value == nil else { return [] }
            state.value = value
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume(returning: value)
        }
    }

    var value: ToolResultBlock {
        get async {
            await withCheckedContinuation { continuation in
                let value = state.withLock { state -> ToolResultBlock? in
                    if let value = state.value { return value }
                    state.waiters.append(continuation)
                    return nil
                }
                if let value { continuation.resume(returning: value) }
            }
        }
    }
}
