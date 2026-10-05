import Foundation
import Testing
@testable import Orbit

/// Everything a provider stream produced.
struct LLMStreamResult {
    var events: [LLMEvent] = []
    var error: (any Error)?

    var llmError: LLMError? { error as? LLMError }

    var textDeltas: [String] {
        events.compactMap { if case .textDelta(let text) = $0 { text } else { nil } }
    }

    var text: String { textDeltas.joined() }

    var progressNotes: [String] {
        events.compactMap { if case .progressNote(let note) = $0 { note } else { nil } }
    }

    /// "id/name" of every `.toolCallStarted`.
    var startedToolCalls: [String] {
        events.compactMap { if case .toolCallStarted(let id, let name) = $0 { "\(id)/\(name)" } else { nil } }
    }

    var toolCalls: [ToolCall] {
        events.compactMap { if case .toolCall(let call) = $0 { call } else { nil } }
    }

    var strippedHistoryThinking: Bool {
        events.contains { if case .historyThinkingStripped = $0 { true } else { false } }
    }

    /// The finished turn; only set when `.end` was the last event.
    var turn: AssistantTurn? {
        if case .end(let turn)? = events.last { return turn }
        return nil
    }

    /// Number of `.end` events (must be at most one).
    var endCount: Int {
        events.filter { if case .end = $0 { true } else { false } }.count
    }
}

/// Helpers of the LLM tests (namespaced to avoid clashes in the test module).
enum LLMTest {
    static func collect(_ stream: AsyncThrowingStream<LLMEvent, Error>) async -> LLMStreamResult {
        var result = LLMStreamResult()
        do {
            for try await event in stream {
                result.events.append(event)
            }
        } catch {
            result.error = error
        }
        return result
    }

    /// Splits text into byte chunks of `size`, deliberately cutting through lines,
    /// CRLF pairs and multi-byte UTF-8 characters.
    static func byteChunks(_ text: String, size: Int) -> [Data] {
        let bytes = Array(text.utf8)
        return stride(from: 0, to: bytes.count, by: size).map { start in
            Data(bytes[start..<min(start + size, bytes.count)])
        }
    }

    /// Polls `condition` until it holds or `timeout` passed.
    static func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    static let weatherTool = ToolDefinition(
        name: "get_weather",
        description: "Get the current weather for a city.",
        inputSchema: [
            "type": "object",
            "properties": ["city": ["type": "string", "description": "City name"]],
            "required": ["city"],
        ]
    )
}

extension MockServer.Response {
    /// SSE events delivered in chunks of `chunkSize` bytes. With `failure`, the
    /// connection drops after them, once `failureGate` opens, if given.
    static func sse(events: [String], chunkSize: Int? = nil, stalls: Bool = false, failure: URLError.Code? = nil,
                    failureGate: FailureGate? = nil) -> Self {
        let text = events.joined()
        let chunks = chunkSize.map { LLMTest.byteChunks(text, size: $0) } ?? [Data(text.utf8)]
        return MockServer.Response(chunks: chunks, stalls: stalls, failure: failure, failureGate: failureGate)
    }
}

/// Builders for Anthropic Messages API stream events.
enum AnthropicSSE {
    static func event(_ name: String, _ payload: JSONValue) -> String {
        "event: \(name)\ndata: \(payload.jsonString())\n\n"
    }

    static func messageStart(
        model: String = "claude-sonnet-5-5",
        inputTokens: Int = 12,
        cacheRead: Int = 0,
        cacheCreation: Int = 0
    ) -> String {
        event("message_start", [
            "type": "message_start",
            "message": [
                "id": "msg_test", "type": "message", "role": "assistant", "model": .string(model),
                "content": [], "stop_reason": nil,
                "usage": [
                    "input_tokens": .number(Double(inputTokens)), "output_tokens": 1,
                    "cache_read_input_tokens": .number(Double(cacheRead)),
                    "cache_creation_input_tokens": .number(Double(cacheCreation)),
                ],
            ],
        ])
    }

    static func blockStart(_ index: Int, _ block: JSONValue) -> String {
        event("content_block_start", ["type": "content_block_start", "index": .number(Double(index)), "content_block": block])
    }

    static func textBlock(_ index: Int) -> String {
        blockStart(index, ["type": "text", "text": ""])
    }

    static func thinkingBlock(_ index: Int) -> String {
        blockStart(index, ["type": "thinking", "thinking": "", "signature": ""])
    }

    static func toolUseBlock(_ index: Int, id: String, name: String) -> String {
        blockStart(index, ["type": "tool_use", "id": .string(id), "name": .string(name), "input": [:]])
    }

    static func delta(_ index: Int, _ delta: JSONValue) -> String {
        event("content_block_delta", ["type": "content_block_delta", "index": .number(Double(index)), "delta": delta])
    }

    static func textDelta(_ index: Int, _ text: String) -> String {
        delta(index, ["type": "text_delta", "text": .string(text)])
    }

    static func thinkingDelta(_ index: Int, _ text: String) -> String {
        delta(index, ["type": "thinking_delta", "thinking": .string(text)])
    }

    static func signatureDelta(_ index: Int, _ signature: String) -> String {
        delta(index, ["type": "signature_delta", "signature": .string(signature)])
    }

