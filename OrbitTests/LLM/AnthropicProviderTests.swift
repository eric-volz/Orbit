import Foundation
import os
import Testing
@testable import Orbit

@Suite("Anthropic provider")
struct AnthropicProviderTests {
    private let official = ProviderConfiguration(kind: .anthropic, apiKey: "sk-ant-test", baseURL: nil)
    private let ollama = ProviderConfiguration(kind: .anthropic, apiKey: "", baseURL: URL(string: "http://127.0.0.1:11434"))

    private func provider(
        _ server: MockServer,
        _ configuration: ProviderConfiguration? = nil,
        sleeps: SleepRecorder = SleepRecorder(),
        memory: ProviderFeatureMemory = ProviderFeatureMemory()
    ) throws -> AnthropicProvider {
        try AnthropicProvider(configuration: configuration ?? official, transport: server.transport(sleeps: sleeps, memory: memory))
    }

    private func request(
        _ model: String = "claude-sonnet-5-5",
        messages: [Message] = [.user("Hallo")],
        tools: [ToolDefinition] = [],
        effort: ReasoningEffort? = nil
    ) -> LLMRequest {
        LLMRequest(model: model, systemPrompt: "You are Orbit.", messages: messages, tools: tools, effort: effort)
    }

    // MARK: Requests

