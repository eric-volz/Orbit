import Foundation
import Testing
@testable import Orbit

@Suite("OpenAI-compatible encoding")
struct OpenAIEncodingTests {
    @Test func mapsHistoryWithToolMessagesBeforeUserText() {
        let history = [
            Message.user("Wie ist das Wetter in Berlin?"),
            Message(role: .assistant, content: [
                .thinking(text: "Need to call the tool.", signature: nil),
                .toolUse(ToolCall(id: "call_1", name: "get_weather", input: ["city": "Berlin"], rawInput: #"{"city": "Berlin"}"#)),
            ]),
            Message(role: .user, content: [
                .text("Kontext: Montag"),
                .toolResult(ToolResultBlock(toolCallID: "call_1", content: "18 °C, sunny")),
                .toolResult(ToolResultBlock(toolCallID: "call_2", content: "Error: timeout", isError: true)),
            ]),
            Message(role: .assistant, content: [.text("In Berlin sind es 18 °C."), .opaque(["type": "x"])]),
            Message(role: .assistant, content: [.thinking(text: "only reasoning", signature: nil)]),
            Message.user("Danke"),
        ]
        let json = JSONValue.array(OpenAIWire.messages(systemPrompt: "You are Orbit.", history: history)).jsonString()
        #expect(json == #"[{"content":"You are Orbit.","role":"system"},{"content":"Wie ist das Wetter in Berlin?","role":"user"},{"content":null,"role":"assistant","tool_calls":[{"function":{"arguments":"{\"city\": \"Berlin\"}","name":"get_weather"},"id":"call_1","type":"function"}]},{"content":"18 °C, sunny","role":"tool","tool_call_id":"call_1"},{"content":"Error: timeout","role":"tool","tool_call_id":"call_2"},{"content":"Kontext: Montag","role":"user"},{"content":"In Berlin sind es 18 °C.","role":"assistant"},{"content":"Danke","role":"user"}]"#)
    }

    /// A finished tool loop, a new question, and a loop in progress whose last
    /// step also carries signed (Anthropic) thinking.
    private static let historyWithReasoning = [
        Message.user("Wie ist das Wetter in Berlin?"),
        Message(role: .assistant, content: [
            .thinking(text: "Need the weather tool.", signature: nil),
            .toolUse(ToolCall(id: "call_1", name: "get_weather", input: ["city": "Berlin"])),
        ]),
        Message(role: .user, content: [.toolResult(ToolResultBlock(toolCallID: "call_1", content: "18 °C"))]),
        Message(role: .assistant, content: [.thinking(text: "Answer now.", signature: nil), .text("18 °C.")]),
        Message.user("Und in Rom und Paris?"),
        Message(role: .assistant, content: [
            .thinking(text: "Rome first.", signature: nil),
            .toolUse(ToolCall(id: "call_2", name: "get_weather", input: ["city": "Rom"])),
        ]),
        Message(role: .user, content: [.toolResult(ToolResultBlock(toolCallID: "call_2", content: "24 °C"))]),
        Message(role: .assistant, content: [
            .thinking(text: "", signature: "c2ln"),
            .thinking(text: "Now Paris.", signature: nil),
            .thinking(text: "  \n", signature: nil),
            .text("Rom hat 24 °C."),
            .toolUse(ToolCall(id: "call_3", name: "get_weather", input: ["city": "Paris"])),
        ]),
        Message(role: .user, content: [.toolResult(ToolResultBlock(toolCallID: "call_3", content: "20 °C"))]),
    ]

    @Test func reasoningOfTheToolLoopInProgressIsEchoed() {
        #expect(OpenAIWire.reasoningToEcho(in: Self.historyWithReasoning) == [5: "Rome first.", 7: "Now Paris."])
        let json = JSONValue.array(OpenAIWire.messages(systemPrompt: "", history: Self.historyWithReasoning, reasoningEcho: .reasoning))
            .jsonString()
        #expect(json == #"[{"content":"Wie ist das Wetter in Berlin?","role":"user"},{"content":null,"role":"assistant","tool_calls":[{"function":{"arguments":"{\"city\":\"Berlin\"}","name":"get_weather"},"id":"call_1","type":"function"}]},{"content":"18 °C","role":"tool","tool_call_id":"call_1"},{"content":"18 °C.","role":"assistant"},{"content":"Und in Rom und Paris?","role":"user"},{"content":null,"reasoning":"Rome first.","role":"assistant","tool_calls":[{"function":{"arguments":"{\"city\":\"Rom\"}","name":"get_weather"},"id":"call_2","type":"function"}]},{"content":"24 °C","role":"tool","tool_call_id":"call_2"},{"content":"Rom hat 24 °C.","reasoning":"Now Paris.","role":"assistant","tool_calls":[{"function":{"arguments":"{\"city\":\"Paris\"}","name":"get_weather"},"id":"call_3","type":"function"}]},{"content":"20 °C","role":"tool","tool_call_id":"call_3"}]"#)
    }

    @Test func reasoningIsEchoedInTheServersField() throws {
        let messages = OpenAIWire.messages(systemPrompt: "", history: Self.historyWithReasoning, reasoningEcho: .reasoningContent)
        #expect(messages[5]["reasoning_content"] == "Rome first.")
        #expect(messages[5]["reasoning"] == nil)
        // Without an echo field, reasoning is never sent.
        let plain = JSONValue.array(OpenAIWire.messages(systemPrompt: "", history: Self.historyWithReasoning)).jsonString()
        #expect(!plain.contains("reasoning"))
        let body = OpenAIWire.requestBody(
            for: LLMRequest(model: "gpt-oss:20b", systemPrompt: "S", messages: Self.historyWithReasoning),
            includesReasoningEffort: false, reasoningEcho: .reasoning
        )
        #expect(body["messages"]?[6]?["reasoning"] == "Rome first.")
    }

    @Test func aNewQuestionAfterToolResultsStartsANewLoop() {
        // After a cancel, the next question is appended to the tool results.
        let history = [
            Message.user("Suche die Rechnung."),
            Message(role: .assistant, content: [
                .thinking(text: "Search first.", signature: nil),
                .toolUse(ToolCall(id: "call_a", name: "search_files", input: ["query": "Rechnung"])),
            ]),
            Message(role: .user, content: [
                .toolResult(ToolResultBlock(toolCallID: "call_a", content: "Cancelled", isError: true)),
                .text("<orbit_context>…</orbit_context>"),
                .text("Lieber die vom März."),
            ]),
            Message(role: .assistant, content: [
                .thinking(text: "Search March.", signature: nil),
                .toolUse(ToolCall(id: "call_b", name: "search_files", input: ["query": "Rechnung März"])),
            ]),
            Message(role: .user, content: [.toolResult(ToolResultBlock(toolCallID: "call_b", content: "1 file"))]),
        ]
        #expect(OpenAIWire.reasoningToEcho(in: history) == [3: "Search March."])
        #expect(OpenAIWire.reasoningToEcho(in: Array(history.prefix(3))).isEmpty)
    }

    @Test(arguments: [
        "Additional properties are not allowed ('reasoning' was unexpected) - 'messages.2'",
        "body.messages.2.reasoning: Extra inputs are not permitted",
        "Unknown parameter: 'messages[2].reasoning'.",
        "body.reasoning_effort: Extra inputs are not permitted; body.messages.2.reasoning: Extra inputs are not permitted",
    ])
    func recognizesReasoningEchoRejections(message: String) {
        #expect(OpenAIWire.rejectsReasoningEcho(message, field: .reasoning))
    }

    @Test(arguments: [
        "Unrecognized request argument supplied: reasoning_effort",
        "Invalid reasoning effort",
        "Unsupported parameter: 'reasoning_effort' is not supported with this model.",
        #""llama3.2" does not support thinking"#,
        "invalid tool call arguments",
    ])
    func otherErrorsAreNotReasoningEchoRejections(message: String) {
        #expect(!OpenAIWire.rejectsReasoningEcho(message, field: .reasoning))
        #expect(!OpenAIWire.rejectsReasoningEcho(message, field: .reasoningContent))
    }

    @Test func reasoningContentRejectionsNameTheirField() {
        let message = "The reasoning_content field of input messages is not supported."
        #expect(OpenAIWire.rejectsReasoningEcho(message, field: .reasoningContent))
        #expect(!OpenAIWire.rejectsReasoningEcho("Additional properties are not allowed ('reasoning' was unexpected)", field: .reasoningContent))
    }

    @Test func assistantTextAndToolCallsTogether() {
        let history = [Message(role: .assistant, content: [
            .text("Ich schaue nach."),
            .toolUse(ToolCall(id: "call_9", name: "list_events", input: .object([:]))),
        ])]
        let json = JSONValue.array(OpenAIWire.messages(systemPrompt: "", history: history)).jsonString()
        #expect(json == #"[{"content":"Ich schaue nach.","role":"assistant","tool_calls":[{"function":{"arguments":"{}","name":"list_events"},"id":"call_9","type":"function"}]}]"#)
    }

    @Test func fullBodyWithOptionalFields() {
        let request = LLMRequest(
            model: "gpt-oss:20b", systemPrompt: "You are Orbit.", messages: [.user("Hi")],
            tools: [LLMTest.weatherTool], maxTokens: 1024, effort: .low
        )
        #expect(OpenAIWire.requestBody(for: request, includesReasoningEffort: true).jsonString() == #"{"max_tokens":1024,"messages":[{"content":"You are Orbit.","role":"system"},{"content":"Hi","role":"user"}],"model":"gpt-oss:20b","reasoning_effort":"low","stream":true,"tools":[{"function":{"description":"Get the current weather for a city.","name":"get_weather","parameters":{"properties":{"city":{"description":"City name","type":"string"}},"required":["city"],"type":"object"}},"type":"function"}]}"#)
        #expect(OpenAIWire.requestBody(for: request, includesReasoningEffort: false).jsonString().contains("reasoning_effort") == false)
    }

    @Test func minimalBody() {
        let request = LLMRequest(model: "gpt-oss:20b", systemPrompt: "S", messages: [.user("Hi")])
        #expect(OpenAIWire.requestBody(for: request, includesReasoningEffort: true).jsonString() == #"{"messages":[{"content":"S","role":"system"},{"content":"Hi","role":"user"}],"model":"gpt-oss:20b","stream":true}"#)
    }

    @Test func toolArgumentsAreEchoedOnlyWhenValid() {
        let valid = ToolCall(id: "a", name: "x", input: ["q": "1"], rawInput: #"{ "q": "1" }"#)
        #expect(OpenAIWire.arguments(of: valid) == #"{ "q": "1" }"#)
        let invalid = ToolCall(id: "b", name: "x", rawInput: #"{"q": "#, inputParseError: ToolCallDecoding.invalidJSONMessage)
        #expect(OpenAIWire.arguments(of: invalid) == "{}")
        let empty = ToolCall(id: "c", name: "x")
        #expect(OpenAIWire.arguments(of: empty) == "{}")
        let doubleEncoded = ToolCall(id: "d", name: "x", input: ["q": "1"], rawInput: #""{\"q\":\"1\"}""#)
        #expect(OpenAIWire.arguments(of: doubleEncoded) == #"{"q":"1"}"#)
        let parsedOnly = ToolCall(id: "e", name: "x", input: ["b": 2, "a": 1])
        #expect(OpenAIWire.arguments(of: parsedOnly) == #"{"a":1,"b":2}"#)
    }

    @Test(arguments: [
        ("stop", false, StopReason.endTurn), (nil, false, .endTurn), ("tool_calls", true, .toolUse),
        ("stop", true, .toolUse), ("length", false, .maxTokens), ("length", true, .maxTokens),
        ("content_filter", false, .refusal(category: nil)), ("content_filter", true, .refusal(category: nil)),
        ("eos", false, .other("eos")),
    ] as [(String?, Bool, StopReason)])
    func mapsFinishReasons(reason: String?, hasToolCalls: Bool, expected: StopReason) {
        #expect(OpenAIWire.stopReason(reason, hasToolCalls: hasToolCalls) == expected)
    }

    @Test(arguments: [
        "Unrecognized request argument supplied: reasoning_effort",
        "Unsupported parameter: 'reasoning_effort' is not supported with this model.",
        "Unknown parameter: 'reasoning_effort'.",
        "Invalid reasoning effort",
        #""llama3.2" does not support thinking"#,
        "body.reasoning_effort: Extra inputs are not permitted",
    ])
    func recognizesReasoningEffortRejections(message: String) {
        #expect(OpenAIWire.rejectsReasoningEffort(message))
    }

    @Test(arguments: [
        "model 'x' not found",
        "Unsupported parameter: 'max_tokens' is not supported with this model. Use 'max_completion_tokens' instead.",
        "invalid tool call arguments",
    ])
    func otherErrorsAreNotReasoningEffortRejections(message: String) {
        #expect(!OpenAIWire.rejectsReasoningEffort(message))
    }
}

@Suite("OpenAI-compatible provider")
struct OpenAICompatibleProviderTests {
    private let ollama = ProviderConfiguration(kind: .openAICompatible, apiKey: "", baseURL: URL(string: "http://127.0.0.1:11434/v1"))

    private func provider(
        _ server: MockServer,
        _ configuration: ProviderConfiguration? = nil,
        sleeps: SleepRecorder = SleepRecorder(),
        memory: ProviderFeatureMemory = ProviderFeatureMemory()
    ) throws -> OpenAICompatibleProvider {
        try OpenAICompatibleProvider(configuration: configuration ?? ollama, transport: server.transport(sleeps: sleeps, memory: memory))
    }

    private func request(tools: [ToolDefinition] = [], effort: ReasoningEffort? = nil, messages: [Message] = [.user("Hallo")]) -> LLMRequest {
        LLMRequest(model: "gpt-oss:20b", systemPrompt: "You are Orbit.", messages: messages, tools: tools, effort: effort)
    }

    /// Chunks of Ollama 0.31.1 (`gpt-oss:20b`): reasoning, then a complete tool
    /// call in one chunk that also carries the finish reason.
    private static let ollamaToolCall = #"""
    data: {"id":"chatcmpl-164","object":"chat.completion.chunk","created":1790622817,"model":"gpt-oss:20b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":"Need"},"finish_reason":null}]}

    data: {"id":"chatcmpl-164","object":"chat.completion.chunk","created":1790622817,"model":"gpt-oss:20b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"","reasoning":" to call function."},"finish_reason":null}]}

    data: {"id":"chatcmpl-164","object":"chat.completion.chunk","created":1790622818,"model":"gpt-oss:20b","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":"","tool_calls":[{"id":"call_qboyy8mx","index":0,"type":"function","function":{"name":"get_weather","arguments":"{\"city\":\"Berlin\"}"}}]},"finish_reason":"tool_calls"}]}

