import Foundation
import os
import Testing
@testable import Orbit

@Suite("MCP bridge JSON-RPC")
struct OrbitMCPServerTests {
    static let token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    static let port: UInt16 = 50_123

    private func makeServer(tools: [ToolDefinition] = [ClaudeCodeTest.testTool],
                            onInitialize: @escaping @Sendable () -> Void = {}) -> OrbitMCPServer {
        let server = OrbitMCPServer(tools: tools, token: Self.token, onInitialize: onInitialize)
        server.setPort(Self.port)
        return server
    }

    private func request(_ body: JSONValue?, method: String = "POST", target: String = "/mcp",
                         headers: [String: String] = [:]) -> HTTPRequest {
        var allHeaders = [
            "host": "127.0.0.1:\(Self.port)",
            "authorization": "Bearer \(Self.token)",
            "content-type": "application/json",
            "accept": "application/json, text/event-stream",
        ]
        for (name, value) in headers {
            allHeaders[name.lowercased()] = value
        }
        allHeaders = allHeaders.filter { !$0.value.isEmpty }
        return HTTPRequest(method: method, target: target, version: "HTTP/1.1", headers: allHeaders,
                           body: body?.jsonData() ?? Data())
    }

    private func rpc(_ method: String, id: JSONValue? = 1, params: JSONValue? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["jsonrpc": "2.0", "method": .string(method)]
        if let id { object["id"] = id }
        if let params { object["params"] = params }
        return .object(object)
    }

    private func json(_ response: HTTPResponse) throws -> JSONValue {
        try JSONValue.parse(response.body)
    }

    // MARK: Transport checks

    @Test func refusesRequestsWithoutTheToken() async {
        let server = makeServer()
        let missing = await server.respond(to: request(rpc("ping"), headers: ["authorization": ""]))
        #expect(missing.status == 401)
        #expect(missing.headers.contains { $0.name == "WWW-Authenticate" })
        let wrong = await server.respond(to: request(rpc("ping"), headers: ["authorization": "Bearer nope"]))
        #expect(wrong.status == 401)
        let basic = await server.respond(to: request(rpc("ping"), headers: ["authorization": "Basic \(Self.token)"]))
        #expect(basic.status == 401)
    }

    @Test func refusesBrowsersOtherHostsAndOtherRoutes() async {
        let server = makeServer()
        #expect(await server.respond(to: request(rpc("ping"), headers: ["origin": "https://evil.example"])).status == 403)
        #expect(await server.respond(to: request(rpc("ping"), headers: ["host": "evil.example:\(Self.port)"])).status == 403)
        #expect(await server.respond(to: request(rpc("ping"), headers: ["host": "127.0.0.1:1"])).status == 403)
        #expect(await server.respond(to: request(rpc("ping"), headers: ["host": "localhost:\(Self.port)"])).status == 200)
        #expect(await server.respond(to: request(rpc("ping"), target: "/")).status == 404)
        #expect(await server.respond(to: request(rpc("ping"), target: "/mcp?x=1")).status == 404)
        #expect(await server.respond(to: request(rpc("ping"), target: "/.well-known/oauth-protected-resource")).status == 404)
    }

    @Test func onlyPostCarriesMessages() async {
        let server = makeServer()
        let get = await server.respond(to: request(nil, method: "GET", headers: ["accept": "text/event-stream"]))
        #expect(get.status == 405)
        #expect(get.headers.contains { $0.name == "Allow" && $0.value == "POST" })
        #expect(await server.respond(to: request(nil, method: "DELETE")).status == 405)
        #expect(await server.respond(to: request(rpc("ping"), headers: ["content-type": "text/plain"])).status == 415)
    }

    @Test func answersProtocolErrors() async throws {
        let server = makeServer()
        var bad = request(nil)
        bad.body = Data("{not json".utf8)
        let parseError = await server.respond(to: bad)
        #expect(parseError.status == 400)
        #expect(try json(parseError)["error"]?["code"]?.intValue == -32700)
        let batch = await server.respond(to: request([rpc("ping")]))
        #expect(batch.status == 400)
        #expect(try json(batch)["error"]?["code"]?.intValue == -32600)
        let unknown = try json(await server.respond(to: request(rpc("resources/list", id: "r1"))))
        #expect(unknown["id"] == "r1")
        #expect(unknown["error"]?["code"]?.intValue == -32601)
        let noVersion = await server.respond(to: request(["method": "ping", "id": 1]))
        #expect(noVersion.status == 400)
    }