    @Test func sendsOfficialHeadersAndDeterministicBody() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: AnthropicSSE.textAnswer(["ok"])))
        let request = request(tools: [LLMTest.weatherTool], effort: .low)
        let result = await LLMTest.collect(try provider(server).stream(request))
        #expect(result.turn != nil)

        let sent = try #require(server.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.headers["x-api-key"] == "sk-ant-test")
        #expect(sent.headers["anthropic-version"] == "2023-06-01")
        #expect(sent.headers["content-type"] == "application/json")
        #expect(sent.headers["accept"] == "text/event-stream")
        #expect(sent.headers["anthropic-beta"] == "server-side-fallback-2026-07-01,thinking-display-updates-2026-08-18")
        let features = AnthropicFeatures.for(model: request.model, effort: .low, officialAPI: true)
        #expect(sent.body == AnthropicWire.requestBody(for: request, messages: request.messages, features: features).jsonData())
    }

    @Test(arguments: ["http://127.0.0.1:11434", "http://127.0.0.1:11434/", "http://127.0.0.1:11434/v1", "http://127.0.0.1:11434/v1/"])
    func customBaseWithoutKeyGetsNoOptionalFeatures(base: String) async throws {
        let server = MockServer()
        server.enqueue(.sse(events: AnthropicSSE.textAnswer(["ok"], model: "gpt-oss:20b")))
        let configuration = ProviderConfiguration(kind: .anthropic, apiKey: "", baseURL: URL(string: base))
        let result = await LLMTest.collect(try provider(server, configuration).stream(request("gpt-oss:20b", tools: [LLMTest.weatherTool], effort: .high)))
        #expect(result.turn?.model == "gpt-oss:20b")

        let sent = try #require(server.requests.first)
        #expect(sent.url.absoluteString == "http://127.0.0.1:11434/v1/messages")
        #expect(sent.headers["x-api-key"] == nil)
        #expect(sent.headers["anthropic-beta"] == nil)
        let body = try #require(sent.bodyJSON)
        for key in ["cache_control", "thinking", "fallbacks", "output_config", "tool_choice", "temperature"] {
            #expect(body[key] == nil, "\(key)")
        }
        #expect(body["tools"]?[0]?["eager_input_streaming"] == nil)
        #expect(body["system"]?[0]?["cache_control"] == ["type": "ephemeral"])
    }

    @Test func officialAPIWithoutKeyFailsBeforeAnyRequest() async throws {
        let server = MockServer()
        let configuration = ProviderConfiguration(kind: .anthropic, apiKey: "  ", baseURL: nil)
        let result = await LLMTest.collect(try provider(server, configuration).stream(request()))
        #expect(result.llmError == .missingAPIKey)
        #expect(result.events.isEmpty)
        await #expect(throws: LLMError.missingAPIKey) {
            try await provider(server, configuration).validateConfiguration(model: "claude-sonnet-5-5")
        }
        #expect(server.requests.isEmpty)
    }

    // MARK: Stream decoding

    @Test(arguments: [1, 7, 64, 4096])
    func streamsTextThroughChunksSplitAnywhere(chunkSize: Int) async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            AnthropicSSE.messageStart(inputTokens: 20, cacheRead: 100, cacheCreation: 50),
            AnthropicSSE.ping,
            AnthropicSSE.textBlock(0),
            AnthropicSSE.textDelta(0, "Grüße"),
            AnthropicSSE.textDelta(0, " aus Köln 👋"),
            AnthropicSSE.blockStop(0),
            AnthropicSSE.messageDelta(stopReason: "end_turn", outputTokens: 9),
            AnthropicSSE.messageStop,
        ], chunkSize: chunkSize))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.error == nil)
        #expect(result.textDeltas == ["Grüße", " aus Köln 👋"])
        #expect(result.endCount == 1)
        let turn = try #require(result.turn)
        #expect(turn.content == [.text("Grüße aus Köln 👋")])
        #expect(turn.stopReason == .endTurn)
        #expect(turn.model == "claude-sonnet-5-5")
        #expect(turn.usage == TokenUsage(inputTokens: 20, outputTokens: 9, cacheReadInputTokens: 100, cacheCreationInputTokens: 50))
    }

    @Test func thinkingBlocksBecomeProgressNotesWhenRequested() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            AnthropicSSE.messageStart(model: "claude-opus-5-5"),
            AnthropicSSE.thinkingBlock(0),
            AnthropicSSE.thinkingDelta(0, "Ich suche "),
            AnthropicSSE.thinkingDelta(0, "die Rechnung."),
            AnthropicSSE.signatureDelta(0, "c2lnLTE="),
            AnthropicSSE.blockStop(0),
            AnthropicSSE.thinkingBlock(1), // hidden reasoning: empty text, signature only
            AnthropicSSE.signatureDelta(1, "c2lnLTI="),
            AnthropicSSE.blockStop(1),
            AnthropicSSE.toolUseBlock(2, id: "toolu_01", name: "search_files"),
            AnthropicSSE.inputJSONDelta(2, #"{"query":"Rechnung"}"#),
            AnthropicSSE.blockStop(2),
            AnthropicSSE.messageDelta(stopReason: "tool_use"),
            AnthropicSSE.messageStop,
        ], chunkSize: 11))
        let result = await LLMTest.collect(try provider(server).stream(request("claude-opus-5-5")))
        #expect(result.progressNotes == ["Ich suche die Rechnung."])
        #expect(result.textDeltas.isEmpty)
        let turn = try #require(result.turn)
        #expect(turn.content == [
            .thinking(text: "Ich suche die Rechnung.", signature: "c2lnLTE="),
            .thinking(text: "", signature: "c2lnLTI="),
            .toolUse(ToolCall(id: "toolu_01", name: "search_files", input: ["query": "Rechnung"], rawInput: #"{"query":"Rechnung"}"#)),
        ])
        #expect(turn.stopReason == .toolUse)
        let noteIndex = try #require(result.events.firstIndex { if case .progressNote = $0 { true } else { false } })
        let startIndex = try #require(result.events.firstIndex { if case .toolCallStarted = $0 { true } else { false } })
        #expect(noteIndex < startIndex)
    }

    @Test func interruptedWorkPlaceholderIsNoProgressNote() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            AnthropicSSE.messageStart(model: "claude-sonnet-5-5"),
            AnthropicSSE.thinkingBlock(0),
            AnthropicSSE.thinkingDelta(0, AnthropicWire.interruptedWorkNote),
            AnthropicSSE.signatureDelta(0, "c2ln"),
            AnthropicSSE.blockStop(0),
            AnthropicSSE.messageDelta(stopReason: "max_tokens"),
            AnthropicSSE.messageStop,
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.progressNotes.isEmpty)
        #expect(result.turn?.content == [.thinking(text: AnthropicWire.interruptedWorkNote, signature: "c2ln")])
        #expect(result.turn?.stopReason == .maxTokens)
    }

    @Test func redactedThinkingIsKeptForTheEcho() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            AnthropicSSE.messageStart(),
            AnthropicSSE.blockStart(0, ["type": "redacted_thinking", "data": "RU5DUllQVEVE"]),
            AnthropicSSE.blockStop(0),
            AnthropicSSE.textBlock(1),
            AnthropicSSE.textDelta(1, "Fertig."),
            AnthropicSSE.blockStop(1),
            AnthropicSSE.messageDelta(stopReason: "end_turn"),
            AnthropicSSE.messageStop,
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.turn?.content == [.redactedThinking(data: "RU5DUllQVEVE"), .text("Fertig.")])
    }

    @Test func toolUseInputArrivesInPieces() async throws {
        let fragments = ["", #"{"qu"#, #"ery": "Rech"#, #"nung März", "#, #""limit": 5}"#]
        let server = MockServer()
        server.enqueue(.sse(events: [AnthropicSSE.messageStart(), AnthropicSSE.toolUseBlock(0, id: "toolu_9", name: "search_files")]
            + fragments.map { AnthropicSSE.inputJSONDelta(0, $0) }
            + [AnthropicSSE.blockStop(0), AnthropicSSE.messageDelta(stopReason: "tool_use"), AnthropicSSE.messageStop],
            chunkSize: 5))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        let expected = ToolCall(id: "toolu_9", name: "search_files", input: ["query": "Rechnung März", "limit": 5], rawInput: fragments.joined())
        #expect(result.startedToolCalls == ["toolu_9/search_files"])
        #expect(result.toolCalls == [expected])
        #expect(result.turn?.content == [.toolUse(expected)])
        #expect(result.turn?.stopReason == .toolUse)
        #expect(result.turn?.toolCalls == [expected])
    }

    @Test func invalidToolJSONIsReportedNotThrown() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            AnthropicSSE.messageStart(),
            AnthropicSSE.toolUseBlock(0, id: "toolu_bad", name: "search_files"),
            AnthropicSSE.inputJSONDelta(0, #"{"query": "#),
            AnthropicSSE.blockStop(0),
            AnthropicSSE.toolUseBlock(1, id: "toolu_empty", name: "list_shortcuts"),
            AnthropicSSE.blockStop(1),
            AnthropicSSE.messageDelta(stopReason: "tool_use"),
            AnthropicSSE.messageStop,
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.error == nil)
        let calls = result.toolCalls
        #expect(calls.count == 2)
        #expect(calls.first == ToolCall(id: "toolu_bad", name: "search_files", input: .object([:]), rawInput: #"{"query": "#, inputParseError: ToolCallDecoding.invalidJSONMessage))
        #expect(calls.last == ToolCall(id: "toolu_empty", name: "list_shortcuts", input: .object([:])))
    }

    @Test func blocksBeforeTheLastFallbackAreNotEchoed() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            AnthropicSSE.messageStart(model: "claude-fable-5-1"),
            AnthropicSSE.thinkingBlock(0),
            AnthropicSSE.thinkingDelta(0, "Plan"),
            AnthropicSSE.signatureDelta(0, "c2lnQQ=="),
            AnthropicSSE.blockStop(0),
            AnthropicSSE.textBlock(1),
            AnthropicSSE.textDelta(1, "Teil eins. "),
            AnthropicSSE.blockStop(1),
            AnthropicSSE.toolUseBlock(2, id: "toolu_a", name: "search_files"),
            AnthropicSSE.inputJSONDelta(2, "{}"),
            AnthropicSSE.blockStop(2),
            AnthropicSSE.blockStart(3, ["type": "fallback", "from": ["model": "claude-fable-5-1"], "to": ["model": "claude-opus-5"]]),
            AnthropicSSE.blockStop(3),
            AnthropicSSE.thinkingBlock(4),
            AnthropicSSE.signatureDelta(4, "c2lnQg=="),
            AnthropicSSE.blockStop(4),
            AnthropicSSE.textBlock(5),
            AnthropicSSE.textDelta(5, "Teil zwei."),
            AnthropicSSE.blockStop(5),
            AnthropicSSE.messageDelta(stopReason: "end_turn"),
            AnthropicSSE.messageStop,
        ], chunkSize: 17))
        let result = await LLMTest.collect(try provider(server).stream(request("claude-fable-5-1")))
        #expect(result.textDeltas == ["Teil eins. ", "Teil zwei."])
        let turn = try #require(result.turn)
        #expect(turn.content == [.text("Teil eins. "), .thinking(text: "", signature: "c2lnQg=="), .text("Teil zwei.")])
        #expect(turn.model == "claude-opus-5")
        #expect(turn.stopReason == .endTurn)
    }

    @Test func fallbackBeforeAnyOutputKeepsEverythingAfterIt() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            AnthropicSSE.messageStart(model: "claude-opus-4-8"),
            AnthropicSSE.blockStart(0, ["type": "fallback", "from": ["model": "claude-sonnet-5-5"], "to": ["model": "claude-opus-4-8"]]),
            AnthropicSSE.blockStop(0),
            AnthropicSSE.toolUseBlock(1, id: "toolu_b", name: "search_files"),
            AnthropicSSE.inputJSONDelta(1, #"{"query":"x"}"#),
            AnthropicSSE.blockStop(1),
            AnthropicSSE.messageDelta(stopReason: "tool_use"),
            AnthropicSSE.messageStop,
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.turn?.content == [.toolUse(ToolCall(id: "toolu_b", name: "search_files", input: ["query": "x"], rawInput: #"{"query":"x"}"#))])
        #expect(result.turn?.model == "claude-opus-4-8")
    }

    @Test func refusalCarriesItsCategory() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            AnthropicSSE.messageStart(),
            AnthropicSSE.textBlock(0),
            AnthropicSSE.textDelta(0, "Ich"),
            AnthropicSSE.blockStop(0),
            AnthropicSSE.messageDelta(stopReason: "refusal", stopDetails: ["type": "refusal", "category": "cyber", "explanation": "…"]),
            AnthropicSSE.messageStop,
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.turn?.stopReason == .refusal(category: "cyber"))
        #expect(result.turn?.content == [.text("Ich")])
    }

    @Test func maxTokensInsideToolInput() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            AnthropicSSE.messageStart(),
            AnthropicSSE.toolUseBlock(0, id: "toolu_m", name: "create_note"),
            AnthropicSSE.inputJSONDelta(0, #"{"title": "Einkauf", "body": "Mi"#),
            AnthropicSSE.messageDelta(stopReason: "max_tokens"),
            AnthropicSSE.messageStop,
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        let turn = try #require(result.turn)
        #expect(turn.stopReason == .maxTokens)
        #expect(result.toolCalls.count == 1)
        #expect(turn.toolCalls.first?.inputParseError == ToolCallDecoding.invalidJSONMessage)
        #expect(turn.toolCalls.first?.rawInput == #"{"title": "Einkauf", "body": "Mi"#)
    }

    @Test func streamWithoutMessageStopCompletesWhenStopReasonArrived() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            AnthropicSSE.messageStart(), AnthropicSSE.textBlock(0), AnthropicSSE.textDelta(0, "ok"),
            AnthropicSSE.messageDelta(stopReason: "end_turn"),
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.turn?.content == [.text("ok")])
        #expect(result.turn?.stopReason == .endTurn)
    }

    @Test func truncatedStreamIsAnInvalidResponse() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [AnthropicSSE.messageStart(), AnthropicSSE.textBlock(0), AnthropicSSE.textDelta(0, "o")]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        guard case .invalidResponse? = result.llmError else {
            Issue.record("Expected invalidResponse, got \(String(describing: result.error))")
            return
        }
        #expect(result.textDeltas == ["o"])
        #expect(server.requests.count == 1)
    }

    @Test func ollamaTranscriptWithThinkingAndToolCall() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [OllamaFixture.anthropicToolCall], chunkSize: 13))
        let result = await LLMTest.collect(try provider(server, ollama).stream(request("gpt-oss:20b", tools: [LLMTest.weatherTool])))
        let call = ToolCall(id: "call_5gbjmp2w", name: "get_weather", input: ["city": "Berlin"], rawInput: #"{"city":"Berlin"}"#)
        #expect(result.error == nil)
        #expect(result.startedToolCalls == ["call_5gbjmp2w/get_weather"])
        #expect(result.toolCalls == [call])
        #expect(result.progressNotes.isEmpty) // raw reasoning is never shown
        #expect(result.textDeltas.isEmpty)
        let turn = try #require(result.turn)
        #expect(turn.content == [.thinking(text: #"We need to use get_weather tool with city="Berlin"."#, signature: nil), .toolUse(call)])
        #expect(turn.stopReason == .toolUse)
        #expect(turn.model == "gpt-oss:20b")
        #expect(turn.usage == TokenUsage(inputTokens: 141, outputTokens: 36))

        // The turn goes back without a signature key.
        let echoed = AnthropicWire.encode([.user("Wetter?"), Message(role: .assistant, content: turn.content)])
        #expect(echoed[1]["content"]?[0] == ["type": "thinking", "thinking": #"We need to use get_weather tool with city="Berlin"."#])
    }

    // MARK: Errors and retries

    @Test func errorEventAfterOutputIsThrownWithoutRetry() async throws {
        let server = MockServer()
        let sleeps = SleepRecorder()
        server.enqueue(
            .sse(events: [AnthropicSSE.messageStart(), AnthropicSSE.textBlock(0), AnthropicSSE.textDelta(0, "Hallo"),
                          AnthropicSSE.error(type: "overloaded_error", message: "Overloaded")]),
            .sse(events: AnthropicSSE.textAnswer(["unused"]))
        )
        let result = await LLMTest.collect(try provider(server, sleeps: sleeps).stream(request()))
        #expect(result.llmError == .overloaded)
        #expect(result.textDeltas == ["Hallo"])
        #expect(result.turn == nil)
        #expect(server.requests.count == 1)
        #expect(sleeps.recorded.isEmpty)
    }

    @Test(arguments: [
        ("api_error", LLMError.server(status: 500)),
        ("rate_limit_error", .rateLimited(retryAfter: nil)),
        ("invalid_request_error", .streamError(type: "invalid_request_error", message: "Bad")),
    ])
    func mapsErrorEvents(type: String, expected: LLMError) async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [AnthropicSSE.messageStart(), AnthropicSSE.textBlock(0), AnthropicSSE.textDelta(0, "x"),
                                     AnthropicSSE.error(type: type, message: "Bad")]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.llmError == expected)
    }

    @Test func errorEventBeforeOutputIsRetried() async throws {
        let server = MockServer()
        let sleeps = SleepRecorder()
        server.enqueue(
            .sse(events: [AnthropicSSE.messageStart(), AnthropicSSE.error(type: "overloaded_error", message: "Overloaded")]),
            .sse(events: AnthropicSSE.textAnswer(["ok"]))
        )
        let result = await LLMTest.collect(try provider(server, sleeps: sleeps).stream(request()))
        #expect(result.text == "ok")
        #expect(server.requests.count == 2)
        #expect(sleeps.recorded == [.seconds(1)])
    }

    @Test func droppedConnectionAfterOutputIsNotRetried() async throws {
        let server = MockServer()
        // The connection drops once the provider has passed on the text, not on a timer, which a busy test run
        // can make overtake the text (the provider then rightly retries: nothing was shown yet).
        let drop = FailureGate()
        server.enqueue(
            .sse(events: [AnthropicSSE.messageStart(), AnthropicSSE.textBlock(0), AnthropicSSE.textDelta(0, "Hal")],
                 failure: .networkConnectionLost, failureGate: drop),
            .sse(events: AnthropicSSE.textAnswer(["unused"]))
        )
        // Without any text the drop comes anyway, so a broken provider fails the test instead of hanging it.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(5))
            drop.open()
        }
        defer { watchdog.cancel() }
        var result = LLMStreamResult()
        do {
            for try await event in try provider(server, ollama).stream(request("gpt-oss:20b")) {
                result.events.append(event)
                if case .textDelta = event { drop.open() }
            }
        } catch {
            result.error = error
        }
        // The server went away (e.g. Ollama restarted): not "no internet connection".
        #expect(result.llmError == .network(.connectionLost))
        #expect(result.textDeltas == ["Hal"])
        #expect(server.requests.count == 1)
    }

    @Test func blockedPlainHTTPIsNotRetried() async throws {
        let server = MockServer()
        let sleeps = SleepRecorder()
        server.enqueue(.failure(.appTransportSecurityRequiresSecureConnection), .sse(events: AnthropicSSE.textAnswer(["unused"])))
        let configuration = ProviderConfiguration(kind: .anthropic, apiKey: "k", baseURL: URL(string: "http://llm.example.com"))
        let result = await LLMTest.collect(try provider(server, configuration, sleeps: sleeps).stream(request()))
        #expect(result.llmError == .network(.insecureConnectionBlocked))
        #expect(result.events.isEmpty)
        #expect(server.requests.count == 1)
        #expect(sleeps.recorded.isEmpty)
    }

    @Test func networkFailureBeforeOutputIsRetried() async throws {
        let server = MockServer()
        let sleeps = SleepRecorder()
        server.enqueue(
            .failure(.cannotConnectToHost),
            .sse(events: [AnthropicSSE.messageStart()], failure: .networkConnectionLost),
            .sse(events: AnthropicSSE.textAnswer(["ok"]))
        )
        let result = await LLMTest.collect(try provider(server, sleeps: sleeps).stream(request()))
        #expect(result.text == "ok")
        #expect(server.requests.count == 3)
        #expect(sleeps.recorded == [.seconds(1), .seconds(3)])
    }

    @Test func persistentNetworkFailureGivesUpAfterTwoRetries() async throws {
        let server = MockServer()
        let sleeps = SleepRecorder()
        server.enqueue(.failure(.cannotConnectToHost), .failure(.cannotConnectToHost), .failure(.cannotConnectToHost))
        let result = await LLMTest.collect(try provider(server, sleeps: sleeps).stream(request()))
        #expect(result.llmError == .network(.cannotConnect))
        #expect(server.requests.count == 3)
        #expect(sleeps.recorded == [.seconds(1), .seconds(3)])
    }

    @Test(arguments: [
        (401, "authentication_error", "invalid x-api-key", LLMError.invalidAPIKey),
        (403, "permission_error", "Not allowed", .permissionDenied),
        (404, "not_found_error", "model: claude-sonnet-5-5", .modelNotFound(model: "claude-sonnet-5-5")),
        (413, "request_too_large", "Request exceeds the maximum size", .requestTooLarge),
        (400, "invalid_request_error", "prompt is too long: 210000 tokens > 200000 maximum", .contextTooLong),
        (400, "invalid_request_error", "messages: roles must alternate", .invalidRequest(message: "messages: roles must alternate")),
        (400, "invalid_request_error", "Your credit balance is too low to access the Anthropic API.", .billing),
        (402, "billing_error", "Payment required", .billing),
    ])
    func mapsHTTPErrorsWithoutRetrying(status: Int, type: String, message: String, expected: LLMError) async throws {
        let server = MockServer()
        let sleeps = SleepRecorder()
        server.enqueue(
            .json(status: status, AnthropicSSE.errorBody(type: type, message: message)),
            .sse(events: AnthropicSSE.textAnswer(["unused"]))
        )
        let result = await LLMTest.collect(try provider(server, sleeps: sleeps).stream(request()))
        #expect(result.llmError == expected)
        #expect(result.events.isEmpty)
        #expect(server.requests.count == 1)
        #expect(sleeps.recorded.isEmpty)
    }

    @Test func plainTextNotFoundMeansWrongBaseURL() async throws {
        let server = MockServer()
        server.enqueue(.text(status: 404, "404 page not found"))
        let result = await LLMTest.collect(try provider(server, ollama).stream(request("gpt-oss:20b")))
        #expect(result.llmError == .invalidBaseURL)
    }

    @Test(arguments: [
        AnthropicSSE.errorBody(type: "not_found_error", message: "Not Found"),
        #"{"detail":"Not Found"}"#,
    ])
    func unknownRouteMeansWrongBaseURL(body: String) async throws {
        let server = MockServer()
        server.enqueue(.json(status: 404, body))
        let configuration = ProviderConfiguration(kind: .anthropic, apiKey: "k", baseURL: URL(string: "https://proxy.example.com/wrong-prefix"))
        let result = await LLMTest.collect(try provider(server, configuration).stream(request()))
        #expect(result.llmError == .invalidBaseURL)
        #expect(server.requests.count == 1)
    }

    @Test func rateLimitHonorsRetryAfter() async throws {
        let server = MockServer()
        let sleeps = SleepRecorder()
        server.enqueue(
            .json(status: 429, AnthropicSSE.errorBody(type: "rate_limit_error", message: "slow down"), headers: ["retry-after": "7"]),
            .sse(events: AnthropicSSE.textAnswer(["ok"]))
        )
        let result = await LLMTest.collect(try provider(server, sleeps: sleeps).stream(request()))
        #expect(result.text == "ok")
        #expect(sleeps.recorded == [.seconds(7)])
    }

    @Test func retryAfterIsCappedAndRateLimitSurfacesWhenPersistent() async throws {
        let server = MockServer()
        let sleeps = SleepRecorder()
        let limited = MockServer.Response.json(
            status: 429, AnthropicSSE.errorBody(type: "rate_limit_error", message: "slow down"), headers: ["Retry-After": "60"]
        )
        server.enqueue(limited, limited, limited)
        let result = await LLMTest.collect(try provider(server, sleeps: sleeps).stream(request()))
        #expect(result.llmError == .rateLimited(retryAfter: 60))
        #expect(sleeps.recorded == [.seconds(20), .seconds(20)])
        #expect(server.requests.count == 3)
    }

    @Test func overloadedThenSuccessUsesBackoff() async throws {
        let server = MockServer()
        let sleeps = SleepRecorder()
        server.enqueue(
            .json(status: 529, AnthropicSSE.errorBody(type: "overloaded_error", message: "Overloaded")),
            .json(status: 503, "{}"),
            .sse(events: AnthropicSSE.textAnswer(["ok"]))
        )
        let result = await LLMTest.collect(try provider(server, sleeps: sleeps).stream(request()))
        #expect(result.text == "ok")
        #expect(sleeps.recorded == [.seconds(1), .seconds(3)])
        #expect(server.requests.count == 3)
        // Every attempt sends the same bytes.
        #expect(Set(server.requests.map(\.body)).count == 1)
    }

    @Test func persistentOverloadSurfacesAfterTwoRetries() async throws {
        let server = MockServer()
        let overloaded = MockServer.Response.json(status: 529, AnthropicSSE.errorBody(type: "overloaded_error", message: "Overloaded"))
        server.enqueue(overloaded, overloaded, overloaded, .sse(events: AnthropicSSE.textAnswer(["unused"])))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.llmError == .overloaded)
        #expect(server.requests.count == 3)
    }

    @Test func rejectedOptionalFeaturesAreRetriedWithoutAndRemembered() async throws {
        let server = MockServer()
        let memory = ProviderFeatureMemory()
        server.enqueue(
            .json(status: 400, AnthropicSSE.errorBody(
                type: "invalid_request_error",
                message: "Unexpected value(s) `thinking-display-updates-2026-08-18` for the `anthropic-beta` header."
            )),
            .sse(events: AnthropicSSE.textAnswer(["ok"])),
            .sse(events: AnthropicSSE.textAnswer(["again"])),
            .sse(events: AnthropicSSE.textAnswer(["other model"], model: "claude-opus-5-5"))
        )
        let provider = try provider(server, memory: memory)
        let request = request(tools: [LLMTest.weatherTool], effort: .low)

        let first = await LLMTest.collect(provider.stream(request))
        #expect(first.text == "ok")
        try #require(server.requests.count == 2)
        #expect(server.requests[0].headers["anthropic-beta"] != nil)
        #expect(server.requests[1].headers["anthropic-beta"] == nil)
        #expect(server.requests[1].body == AnthropicWire.requestBody(for: request, messages: request.messages, features: .none).jsonData())

        // Later requests to the same host and model leave the features out right away.
        let second = await LLMTest.collect(provider.stream(request))
        #expect(second.text == "again")
        try #require(server.requests.count == 3)
        #expect(server.requests[2].body == server.requests[1].body)
        #expect(server.requests[2].headers["anthropic-beta"] == nil)

        // Other models are not affected.
        var opus = request
        opus.model = "claude-opus-5-5"
        _ = await LLMTest.collect(provider.stream(opus))
        try #require(server.requests.count == 4)
        #expect(server.requests[3].headers["anthropic-beta"] != nil)
        #expect(memory.isDisabled(.anthropicOptionalFeatures, host: "api.anthropic.com:443", model: "claude-sonnet-5-5"))
        #expect(!memory.isDisabled(.anthropicOptionalFeatures, host: "api.anthropic.com:443", model: "claude-opus-5-5"))
    }

    @Test func featureRetryHappensOnlyOnce() async throws {
        let server = MockServer()
        let rejected = MockServer.Response.json(status: 400, AnthropicSSE.errorBody(type: "invalid_request_error", message: "output_config: Extra inputs are not permitted"))
        server.enqueue(rejected, rejected, .sse(events: AnthropicSSE.textAnswer(["unused"])))
        let result = await LLMTest.collect(try provider(server).stream(request(effort: .high)))
        #expect(result.llmError == .invalidRequest(message: "output_config: Extra inputs are not permitted"))
        #expect(server.requests.count == 2)
    }

    /// FastAPI/pydantic servers answer 422 (a few proxies 400).
    @Test(arguments: [400, 422])
    func strictCompatibleServerLosesTheSystemCacheBreakpoint(status: Int) async throws {
        let server = MockServer()
        let memory = ProviderFeatureMemory()
        server.enqueue(
            .json(status: status, #"{"detail":[{"loc":["body","system",0,"cache_control"],"msg":"Extra inputs are not permitted","type":"extra_forbidden"}]}"#),
            .sse(events: AnthropicSSE.textAnswer(["ok"], model: "qwen3")),
            .sse(events: AnthropicSSE.textAnswer(["again"], model: "qwen3"))
        )
        let configuration = ProviderConfiguration(kind: .anthropic, apiKey: "", baseURL: URL(string: "http://127.0.0.1:8080"))
        let provider = try provider(server, configuration, memory: memory)
        let first = await LLMTest.collect(provider.stream(request("qwen3")))
        #expect(first.text == "ok")
        try #require(server.requests.count == 2)
        #expect(server.requests[0].bodyJSON?["system"]?[0]?["cache_control"] != nil)
        #expect(server.requests[1].bodyJSON?["system"] == [["type": "text", "text": "You are Orbit."]])
        _ = await LLMTest.collect(provider.stream(request("qwen3")))
        try #require(server.requests.count == 3)
        #expect(server.requests[2].bodyJSON?["system"] == [["type": "text", "text": "You are Orbit."]])
        #expect(memory.isDisabled(.anthropicSystemPromptCaching, host: "127.0.0.1:8080", model: "qwen3"))
    }

    @Test func officialAPIKeepsTheSystemCacheBreakpoint() async throws {
        let server = MockServer()
        server.enqueue(
            .json(status: 400, AnthropicSSE.errorBody(type: "invalid_request_error", message: "cache_control: Extra inputs are not permitted")),
            .sse(events: AnthropicSSE.textAnswer(["ok"]))
        )
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.text == "ok")
        let retried = try #require(server.requests.last?.bodyJSON)
        #expect(retried["cache_control"] == nil)
        #expect(retried["system"]?[0]?["cache_control"] == ["type": "ephemeral"])
    }

    private static let boundThinkingMessage = "messages.1.content.0: Invalid `signature` in `thinking` block. The block is bound to a different conversation. Remove the block, or set `thinking.block_binding.prefix_mismatch_behavior` to \"drop_block\". That setting requires the `thinking-binding-controls-2026-08-01` value in the `anthropic-beta` header."

    private let historyWithThinking = [
        Message.user("Was steht an?"),
        Message(role: .assistant, content: [
            .thinking(text: "", signature: "c2lnLW9sZA=="),
            .redactedThinking(data: "b2xk"),
            .text("Drei Termine."),
        ]),
        Message.user("Und morgen?"),
    ]

    @Test func rejectedHistoryThinkingIsStrippedOnce() async throws {
        let server = MockServer()
        server.enqueue(
            .json(status: 400, AnthropicSSE.errorBody(type: "invalid_request_error", message: Self.boundThinkingMessage)),
            .sse(events: AnthropicSSE.textAnswer(["ok"]))
        )
        let result = await LLMTest.collect(try provider(server).stream(request(messages: historyWithThinking)))
        guard case .historyThinkingStripped? = result.events.first else {
            Issue.record("Expected historyThinkingStripped first, got \(result.events)")
            return
        }
        #expect(result.text == "ok")
        try #require(server.requests.count == 2)
        let retried = try #require(server.requests.last?.bodyJSON)
        #expect(retried["messages"] == JSONValue.array(AnthropicWire.encode(AnthropicWire.removingThinking(from: historyWithThinking))))
        #expect(!server.requests[1].bodyText.contains(#""type":"thinking""#))
        #expect(!server.requests[1].bodyText.contains("redacted_thinking"))
        // The message also names the anthropic-beta header, but features stay on.
        #expect(server.requests[1].headers["anthropic-beta"] != nil)
    }

    @Test func historyThinkingIsStrippedAtMostOnce() async throws {
        let server = MockServer()
        let rejected = MockServer.Response.json(status: 400, AnthropicSSE.errorBody(type: "invalid_request_error", message: Self.boundThinkingMessage))
        server.enqueue(rejected, rejected, .sse(events: AnthropicSSE.textAnswer(["unused"])))
        let result = await LLMTest.collect(try provider(server).stream(request(messages: historyWithThinking)))
        #expect(result.strippedHistoryThinking)
        #expect(result.llmError == .invalidRequest(message: Self.boundThinkingMessage))
        #expect(server.requests.count == 2)
    }

    /// A strict compatible server that requires a signature on thinking blocks
    /// (e.g. after the conversation started with Ollama's unsigned thinking).
    @Test(arguments: [400, 422])
    func compatibleServerRejectingUnsignedThinkingGetsItStripped(status: Int) async throws {
        let server = MockServer()
        server.enqueue(
            .json(status: status, #"{"detail":[{"loc":["body","messages",1,"content",0,"thinking","signature"],"msg":"Field required","type":"missing"}]}"#),
            .sse(events: AnthropicSSE.textAnswer(["ok"], model: "qwen3"))
        )
        let history = [
            Message.user("Wetter?"),
            Message(role: .assistant, content: [
                .thinking(text: "Need the tool.", signature: nil),
                .toolUse(ToolCall(id: "call_1", name: "get_weather", input: ["city": "Berlin"])),
            ]),
            Message(role: .user, content: [.toolResult(ToolResultBlock(toolCallID: "call_1", content: "18 °C"))]),
        ]
        let configuration = ProviderConfiguration(kind: .anthropic, apiKey: "", baseURL: URL(string: "http://127.0.0.1:8080"))
        let result = await LLMTest.collect(try provider(server, configuration).stream(request("qwen3", messages: history)))
        guard case .historyThinkingStripped? = result.events.first else {
            Issue.record("Expected historyThinkingStripped first, got \(result.events)")
            return
        }
        #expect(result.text == "ok")
        try #require(server.requests.count == 2)
        #expect(server.requests[0].bodyText.contains(#""type":"thinking""#))
        #expect(!server.requests[1].bodyText.contains(#""type":"thinking""#))
        #expect(server.requests[1].bodyJSON?["messages"] == .array(AnthropicWire.encode(AnthropicWire.removingThinking(from: history))))
    }

    @Test func thinkingErrorWithoutThinkingInHistoryIsNotRetried() async throws {
        let server = MockServer()
        server.enqueue(.json(status: 400, AnthropicSSE.errorBody(type: "invalid_request_error", message: "messages.0.content.0.thinking.signature: Field required")))
        let result = await LLMTest.collect(try provider(server, ollama).stream(request("gpt-oss:20b")))
        #expect(!result.strippedHistoryThinking)
        #expect(server.requests.count == 1)
        guard case .invalidRequest? = result.llmError else {
            Issue.record("Expected invalidRequest, got \(String(describing: result.error))")
            return
        }
    }

    // MARK: Cancellation

    @Test func cancellingTheConsumerCancelsTheRequest() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [AnthropicSSE.messageStart(), AnthropicSSE.textBlock(0), AnthropicSSE.textDelta(0, "Hallo")], stalls: true))
        let provider = try provider(server)
        let received = OSAllocatedUnfairLock<[LLMEvent]>(initialState: [])
        let consumer = Task {
            do {
                for try await event in provider.stream(request()) {
                    received.withLock { $0.append(event) }
                }
                return nil as (any Error)?
            } catch {
                return error
            }
        }
        #expect(await LLMTest.eventually { !received.withLock { $0.isEmpty } })
        let cancelled = ContinuousClock.now
        consumer.cancel()
        let error = await consumer.value
        #expect(cancelled.duration(to: .now) < .seconds(2))
        #expect(error == nil || (error as? LLMError) == .cancelled || error is CancellationError)
        #expect(await LLMTest.eventually { server.cancelledStalls == 1 })
        let events = received.withLock { $0 }
        #expect(!events.contains { if case .end = $0 { true } else { false } })
    }

    @Test func cancellingWhileWaitingForHeadersCancelsTheRequest() async throws {
        let server = MockServer()
        server.enqueue(.hang)
        let provider = try provider(server)
        let consumer = Task { await LLMTest.collect(provider.stream(request())) }
        #expect(await LLMTest.eventually { server.requests.count == 1 })
        let cancelled = ContinuousClock.now
        consumer.cancel()
        let result = await consumer.value
        #expect(cancelled.duration(to: .now) < .seconds(2))
        #expect(result.turn == nil)
        #expect(result.error == nil || result.llmError == .cancelled)
        #expect(await LLMTest.eventually { server.cancelledStalls == 1 })
    }

    @Test func droppingTheStreamCancelsTheRequest() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [AnthropicSSE.messageStart(), AnthropicSSE.textBlock(0), AnthropicSSE.textDelta(0, "Hallo")], stalls: true))
        let provider = try provider(server)
        for try await event in provider.stream(request()) {
            if case .textDelta = event { break }
        }
        #expect(await LLMTest.eventually { server.cancelledStalls == 1 })
    }

    // MARK: Validation and naming

    @Test func validatesAgainstTheModelRoute() async throws {
        let server = MockServer()
        server.enqueue(.json(#"{"type":"model","id":"claude-sonnet-5-5","display_name":"Claude Sonnet 5.5"}"#))
        try await provider(server).validateConfiguration(model: "claude-sonnet-5-5")
        let sent = try #require(server.requests.first)
        #expect(sent.method == "GET")
        #expect(sent.url.absoluteString == "https://api.anthropic.com/v1/models/claude-sonnet-5-5")
        #expect(sent.headers["x-api-key"] == "sk-ant-test")
        #expect(sent.headers["anthropic-version"] == "2023-06-01")
        #expect(sent.body.isEmpty)
    }

    @Test(arguments: [
        (401, "authentication_error", LLMError.invalidAPIKey),
        (404, "not_found_error", .modelNotFound(model: "claude-nope")),
        (403, "permission_error", .permissionDenied),
    ])
    func officialValidationErrors(status: Int, type: String, expected: LLMError) async throws {
        let server = MockServer()
        server.enqueue(.json(status: status, AnthropicSSE.errorBody(type: type, message: "x")), .json(#"{"data":[]}"#))
        await #expect(throws: expected) { try await provider(server).validateConfiguration(model: "claude-nope") }
        #expect(server.requests.count == 1) // no list fallback on the official API
    }

    @Test func compatibleServerFallsBackToTheModelList() async throws {
        let server = MockServer()
        server.enqueue(
            .json(status: 404, #"{"error":{"message":"model 'gpt-oss:20b' not found","type":"not_found_error"}}"#),
            .json(#"{"object":"list","data":[{"id":"gpt-oss:20b","object":"model"},{"id":"llama3.2:latest","object":"model"}]}"#),
            .json(status: 404, "{}"),
            .json(#"{"object":"list","data":[{"id":"gpt-oss:20b","object":"model"},{"id":"llama3.2:latest","object":"model"}]}"#),
            .json(status: 404, "{}"),
            .json(#"{"object":"list","data":[{"id":"gpt-oss:20b","object":"model"}]}"#)
        )
        let provider = try provider(server, ollama)
        try await provider.validateConfiguration(model: "gpt-oss:20b")
        try await provider.validateConfiguration(model: "llama3.2") // implicit ":latest"
        await #expect(throws: LLMError.modelNotFound(model: "bogus-model")) {
            try await provider.validateConfiguration(model: "bogus-model")
        }
        #expect(server.requests.map(\.url.absoluteString) == [
            "http://127.0.0.1:11434/v1/models/gpt-oss:20b", "http://127.0.0.1:11434/v1/models",
            "http://127.0.0.1:11434/v1/models/llama3.2", "http://127.0.0.1:11434/v1/models",
            "http://127.0.0.1:11434/v1/models/bogus-model", "http://127.0.0.1:11434/v1/models",
        ])
        #expect(server.requests.allSatisfy { $0.headers["x-api-key"] == nil })
    }

    @Test func serverWithoutModelRoutesIsAWrongBaseURL() async throws {
        let server = MockServer()
        server.enqueue(.text(status: 404, "404 page not found"), .text(status: 404, "404 page not found"))
        await #expect(throws: LLMError.invalidBaseURL) {
            try await provider(server, ollama).validateConfiguration(model: "gpt-oss:20b")
        }
    }

    @Test func apiWithoutModelRoutesIsAWrongBaseURL() async throws {
        let server = MockServer()
        server.enqueue(.json(status: 404, #"{"detail":"Not Found"}"#), .json(status: 404, #"{"detail":"Not Found"}"#))
        let configuration = ProviderConfiguration(kind: .anthropic, apiKey: "", baseURL: URL(string: "http://127.0.0.1:4000/proxy"))
        await #expect(throws: LLMError.invalidBaseURL) {
            try await provider(server, configuration).validateConfiguration(model: "qwen3")
        }
        #expect(server.requests.map(\.url.path) == ["/proxy/v1/models/qwen3", "/proxy/v1/models"])
    }

    @Test func modelIDsArePercentEncodedInThePath() async throws {
        let server = MockServer()
        server.enqueue(.json("{}"))
        let configuration = ProviderConfiguration(kind: .anthropic, apiKey: "k", baseURL: URL(string: "https://proxy.example.com/anthropic/"))
        try await provider(server, configuration).validateConfiguration(model: "org/model name")
        #expect(server.requests.first?.url.absoluteString == "https://proxy.example.com/anthropic/v1/models/org%2Fmodel%20name")
    }

    @Test(arguments: [
        (nil, "Claude"),
        ("https://api.anthropic.com/", "Claude"),
        ("http://127.0.0.1:11434", "das lokale Modell"),
        ("http://localhost:11434/v1", "das lokale Modell"),
        ("http://[::1]:11434", "das lokale Modell"),
        ("https://llm-proxy.example.com/anthropic", "llm-proxy.example.com"),
        // Remote hosts whose names merely start like a loopback address.
        ("https://127.gateway.example.com", "127.gateway.example.com"),
        ("https://127.0.0.1.example.net/v1", "127.0.0.1.example.net"),
    ] as [(String?, String)])
    func displayNames(base: String?, expected: String) throws {
        let configuration = ProviderConfiguration(kind: .anthropic, apiKey: "k", baseURL: base.flatMap(URL.init(string:)))
        #expect(try AnthropicProvider(configuration: configuration).displayName == expected)
    }

    @Test(arguments: ["ftp://example.com", "localhost:11434", "http://", "file:///tmp/x", "mailto:a@b.c"])
    func rejectsUnusableBaseURLs(base: String) {
        let configuration = ProviderConfiguration(kind: .anthropic, apiKey: "k", baseURL: URL(string: base))
        #expect(throws: LLMError.invalidBaseURL) { try AnthropicProvider(configuration: configuration) }
    }
}