    data: {"id":"chatcmpl-164","object":"chat.completion.chunk","created":1790622818,"model":"gpt-oss:20b","system_fingerprint":"fp_ollama","choices":[],"usage":{"prompt_tokens":141,"completion_tokens":29,"total_tokens":170}}

    data: [DONE]


    """#

    // MARK: Requests

    @Test(arguments: ["http://127.0.0.1:11434/v1", "http://127.0.0.1:11434/v1/", "http://127.0.0.1:11434/v1/chat/completions"])
    func postsToChatCompletions(base: String) async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [OpenAISSE.content("ok", finishReason: "stop"), OpenAISSE.done]))
        let configuration = ProviderConfiguration(kind: .openAICompatible, apiKey: "", baseURL: URL(string: base))
        let request = request(effort: .medium)
        let result = await LLMTest.collect(try provider(server, configuration).stream(request))
        #expect(result.text == "ok")
        let sent = try #require(server.requests.first)
        #expect(sent.method == "POST")
        #expect(sent.url.absoluteString == "http://127.0.0.1:11434/v1/chat/completions")
        #expect(sent.headers["authorization"] == nil)
        #expect(sent.headers["content-type"] == "application/json")
        #expect(sent.headers["accept"] == "text/event-stream")
        #expect(sent.body == OpenAIWire.requestBody(for: request, includesReasoningEffort: true).jsonData())
    }

    @Test func sendsBearerTokenWhenAKeyIsSet() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [OpenAISSE.content("ok", finishReason: "stop"), OpenAISSE.done]))
        let configuration = ProviderConfiguration(kind: .openAICompatible, apiKey: " sk-test \n", baseURL: URL(string: "https://api.openai.com/v1"))
        _ = await LLMTest.collect(try provider(server, configuration).stream(request()))
        #expect(server.requests.first?.headers["authorization"] == "Bearer sk-test")
        #expect(server.requests.first?.url.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test func modelIDsAreTrimmedAndMustNotBeEmpty() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [OpenAISSE.content("ok", finishReason: "stop"), OpenAISSE.done]))
        var padded = request()
        padded.model = " gpt-oss:20b\n"
        _ = await LLMTest.collect(try provider(server).stream(padded))
        #expect(server.requests.first?.bodyJSON?["model"] == "gpt-oss:20b")

        var empty = request()
        empty.model = "  "
        let result = await LLMTest.collect(try provider(server).stream(empty))
        #expect(result.llmError == .modelNotFound(model: ""))
        #expect(server.requests.count == 1)
    }

    // MARK: Stream decoding

    @Test(arguments: [1, 9, 4096])
    func streamsContentUntilDone(chunkSize: Int) async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            OpenAISSE.content("Grü"), OpenAISSE.content("ße "), OpenAISSE.content("👋", finishReason: "stop"),
            OpenAISSE.usage(prompt: 20, completion: 3, cached: 5), OpenAISSE.done,
        ], chunkSize: chunkSize))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.error == nil)
        #expect(result.textDeltas == ["Grü", "ße ", "👋"])
        let turn = try #require(result.turn)
        #expect(turn.content == [.text("Grüße 👋")])
        #expect(turn.stopReason == .endTurn)
        #expect(turn.model == "gpt-oss:20b")
        #expect(turn.usage == TokenUsage(inputTokens: 15, outputTokens: 3, cacheReadInputTokens: 5))
    }

    @Test func reasoningIsKeptButNeverShown() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            OpenAISSE.reasoning("Need"),
            OpenAISSE.reasoning(" to think."),
            OpenAISSE.chunk(["content": "", "reasoning_content": " More."]),
            OpenAISSE.content("Antwort", finishReason: "stop"),
            OpenAISSE.done,
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.textDeltas == ["Antwort"])
        #expect(result.progressNotes.isEmpty)
        #expect(result.turn?.content == [.thinking(text: "Need to think. More.", signature: nil), .text("Antwort")])
    }

    @Test func toolCallsSplitAcrossChunksByIndex() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            OpenAISSE.toolCall(index: 0, id: "call_a", name: "get_weather", arguments: ""),
            OpenAISSE.toolCall(index: 1, id: "call_b", name: "get_time", arguments: #"{"tz":"#),
            OpenAISSE.toolCall(index: 0, arguments: #"{"city":"#),
            OpenAISSE.toolCall(index: 0, arguments: #""Berlin"}"#),
            OpenAISSE.toolCall(index: 1, arguments: #""CET"}"#),
            OpenAISSE.finish("tool_calls"),
            OpenAISSE.done,
        ], chunkSize: 16))
        let result = await LLMTest.collect(try provider(server).stream(request(tools: [LLMTest.weatherTool])))
        let weather = ToolCall(id: "call_a", name: "get_weather", input: ["city": "Berlin"], rawInput: #"{"city":"Berlin"}"#)
        let time = ToolCall(id: "call_b", name: "get_time", input: ["tz": "CET"], rawInput: #"{"tz":"CET"}"#)
        #expect(result.startedToolCalls == ["call_a/get_weather", "call_b/get_time"])
        #expect(result.toolCalls == [weather, time])
        #expect(result.turn?.content == [.toolUse(weather), .toolUse(time)])
        #expect(result.turn?.stopReason == .toolUse)
    }

    @Test func completeToolCallsWithoutIndexInSeparateChunks() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            OpenAISSE.toolCall(index: nil, id: "call_a", name: "get_weather", arguments: #"{"city":"Rom"}"#),
            OpenAISSE.toolCall(index: nil, id: "call_b", name: "get_time", arguments: #"{"tz":"CET"}"#),
            OpenAISSE.finish("tool_calls"),
            OpenAISSE.done,
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        let weather = ToolCall(id: "call_a", name: "get_weather", input: ["city": "Rom"], rawInput: #"{"city":"Rom"}"#)
        let time = ToolCall(id: "call_b", name: "get_time", input: ["tz": "CET"], rawInput: #"{"tz":"CET"}"#)
        #expect(result.startedToolCalls == ["call_a/get_weather", "call_b/get_time"])
        #expect(result.toolCalls == [weather, time])
        #expect(result.turn?.content == [.toolUse(weather), .toolUse(time)])
    }

    @Test func reusedIndexWithANewIDStartsANewCall() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            OpenAISSE.toolCall(index: 0, id: "call_a", name: "get_weather", arguments: #"{"city":"#),
            OpenAISSE.toolCall(index: 0, arguments: #""Rom"}"#),
            OpenAISSE.toolCall(index: 0, id: "call_b", name: "get_time", arguments: #"{"tz":"#),
            OpenAISSE.toolCall(index: 0, arguments: #""CET"}"#),
            OpenAISSE.finish("tool_calls"),
            OpenAISSE.done,
        ], chunkSize: 19))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.toolCalls == [
            ToolCall(id: "call_a", name: "get_weather", input: ["city": "Rom"], rawInput: #"{"city":"Rom"}"#),
            ToolCall(id: "call_b", name: "get_time", input: ["tz": "CET"], rawInput: #"{"tz":"CET"}"#),
        ])
    }

    @Test func fragmentsWithoutIndexContinueTheirCall() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            OpenAISSE.toolCall(index: nil, id: "call_a", name: "get_weather", arguments: #"{"ci"#),
            OpenAISSE.toolCall(index: nil, arguments: #"ty":"#),
            OpenAISSE.toolCall(index: nil, arguments: #""Rom"}"#),
            OpenAISSE.finish("tool_calls"),
            OpenAISSE.done,
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.toolCalls == [ToolCall(id: "call_a", name: "get_weather", input: ["city": "Rom"], rawInput: #"{"city":"Rom"}"#)])
    }

    @Test func callsWithoutIndexOrIDToTheSameFunction() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            OpenAISSE.toolCall(index: nil, name: "get_weather", arguments: #"{"city":"Rom"}"#),
            OpenAISSE.toolCall(index: nil, name: "get_weather", arguments: #"{"city":"Paris"}"#),
            OpenAISSE.finish("tool_calls"),
            OpenAISSE.done,
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.toolCalls.map(\.input) == [["city": "Rom"], ["city": "Paris"]])
        #expect(result.toolCalls.allSatisfy { $0.inputParseError == nil && $0.id.hasPrefix("call_") })
        #expect(Set(result.toolCalls.map(\.id)).count == 2)
    }

    /// Some servers repeat the id and name in every fragment of a call.
    @Test func repeatedNameAndIDInEveryFragmentIsOneCall() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            OpenAISSE.toolCall(index: 0, id: "call_a", name: "get_weather", arguments: #"{"city":"#),
            OpenAISSE.toolCall(index: 0, id: "call_a", name: "get_weather", arguments: #""Rom"}"#),
            OpenAISSE.toolCall(index: 0, id: "call_a", name: "get_weather", arguments: ""),
            OpenAISSE.toolCall(index: nil, name: "get_time", arguments: #"{"tz":"#),
            OpenAISSE.toolCall(index: nil, name: "get_time", arguments: #""CET"}"#),
            OpenAISSE.toolCall(index: nil, name: "get_time", arguments: " "),
            OpenAISSE.finish("tool_calls"),
            OpenAISSE.done,
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.toolCalls.map(\.name) == ["get_weather", "get_time"])
        #expect(result.toolCalls.map(\.input) == [["city": "Rom"], ["tz": "CET"]])
        #expect(result.startedToolCalls.first == "call_a/get_weather")
    }

    @Test func severalCallsWithoutIndexInOneChunk() async throws {
        let server = MockServer()
        let calls: JSONValue = [
            OpenAISSE.toolCallDelta(index: nil, id: "call_a", name: "get_weather", arguments: #"{"city":"Rom"}"#),
            OpenAISSE.toolCallDelta(index: nil, name: "get_time", arguments: #"{"tz":"CET"}"#),
        ]
        server.enqueue(.sse(events: [OpenAISSE.chunk(["role": "assistant", "tool_calls": calls], finishReason: "tool_calls"), OpenAISSE.done]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.toolCalls.map(\.name) == ["get_weather", "get_time"])
        #expect(result.toolCalls.map(\.input) == [["city": "Rom"], ["tz": "CET"]])
    }

    @Test func ollamaToolCallTranscript() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [Self.ollamaToolCall], chunkSize: 23))
        let result = await LLMTest.collect(try provider(server).stream(request(tools: [LLMTest.weatherTool], effort: .low)))
        let call = ToolCall(id: "call_qboyy8mx", name: "get_weather", input: ["city": "Berlin"], rawInput: #"{"city":"Berlin"}"#)
        #expect(result.error == nil)
        #expect(result.startedToolCalls == ["call_qboyy8mx/get_weather"])
        #expect(result.toolCalls == [call])
        #expect(result.textDeltas.isEmpty)
        let turn = try #require(result.turn)
        #expect(turn.content == [.thinking(text: "Need to call function.", signature: nil), .toolUse(call)])
        #expect(turn.stopReason == .toolUse)
        #expect(turn.usage == TokenUsage(inputTokens: 141, outputTokens: 29))
    }

    @Test func toolCallsWinOverAStopFinishReason() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            OpenAISSE.toolCall(index: 0, id: "call_s", name: "get_weather", arguments: #"{"city":"Rom"}"#),
            OpenAISSE.finish("stop"),
            OpenAISSE.done,
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.turn?.stopReason == .toolUse)
    }

    @Test func toolArgumentsThatAreEmptyOrInvalid() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            OpenAISSE.toolCall(index: 0, id: "call_e", name: "list_shortcuts", arguments: ""),
            OpenAISSE.toolCall(index: 1, id: "call_i", name: "get_weather", arguments: #"{"city": "Ber"#),
            OpenAISSE.finish("tool_calls"),
            OpenAISSE.done,
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.toolCalls == [
            ToolCall(id: "call_e", name: "list_shortcuts", input: .object([:])),
            ToolCall(id: "call_i", name: "get_weather", rawInput: #"{"city": "Ber"#, inputParseError: ToolCallDecoding.invalidJSONMessage),
        ])
    }

    @Test func toolCallsWithoutIDsGetOne() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [
            OpenAISSE.toolCall(index: 0, name: "get_weather", arguments: #"{"city":"Rom"}"#),
            OpenAISSE.finish("tool_calls"),
            OpenAISSE.done,
        ]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        let call = try #require(result.toolCalls.first)
        #expect(call.id.hasPrefix("call_") && call.id.count > 10)
        #expect(result.startedToolCalls == ["\(call.id)/get_weather"])
    }

    @Test func streamWithoutDoneCompletesWhenAFinishReasonArrived() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [OpenAISSE.content("ok", finishReason: "length")]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.turn?.stopReason == .maxTokens)
        #expect(result.turn?.content == [.text("ok")])
    }

    @Test func truncatedStreamIsAnInvalidResponse() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [OpenAISSE.content("o")]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        guard case .invalidResponse? = result.llmError else {
            Issue.record("Expected invalidResponse, got \(String(describing: result.error))")
            return
        }
        #expect(server.requests.count == 1)
    }

    @Test func errorObjectInsideTheStream() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [OpenAISSE.content("Hi"), #"data: {"error":{"message":"boom","type":"server_error","code":null}}"# + "\n\n"]))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.llmError == .server(status: 500))
        #expect(result.textDeltas == ["Hi"])
        #expect(server.requests.count == 1)

        let plain = MockServer()
        plain.enqueue(.sse(events: [OpenAISSE.content("Hi"), #"data: {"error":"model runner crashed"}"# + "\n\n"]))
        let crashed = await LLMTest.collect(try provider(plain).stream(request()))
        #expect(crashed.llmError == .streamError(type: "error", message: "model runner crashed"))
    }

    // MARK: HTTP errors and retries

    @Test func rejectedReasoningEffortIsRetriedWithoutAndRemembered() async throws {
        let server = MockServer()
        let memory = ProviderFeatureMemory()
        server.enqueue(
            .json(status: 400, #"{"error":{"message":"Unrecognized request argument supplied: reasoning_effort","type":"invalid_request_error","param":null,"code":null}}"#),
            .sse(events: [OpenAISSE.content("ok", finishReason: "stop"), OpenAISSE.done]),
            .sse(events: [OpenAISSE.content("again", finishReason: "stop"), OpenAISSE.done])
        )
        let provider = try provider(server, memory: memory)
        let request = request(effort: .high)
        let first = await LLMTest.collect(provider.stream(request))
        #expect(first.text == "ok")
        try #require(server.requests.count == 2)
        #expect(server.requests[0].bodyJSON?["reasoning_effort"] == "high")
        #expect(server.requests[1].bodyJSON?["reasoning_effort"] == nil)

        let second = await LLMTest.collect(provider.stream(request))
        #expect(second.text == "again")
        try #require(server.requests.count == 3)
        #expect(server.requests[2].bodyJSON?["reasoning_effort"] == nil)
        #expect(memory.isDisabled(.openAIReasoningEffort, host: "127.0.0.1:11434", model: "gpt-oss:20b"))
    }

    @Test func validationErrorAboutReasoningEffortIsRetriedWithout() async throws {
        let server = MockServer()
        server.enqueue(
            .json(status: 422, #"{"detail":[{"loc":["body","reasoning_effort"],"msg":"Extra inputs are not permitted","type":"extra_forbidden"}]}"#),
            .sse(events: [OpenAISSE.content("ok", finishReason: "stop"), OpenAISSE.done])
        )
        let result = await LLMTest.collect(try provider(server).stream(request(effort: .low)))
        #expect(result.text == "ok")
        try #require(server.requests.count == 2)
        #expect(server.requests[1].bodyJSON?["reasoning_effort"] == nil)
    }

    // MARK: Reasoning echo

    /// The first turn of the Ollama transcript, with its tool result.
    private func historyAfterOllamaToolCall(_ turn: AssistantTurn) -> [Message] {
        [
            .user("Hallo"),
            Message(role: .assistant, content: turn.content, model: turn.model),
            Message(role: .user, content: [.toolResult(ToolResultBlock(toolCallID: turn.toolCalls.first?.id ?? "", content: "18 °C"))]),
        ]
    }

    @Test func reasoningOfTheToolLoopGoesBackToTheServer() async throws {
        let server = MockServer()
        let memory = ProviderFeatureMemory()
        server.enqueue(
            .sse(events: [Self.ollamaToolCall]),
            .sse(events: [OpenAISSE.content("18 °C in Berlin.", finishReason: "stop"), OpenAISSE.done])
        )
        let provider = try provider(server, memory: memory)
        let first = await LLMTest.collect(provider.stream(request(tools: [LLMTest.weatherTool], effort: .low)))
        let turn = try #require(first.turn)
        #expect(memory.reasoningField(host: "127.0.0.1:11434", model: "gpt-oss:20b") == .reasoning)

        let second = await LLMTest.collect(provider.stream(request(tools: [LLMTest.weatherTool], effort: .low,
                                                                   messages: historyAfterOllamaToolCall(turn))))
        #expect(second.text == "18 °C in Berlin.")
        let sent = try #require(server.requests.last?.bodyJSON)
        #expect(sent["messages"]?[2]?["reasoning"] == "Need to call function.")
        #expect(sent["messages"]?[2]?["tool_calls"]?[0]?["id"] == "call_qboyy8mx")
        #expect(sent["reasoning_effort"] == "low")
    }

    @Test func reasoningContentServersGetItBackInTheirField() async throws {
        let server = MockServer()
        let memory = ProviderFeatureMemory()
        server.enqueue(
            .sse(events: [
                OpenAISSE.reasoningContent("Use the tool."),
                OpenAISSE.toolCall(index: 0, id: "call_d", name: "get_weather", arguments: #"{"city":"Rom"}"#),
                OpenAISSE.finish("tool_calls"), OpenAISSE.done,
            ]),
            .sse(events: [OpenAISSE.content("24 °C.", finishReason: "stop"), OpenAISSE.done])
        )
        let provider = try provider(server, memory: memory)
        let turn = try #require(await LLMTest.collect(provider.stream(request())).turn)
        #expect(turn.content.first == .thinking(text: "Use the tool.", signature: nil))
        _ = await LLMTest.collect(provider.stream(request(messages: historyAfterOllamaToolCall(turn))))
        let assistant = try #require(server.requests.last?.bodyJSON?["messages"]?[2])
        #expect(assistant["reasoning_content"] == "Use the tool.")
        #expect(assistant["reasoning"] == nil)
    }

    @Test(arguments: [
        MockServer.Response.json(status: 400, #"{"error":{"message":"Additional properties are not allowed ('reasoning' was unexpected) - 'messages.2'","type":"invalid_request_error","param":null,"code":null}}"#),
        .json(status: 422, #"{"detail":[{"loc":["body","messages",2,"reasoning"],"msg":"Extra inputs are not permitted","type":"extra_forbidden"}]}"#),
    ])
    func rejectedReasoningEchoIsRetriedWithoutAndRemembered(rejection: MockServer.Response) async throws {
        let server = MockServer()
        let memory = ProviderFeatureMemory()
        let ok = MockServer.Response.sse(events: [OpenAISSE.content("ok", finishReason: "stop"), OpenAISSE.done])
        server.enqueue(rejection, ok, ok)
        let provider = try provider(server, memory: memory)
        let history = historyWithLoopReasoning
        let first = await LLMTest.collect(provider.stream(request(effort: .medium, messages: history)))
        #expect(first.text == "ok")
        try #require(server.requests.count == 2)
        #expect(server.requests[0].bodyJSON?["messages"]?[2]?["reasoning"] == "Look it up.")
        #expect(server.requests[1].bodyJSON?["messages"]?[2]?["reasoning"] == nil)
        // Only the echo was dropped.
        #expect(server.requests[1].bodyJSON?["reasoning_effort"] == "medium")
        #expect(memory.isDisabled(.openAIReasoningEcho, host: "127.0.0.1:11434", model: "gpt-oss:20b"))
        #expect(!memory.isDisabled(.openAIReasoningEffort, host: "127.0.0.1:11434", model: "gpt-oss:20b"))

        _ = await LLMTest.collect(provider.stream(request(effort: .medium, messages: history)))
        try #require(server.requests.count == 3)
        #expect(server.requests[2].body == server.requests[1].body)
    }

    @Test func oneRejectionOfEchoAndEffortDropsBoth() async throws {
        let server = MockServer()
        server.enqueue(
            .json(status: 422, #"{"detail":[{"loc":["body","reasoning_effort"],"msg":"Extra inputs are not permitted"},{"loc":["body","messages",2,"reasoning"],"msg":"Extra inputs are not permitted"}]}"#),
            .sse(events: [OpenAISSE.content("ok", finishReason: "stop"), OpenAISSE.done])
        )
        let result = await LLMTest.collect(try provider(server).stream(request(effort: .low, messages: historyWithLoopReasoning)))
        #expect(result.text == "ok")
        #expect(server.requests.count == 2)
        let retried = try #require(server.requests.last?.bodyJSON)
        #expect(retried["reasoning_effort"] == nil)
        #expect(retried["messages"]?[2]?["reasoning"] == nil)
    }

    @Test func effortRejectionKeepsTheEcho() async throws {
        let server = MockServer()
        let memory = ProviderFeatureMemory()
        server.enqueue(
            .json(status: 400, #"{"error":{"message":"Unrecognized request argument supplied: reasoning_effort","type":"invalid_request_error"}}"#),
            .sse(events: [OpenAISSE.content("ok", finishReason: "stop"), OpenAISSE.done])
        )
        let result = await LLMTest.collect(try provider(server, memory: memory).stream(request(effort: .high, messages: historyWithLoopReasoning)))
        #expect(result.text == "ok")
        let retried = try #require(server.requests.last?.bodyJSON)
        #expect(retried["reasoning_effort"] == nil)
        #expect(retried["messages"]?[2]?["reasoning"] == "Look it up.")
        #expect(!memory.isDisabled(.openAIReasoningEcho, host: "127.0.0.1:11434", model: "gpt-oss:20b"))
    }

    @Test func unexplainedRejectionIsRetriedOnceWithoutTheEcho() async throws {
        let server = MockServer()
        let memory = ProviderFeatureMemory()
        server.enqueue(
            .json(status: 400, #"{"error":{"message":"Bad Request"}}"#),
            .sse(events: [OpenAISSE.content("ok", finishReason: "stop"), OpenAISSE.done])
        )
        let result = await LLMTest.collect(try provider(server, memory: memory).stream(request(effort: .low, messages: historyWithLoopReasoning)))
        #expect(result.text == "ok")
        try #require(server.requests.count == 2)
        #expect(server.requests[0].bodyJSON?["messages"]?[2]?["reasoning"] == "Look it up.")
        #expect(server.requests[1].bodyJSON?["messages"]?[2]?["reasoning"] == nil)
        #expect(server.requests[1].bodyJSON?["reasoning_effort"] == "low")
        #expect(memory.isDisabled(.openAIReasoningEcho, host: "127.0.0.1:11434", model: "gpt-oss:20b"))
    }

    @Test func persistentUnexplainedRejectionIsNotBlamedOnTheEcho() async throws {
        let server = MockServer()
        let memory = ProviderFeatureMemory()
        let rejected = MockServer.Response.json(status: 400, #"{"error":{"message":"Bad Request"}}"#)
        server.enqueue(rejected, rejected, .sse(events: [OpenAISSE.content("unused", finishReason: "stop"), OpenAISSE.done]))
        let result = await LLMTest.collect(try provider(server, memory: memory).stream(request(messages: historyWithLoopReasoning)))
        #expect(result.llmError == .invalidRequest(message: "Bad Request"))
        #expect(server.requests.count == 2)
        #expect(!memory.isDisabled(.openAIReasoningEcho, host: "127.0.0.1:11434", model: "gpt-oss:20b"))
    }

    @Test func classifiedErrorsAreNotRetriedWithoutTheEcho() async throws {
        let server = MockServer()
        server.enqueue(.json(status: 400, #"{"error":{"message":"This model's maximum context length is 8192 tokens.","code":"context_length_exceeded"}}"#))
        let result = await LLMTest.collect(try provider(server).stream(request(messages: historyWithLoopReasoning)))
        #expect(result.llmError == .contextTooLong)
        #expect(server.requests.count == 1)
    }

    @Test func reasoningErrorWithoutAnEchoIsNotBlamedOnIt() async throws {
        let server = MockServer()
        let memory = ProviderFeatureMemory()
        server.enqueue(.json(status: 400, #"{"error":{"message":"Additional properties are not allowed ('reasoning' was unexpected)"}}"#))
        // A new question: nothing to echo, no effort to drop.
        let result = await LLMTest.collect(try provider(server, memory: memory).stream(request()))
        guard case .invalidRequest? = result.llmError else {
            Issue.record("Expected invalidRequest, got \(String(describing: result.error))")
            return
        }
        #expect(server.requests.count == 1)
        #expect(!memory.isDisabled(.openAIReasoningEcho, host: "127.0.0.1:11434", model: "gpt-oss:20b"))
    }

    private let historyWithLoopReasoning = [
        Message.user("Wetter in Rom?"),
        Message(role: .assistant, content: [
            .thinking(text: "Look it up.", signature: nil),
            .toolUse(ToolCall(id: "call_r", name: "get_weather", input: ["city": "Rom"])),
        ]),
        Message(role: .user, content: [.toolResult(ToolResultBlock(toolCallID: "call_r", content: "24 °C"))]),
    ]

    @Test func requestsWithoutEffortAreNeverRetriedForIt() async throws {
        let server = MockServer()
        server.enqueue(.json(status: 400, #"{"error":{"message":"\"llama3.2\" does not support thinking"}}"#))
        let result = await LLMTest.collect(try provider(server).stream(request()))
        #expect(result.llmError == .invalidRequest(message: #""llama3.2" does not support thinking"#))
        #expect(server.requests.count == 1)
    }

    @Test func unrelatedBadRequestIsNotRetried() async throws {
        let server = MockServer()
        server.enqueue(
            .json(status: 400, #"{"error":{"message":"invalid tool call arguments","type":"invalid_request_error"}}"#),
            .sse(events: [OpenAISSE.content("unused", finishReason: "stop"), OpenAISSE.done])
        )
        let result = await LLMTest.collect(try provider(server).stream(request(effort: .low)))
        #expect(result.llmError == .invalidRequest(message: "invalid tool call arguments"))
        #expect(server.requests.count == 1)
    }

    @Test(arguments: [
        // Without a key (as for Ollama): the server wants one.
        (401, #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}"#, LLMError.missingAPIKey),
        (404, #"{"error":{"message":"model 'nope' not found","type":"not_found_error"}}"#, .modelNotFound(model: "gpt-oss:20b")),
        (404, "404 page not found", .invalidBaseURL),
        // OpenAI with a base URL that lacks /v1.
        (404, #"{"error":{"message":"Invalid URL (POST /chat/completions)","type":"invalid_request_error","param":null,"code":null}}"#, .invalidBaseURL),
        (404, #"{"error":"Unexpected endpoint or method. (POST /chat/completions)"}"#, .invalidBaseURL),
        (429, #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details.","type":"insufficient_quota","code":"insufficient_quota"}}"#, .billing),
        (400, #"{"error":{"message":"This model's maximum context length is 8192 tokens.","type":"invalid_request_error","code":"context_length_exceeded"}}"#, .contextTooLong),
    ])
    func mapsHTTPErrorsWithoutRetrying(status: Int, body: String, expected: LLMError) async throws {
        let server = MockServer()
        let sleeps = SleepRecorder()
        server.enqueue(body.hasPrefix("{") ? .json(status: status, body) : .text(status: status, body))
        let result = await LLMTest.collect(try provider(server, sleeps: sleeps).stream(request()))
        #expect(result.llmError == expected)
        #expect(server.requests.count == 1)
        #expect(sleeps.recorded.isEmpty)
    }

    @Test func serverErrorsBeforeOutputAreRetried() async throws {
        let server = MockServer()
        let sleeps = SleepRecorder()
        server.enqueue(
            .text(status: 502, "Bad Gateway"),
            .json(status: 429, #"{"error":{"message":"Rate limit reached","type":"rate_limit_exceeded"}}"#, headers: ["retry-after-ms": "1500"]),
            .sse(events: [OpenAISSE.content("ok", finishReason: "stop"), OpenAISSE.done])
        )
        let result = await LLMTest.collect(try provider(server, sleeps: sleeps).stream(request()))
        #expect(result.text == "ok")
        #expect(sleeps.recorded == [.seconds(1), .milliseconds(1500)])
    }

    @Test func cancellingTheConsumerCancelsTheRequest() async throws {
        let server = MockServer()
        server.enqueue(.sse(events: [OpenAISSE.content("Hallo")], stalls: true))
        let provider = try provider(server)
        for try await event in provider.stream(request()) {
            if case .textDelta = event { break }
        }
        #expect(await LLMTest.eventually { server.cancelledStalls == 1 })
    }

    // MARK: Validation and naming

    @Test func validatesAgainstTheModelList() async throws {
        let server = MockServer()
        let list = #"{"object":"list","data":[{"id":"gpt-oss:20b","object":"model","created":1790445925,"owned_by":"library"},{"id":"qwen3:latest","object":"model"}]}"#
        let withTools = #"{"capabilities":["completion","tools","thinking"]}"#
        server.enqueue(.json(list), .json(withTools), .json(list), .json(withTools), .json(list), .json(list))
        let provider = try provider(server)
        try await provider.validateConfiguration(model: "gpt-oss:20b")
        try await provider.validateConfiguration(model: "qwen3")
        try await provider.validateConfiguration(model: "")
        await #expect(throws: LLMError.modelNotFound(model: "bogus")) {
            try await provider.validateConfiguration(model: "bogus")
        }
        let sent = try #require(server.requests.first)
        #expect(sent.method == "GET")
        #expect(sent.url.absoluteString == "http://127.0.0.1:11434/v1/models")
        #expect(sent.headers["accept"] == "application/json")
        #expect(server.requests.map(\.method) == ["GET", "POST", "GET", "POST", "GET", "GET"],
                "Ollama is asked about tools for a listed model only")
    }

    /// A model that is installed but cannot use tools (Ollama: gemma3) fails the
    /// connection test as every request would, asked through Ollama's model
    /// information, which loads no model and spends no tokens. An answer without
    /// a list of capabilities (another server, an older Ollama) says nothing.
    @Test func aModelWithoutToolsFailsTheConnectionTest() async throws {
        let server = MockServer()
        let list = #"{"object":"list","data":[{"id":"gemma3:4b","object":"model"},{"id":"gpt-oss:20b","object":"model"}]}"#
        server.enqueue(.json(list), .json(#"{"details":{"family":"gemma3"},"capabilities":["completion","vision"]}"#))
        await #expect(throws: LLMError.toolsNotSupported(model: "gemma3:4b")) {
            try await provider(server).validateConfiguration(model: "gemma3:4b")
        }
        #expect(server.requests.map { "\($0.method) \($0.url.absoluteString)" }
                == ["GET http://127.0.0.1:11434/v1/models", "POST http://127.0.0.1:11434/api/show"])
        #expect(server.requests.last?.bodyJSON == ["model": "gemma3:4b"])

        server.enqueue(.json(list), .json(#"{"capabilities":["completion","tools","thinking"]}"#),
                       .json(list), .json(status: 404, #"{"error":"model 'gpt-oss:20b' not found"}"#),
                       .json(list), .json(#"{"error":"Unexpected endpoint or method. (POST /api/show)"}"#))
        for _ in 0..<3 {
            try await provider(server).validateConfiguration(model: "gpt-oss:20b")
        }
        #expect(server.requests.count == 8)
    }

    /// Ollama answers beside its OpenAI-compatible `/v1`; other addresses are not asked.
    @Test func onlyOllamaStyleAddressesAreAskedAboutTools() async throws {
        func show(_ base: String) throws -> String? {
            OpenAICompatibleProvider.ollamaShowURL(for: try #require(URL(string: base)))?.absoluteString
        }
        #expect(try show("http://localhost:11434/v1") == "http://localhost:11434/api/show")
        #expect(try show("https://gpu.example.com/ollama/V1") == "https://gpu.example.com/ollama/api/show")
        #expect(try show("http://localhost:8080/openai") == nil)
        let remote = MockServer()
        remote.enqueue(.json(#"{"data":[{"id":"gpt-5"}]}"#))
        try await OpenAICompatibleProvider(
            configuration: ProviderConfiguration(kind: .openAICompatible, apiKey: "sk-test", baseURL: URL(string: "https://llm.example.com/openai")),
            transport: remote.transport()
        ).validateConfiguration(model: "gpt-5")
        #expect(remote.requests.count == 1)
    }

    @Test func unreadableModelListStillValidates() async throws {
        let server = MockServer()
        server.enqueue(.json(#"{"status":"ok"}"#))
        try await provider(server).validateConfiguration(model: "anything")
    }

    @Test(arguments: [
        (401, #"{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}"#, LLMError.missingAPIKey),
        (404, "404 page not found", .invalidBaseURL),
        (404, #"{"error":{"message":"Invalid URL (GET /models)","type":"invalid_request_error","param":null,"code":null}}"#, .invalidBaseURL),
        (404, #"{"detail":"Not Found"}"#, .invalidBaseURL),
    ])
    func validationErrors(status: Int, body: String, expected: LLMError) async throws {
        let server = MockServer()
        server.enqueue(body.hasPrefix("{") ? .json(status: status, body) : .text(status: status, body))
        await #expect(throws: expected) { try await provider(server).validateConfiguration(model: "gpt-oss:20b") }
    }

    @Test func unreachableServer() async throws {
        let server = MockServer()
        server.enqueue(.failure(.cannotConnectToHost))
        await #expect(throws: LLMError.network(.cannotConnect)) { try await provider(server).validateConfiguration(model: "gpt-oss:20b") }
    }

    @Test(arguments: [
        (nil, "das lokale Modell"),
        ("http://localhost:1234/v1", "das lokale Modell"),
        ("http://127.0.0.1:11434/v1", "das lokale Modell"),
        ("https://api.openai.com/v1", "api.openai.com"),
        ("http://192.168.1.20:11434/v1", "192.168.1.20"),
        ("https://127.gateway.example.com/v1", "127.gateway.example.com"),
        ("https://127.0.0.1.example.net/v1", "127.0.0.1.example.net"),
    ] as [(String?, String)])
    func displayNames(base: String?, expected: String) throws {
        let configuration = ProviderConfiguration(kind: .openAICompatible, apiKey: "", baseURL: base.flatMap(URL.init(string:)))
        #expect(try OpenAICompatibleProvider(configuration: configuration).displayName == expected)
    }
}