    // MARK: Lifecycle

    @Test(arguments: [("2025-11-25", "2025-11-25"), ("2025-06-18", "2025-06-18"), ("2024-11-05", "2024-11-05"),
                      ("2099-01-01", "2025-11-25")])
    func negotiatesTheProtocolVersion(requested: String, expected: String) async throws {
        let server = makeServer()
        let response = try json(await server.respond(to: request(rpc("initialize", id: 0, params: [
            "protocolVersion": .string(requested), "capabilities": [:], "clientInfo": ["name": "claude-code", "version": "2"],
        ]))))
        #expect(response["id"]?.intValue == 0)
        #expect(response["result"]?["protocolVersion"]?.stringValue == expected)
        #expect(response["result"]?["capabilities"]?["tools"] != nil)
        #expect(response["result"]?["serverInfo"]?["name"] == "orbit")
    }

    @Test func initializeIsReportedOnce() async {
        let count = OSAllocatedUnfairLock(initialState: 0)
        let server = makeServer { count.withLock { $0 += 1 } }
        _ = await server.respond(to: request(rpc("initialize", id: 0, params: ["protocolVersion": "2025-11-25"])))
        _ = await server.respond(to: request(rpc("initialize", id: 1, params: ["protocolVersion": "2025-11-25"])))
        #expect(count.withLock { $0 } == 1)
    }

    @Test func notificationsAndResponsesAreAccepted() async {
        let server = makeServer()
        let initialized = await server.respond(to: request(rpc("notifications/initialized", id: nil)))
        #expect(initialized.status == 202 && initialized.body.isEmpty)
        let response = await server.respond(to: request(["jsonrpc": "2.0", "id": 5, "result": [:]]))
        #expect(response.status == 202)
    }