    static func inputJSONDelta(_ index: Int, _ json: String) -> String {
        delta(index, ["type": "input_json_delta", "partial_json": .string(json)])
    }

    static func blockStop(_ index: Int) -> String {
        event("content_block_stop", ["type": "content_block_stop", "index": .number(Double(index))])
    }

    static func messageDelta(stopReason: String, outputTokens: Int = 7, stopDetails: JSONValue? = nil) -> String {
        var delta: [String: JSONValue] = ["stop_reason": .string(stopReason), "stop_sequence": nil]
        if let stopDetails { delta["stop_details"] = stopDetails }
        return event("message_delta", [
            "type": "message_delta", "delta": .object(delta), "usage": ["output_tokens": .number(Double(outputTokens))],
        ])
    }

    static let messageStop = event("message_stop", ["type": "message_stop"])
    static let ping = event("ping", ["type": "ping"])

    static func error(type: String, message: String) -> String {
        event("error", ["type": "error", "error": ["type": .string(type), "message": .string(message)]])
    }

    /// A complete text-only answer.
    static func textAnswer(_ parts: [String], model: String = "claude-sonnet-5-5") -> [String] {
        [messageStart(model: model), textBlock(0)] + parts.map { textDelta(0, $0) }
            + [blockStop(0), messageDelta(stopReason: "end_turn"), messageStop]
    }

    /// An API error body.
    static func errorBody(type: String, message: String) -> String {
        JSONValue.object([
            "type": "error", "error": ["type": .string(type), "message": .string(message)], "request_id": "req_test",
        ]).jsonString()
    }
}

/// Builders for Chat Completions stream chunks.
enum OpenAISSE {
    static func chunk(_ delta: JSONValue, finishReason: String? = nil, model: String = "gpt-oss:20b") -> String {
        let choice: JSONValue = [
            "index": 0, "delta": delta, "finish_reason": finishReason.map(JSONValue.string) ?? .null,
        ]
        let payload: JSONValue = [
            "id": "chatcmpl-1", "object": "chat.completion.chunk", "created": 1_790_622_817,
            "model": .string(model), "choices": [choice],
        ]
        return "data: \(payload.jsonString())\n\n"
    }

    static func content(_ text: String, finishReason: String? = nil) -> String {
        chunk(["role": "assistant", "content": .string(text)], finishReason: finishReason)
    }

    static func reasoning(_ text: String) -> String {
        chunk(["role": "assistant", "content": "", "reasoning": .string(text)])
    }

    /// One tool-call delta; `index: nil` leaves the index out (as some servers do).
    static func toolCall(index: Int?, id: String? = nil, name: String? = nil, arguments: String? = nil) -> String {
        chunk(["role": "assistant", "tool_calls": [toolCallDelta(index: index, id: id, name: name, arguments: arguments)]])
    }

    static func toolCallDelta(index: Int?, id: String? = nil, name: String? = nil, arguments: String? = nil) -> JSONValue {
        var function: [String: JSONValue] = [:]
        if let name { function["name"] = .string(name) }
        if let arguments { function["arguments"] = .string(arguments) }
        var call: [String: JSONValue] = ["function": .object(function)]
        if let index { call["index"] = .number(Double(index)) }
        if let id {
            call["id"] = .string(id)
            call["type"] = "function"
        }
        return .object(call)
    }

    /// Reasoning in `reasoning_content` (DeepSeek, llama.cpp) instead of `reasoning`.
    static func reasoningContent(_ text: String) -> String {
        chunk(["role": "assistant", "content": "", "reasoning_content": .string(text)])
    }

    static func finish(_ reason: String) -> String {
        chunk(["role": "assistant", "content": ""], finishReason: reason)
    }

    static func usage(prompt: Int, completion: Int, cached: Int = 0) -> String {
        let payload: JSONValue = [
            "id": "chatcmpl-1", "object": "chat.completion.chunk", "model": "gpt-oss:20b", "choices": [],
            "usage": [
                "prompt_tokens": .number(Double(prompt)), "completion_tokens": .number(Double(completion)),
                "total_tokens": .number(Double(prompt + completion)),
                "prompt_tokens_details": ["cached_tokens": .number(Double(cached))],
            ],
        ]
        return "data: \(payload.jsonString())\n\n"
    }

    static let done = "data: [DONE]\n\n"
}

/// A real transcript of Ollama 0.31.1 (`gpt-oss:20b`) on its Anthropic-compatible
/// endpoint: thinking without signature, then a tool call.
enum OllamaFixture {
    static let anthropicToolCall = #"""
    event: message_start
    data: {"type":"message_start","message":{"id":"msg_11372c75d419c83f0e5c2452","type":"message","role":"assistant","model":"gpt-oss:20b","content":[],"usage":{"input_tokens":46,"output_tokens":0}}}

    event: content_block_start
    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"We"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" need"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" to"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" use"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" get"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"_weather"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" tool"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" with"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":" city"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"=\""}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Berlin"}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"\"."}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":0}

    event: content_block_start
    data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"call_5gbjmp2w","name":"get_weather","input":{}}}

    event: content_block_delta
    data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"Berlin\"}"}}

    event: content_block_stop
    data: {"type":"content_block_stop","index":1}

    event: message_delta
    data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"input_tokens":141,"output_tokens":36}}

    event: message_stop
    data: {"type":"message_stop"}


    """#
}