    @Test func listsTheFrozenTools() async throws {
        let tools = [ClaudeCodeTest.testTool,
                     ToolDefinition(name: "no_type", description: "d", inputSchema: ["properties": [:]])]
        let server = makeServer(tools: tools)
        let response = try json(await server.respond(to: request(rpc("tools/list", id: 2))))
        let listed = try #require(response["result"]?["tools"]?.arrayValue)
        #expect(listed.count == 2)
        #expect(listed[0] == [
            "name": "get_test_value",
            "description": "Returns the current test value.",
            "inputSchema": ["type": "object", "properties": ["label": ["type": "string"]]],
        ])
        #expect(listed[1]["inputSchema"]?["type"] == "object")
    }

    // MARK: Tool calls

    private func callParams(_ name: String = "get_test_value", arguments: JSONValue = ["label": "x"],
                            toolUseID: String? = "toolu_01ABC") -> JSONValue {
        var params: [String: JSONValue] = ["name": .string(name), "arguments": arguments]
        if let toolUseID {
            params["_meta"] = ["claudecode/toolUseId": .string(toolUseID), "progressToken": 2]
        }
        return .object(params)
    }

    @Test func runsToolCallsThroughTheActiveTurnsExecutor() async throws {
        let server = makeServer()
        let executor = StubToolExecutor(result: "Wert: 42")
        let turn = UUID()
        server.beginTurn(turn, executor: executor)
        let response = try json(await server.respond(to: request(rpc("tools/call", id: 3, params: callParams()))))
        #expect(response["id"]?.intValue == 3)
        #expect(response["result"] == ["content": [["type": "text", "text": "Wert: 42"]], "isError": false])
        let call = try #require(executor.calls.first)
        #expect(call.id == "toolu_01ABC")
        #expect(call.name == "get_test_value")
        #expect(call.input == ["label": "x"])
        #expect(call.inputParseError == nil)

        // Prefixed names and missing arguments are accepted; errors stay results.
        let failing = StubToolExecutor(result: "Keine Berechtigung", isError: true)
        server.beginTurn(turn, executor: failing)
        let second = try json(await server.respond(to: request(rpc("tools/call", id: 4, params: [
            "name": "mcp__orbit__get_test_value",
        ]))))
        #expect(second["result"]?["isError"] == true)
        #expect(failing.calls.first?.input == [:])
        #expect(failing.calls.first?.id.hasPrefix("mcp_") == true)
    }

    @Test func rejectsUnknownToolsAndBadArguments() async throws {
        let server = makeServer()
        let executor = StubToolExecutor()
        server.beginTurn(UUID(), executor: executor)
        let unknown = try json(await server.respond(to: request(rpc("tools/call", id: 5, params: callParams("rm_rf")))))
        #expect(unknown["result"]?["isError"] == true)
        #expect(unknown["result"]?["content"]?[0]?["text"]?.stringValue?.contains("Unknown tool") == true)
        let badArguments = try json(await server.respond(to: request(rpc("tools/call", id: 6,
                                                                         params: callParams(arguments: "text")))))
        #expect(badArguments["error"]?["code"]?.intValue == -32602)
        let noName = try json(await server.respond(to: request(rpc("tools/call", id: 7, params: [:]))))
        #expect(noName["error"]?["code"]?.intValue == -32602)
        #expect(executor.calls.isEmpty)
    }

    @Test func callsOutsideATurnFail() async throws {
        let server = makeServer()
        let response = try json(await server.respond(to: request(rpc("tools/call", id: 8, params: callParams()))))
        #expect(response["result"] == OrbitMCPServer.toolResult(OrbitMCPServer.noActiveTurnMessage, isError: true))
        let turn = UUID()
        let executor = StubToolExecutor()
        server.beginTurn(turn, executor: executor)
        server.endTurn(turn)
        let late = try json(await server.respond(to: request(rpc("tools/call", id: 9, params: callParams()))))
        #expect(late["result"]?["isError"] == true)
        #expect(executor.calls.isEmpty)
    }

    @Test func endingATurnAnswersPendingCallsAndCancelsThem() async throws {
        let server = makeServer()
        let executor = StubToolExecutor(blocks: true)
        let turn = UUID()
        server.beginTurn(turn, executor: executor)
        let pending = Task { try json(await server.respond(to: request(rpc("tools/call", id: 10, params: callParams())))) }
        #expect(await LLMTest.eventually { executor.calls.count == 1 && server.pendingCallCount == 1 })
        server.endTurn(turn, message: OrbitMCPServer.cancelledMessage)
        let response = try await pending.value
        #expect(response["result"] == OrbitMCPServer.toolResult(OrbitMCPServer.cancelledMessage, isError: true))
        #expect(await LLMTest.eventually { executor.cancellations == 1 })
        #expect(server.pendingCallCount == 0)
    }

    @Test func aClientCancellationStopsTheExecution() async throws {
        let server = makeServer()
        let executor = StubToolExecutor(blocks: true)
        server.beginTurn(UUID(), executor: executor)
        let pending = Task { try json(await server.respond(to: request(rpc("tools/call", id: 11, params: callParams())))) }
        #expect(await LLMTest.eventually { server.pendingCallCount == 1 })
        let notification = await server.respond(to: request(rpc("notifications/cancelled", id: nil,
                                                                params: ["requestId": 11, "reason": "aborted"])))
        #expect(notification.status == 202)
        let response = try await pending.value
        #expect(response["result"]?["isError"] == true)
        #expect(await LLMTest.eventually { executor.cancellations == 1 })

        // A dropped connection cancels the handler task.
        let dropped = Task { try json(await server.respond(to: request(rpc("tools/call", id: 12, params: callParams())))) }
        #expect(await LLMTest.eventually { server.pendingCallCount == 1 })
        dropped.cancel()
        _ = try await dropped.value
        #expect(await LLMTest.eventually { executor.cancellations == 2 })
        #expect(server.pendingCallCount == 0)
    }

    @Test func comparesTokensInConstantTime() {
        #expect(OrbitMCPServer.constantTimeEquals("Bearer abc", "Bearer abc"))
        #expect(!OrbitMCPServer.constantTimeEquals("Bearer abd", "Bearer abc"))
        #expect(!OrbitMCPServer.constantTimeEquals("Bearer ab", "Bearer abc"))
        #expect(!OrbitMCPServer.constantTimeEquals("", "Bearer abc"))
    }
}
