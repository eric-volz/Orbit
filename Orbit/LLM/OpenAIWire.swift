import Foundation

/// The message field in which an OpenAI-compatible server streams the model's
/// reasoning (`delta.reasoning` / `delta.reasoning_content`) and reads it back.
enum OpenAIReasoningField: String, Sendable, Hashable, CaseIterable {
    /// Ollama, LM Studio, OpenRouter, newer vLLM.
    case reasoning
    /// DeepSeek, llama.cpp, SGLang, older vLLM.
    case reasoningContent = "reasoning_content"
}

/// Request encoding for Chat Completions (OpenAI and compatible servers).
/// Bodies are built as `JSONValue` and serialized deterministically.
enum OpenAIWire {
    /// `reasoningEcho`: the field that carries the reasoning of the tool loop in
    /// progress back to the model (see `reasoningToEcho(in:)`); nil sends none.
    static func requestBody(
        for request: LLMRequest,
        includesReasoningEffort: Bool,
        reasoningEcho: OpenAIReasoningField? = nil
    ) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "stream": .bool(true),
            "messages": .array(messages(systemPrompt: request.systemPrompt, history: request.messages,
                                        reasoningEcho: reasoningEcho)),
        ]
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map(encode))
        }
        if let maxTokens = request.maxTokens {
            body["max_tokens"] = .number(Double(maxTokens))
        }
        if includesReasoningEffort, let effort = request.effort {
            body["reasoning_effort"] = .string(effort.rawValue)
        }
        return .object(body)
    }

    static func encode(_ tool: ToolDefinition) -> JSONValue {
        .object([
            "type": "function",
            "function": .object([
                "name": .string(tool.name),
                "description": .string(tool.description),
                "parameters": tool.inputSchema,
            ]),
        ])
    }

    /// The system prompt followed by the mapped history. Tool results of a user
    /// message become `tool` messages placed before the message's text.
    /// Provider-specific blocks are not sent, and reasoning only in the
    /// `reasoningEcho` field of the tool loop's assistant messages.
    static func messages(
        systemPrompt: String,
        history: [Message],
        reasoningEcho: OpenAIReasoningField? = nil
    ) -> [JSONValue] {
        var result: [JSONValue] = []
        if !systemPrompt.isEmpty {
            result.append(.object(["role": "system", "content": .string(systemPrompt)]))
        }
        let echoedReasoning = reasoningEcho == nil ? [:] : reasoningToEcho(in: history)
        for (index, message) in history.enumerated() {
            let text = visibleText(of: message)
            switch message.role {
            case .user:
                for toolResult in message.toolResults {
                    result.append(.object([
                        "role": "tool",
                        "tool_call_id": .string(toolResult.toolCallID),
                        "content": .string(toolResult.content),
                    ]))
                }
                if !text.isEmpty {
                    result.append(.object(["role": "user", "content": .string(text)]))
                }
            case .assistant:
                let calls = message.toolCalls
                guard !text.isEmpty || !calls.isEmpty else { continue }
                var object: [String: JSONValue] = [
                    "role": "assistant",
                    "content": text.isEmpty ? .null : .string(text),
                ]
                if !calls.isEmpty {
                    object["tool_calls"] = .array(calls.map { call in
                        .object([
                            "id": .string(call.id),
                            "type": "function",
                            "function": .object(["name": .string(call.name), "arguments": .string(arguments(of: call))]),
                        ])
                    })
                }
                if let reasoningEcho, let reasoning = echoedReasoning[index] {
                    object[reasoningEcho.rawValue] = .string(reasoning)
                }
                result.append(.object(object))
            }
        }
        return result
    }

    /// The reasoning to send back, by history index: that of the assistant
    /// messages with tool calls after the last user message with text, i.e. of
    /// the tool loop in progress. Reasoning models such as gpt-oss expect it
    /// there and leave it out for finished turns. Signed thinking comes from
    /// Anthropic and is never sent to other servers.
    static func reasoningToEcho(in history: [Message]) -> [Int: String] {
        let loopStart = history.lastIndex { $0.role == .user && !visibleText(of: $0).isEmpty } ?? -1
        var result: [Int: String] = [:]
        for index in history.indices where index > loopStart {
            let message = history[index]
            guard message.role == .assistant, !message.toolCalls.isEmpty else { continue }
            let reasoning = message.content.compactMap { block -> String? in
                guard case .thinking(let text, .none) = block, text.contains(where: { !$0.isWhitespace }) else {
                    return nil
                }
                return text
            }
            if !reasoning.isEmpty {
                result[index] = reasoning.joined(separator: "\n\n")
            }
        }
        return result
    }

    /// The argument text of a tool call in the history. The raw text is echoed
    /// as the model wrote it, but only when it is a JSON object: servers such as
    /// Ollama reject a history with invalid or empty arguments (HTTP 400), which
    /// would break the whole conversation.
    static func arguments(of call: ToolCall) -> String {
        if call.inputParseError == nil, let raw = call.rawInput, (try? JSONValue.parse(raw))?.objectValue != nil {
            return raw
        }
        return (call.input.objectValue != nil ? call.input : .object([:])).jsonString()
    }

    static func stopReason(_ finishReason: String?, hasToolCalls: Bool) -> StopReason {
        if finishReason == "content_filter" { return .refusal(category: nil) }
        // A tool call cut off by the length limit has incomplete arguments: never run it.
        if finishReason == "length" { return .maxTokens }
        if hasToolCalls { return .toolUse }
        switch finishReason {
        case nil, "stop", "tool_calls", "function_call": return .endTurn
        case "length": return .maxTokens
        case let other?: return .other(other)
        }
    }

    /// Maps an error object sent inside the stream.
    static func streamError(_ error: JSONValue) -> LLMError {
        let message = error["message"]?.stringValue ?? error.stringValue ?? ""
        let type = error["type"]?.stringValue ?? error["code"]?.stringValue ?? "error"
        switch type {
        case "rate_limit_error", "rate_limit_exceeded": return .rateLimited(retryAfter: nil)
        case "overloaded_error", "overloaded": return .overloaded
        case "server_error", "api_error", "internal_error": return .server(status: 500)
        default: return .streamError(type: type, message: message)
        }
    }

    /// Whether a 400/422 says the server does not accept `reasoning_effort`, e.g.
    /// "Unrecognized request argument supplied: reasoning_effort", or Ollama's
    /// "\"llama3.2\" does not support thinking" for models without reasoning.
    static func rejectsReasoningEffort(_ message: String) -> Bool {
        let message = message.lowercased()
        return ["reasoning", "thinking", "unknown parameter", "unrecognized request argument"]
            .contains { message.contains($0) }
    }

    /// Whether a 400/422 is about the reasoning echoed in `field`, e.g. OpenAI's
    /// "Additional properties are not allowed ('reasoning' was unexpected)" or
    /// "body.messages.2.reasoning: Extra inputs are not permitted". Mentions of
    /// `reasoning_effort` do not count.
    static func rejectsReasoningEcho(_ message: String, field: OpenAIReasoningField) -> Bool {
        var message = message.lowercased()
        for effort in ["reasoning_effort", "reasoning effort", "reasoning.effort"] {
            message = message.replacingOccurrences(of: effort, with: " ")
        }
        return message.contains(field.rawValue)
    }

    /// Whether an error about the echoed reasoning also names `reasoning_effort`.
    static func mentionsReasoningEffort(_ message: String) -> Bool {
        message.lowercased().contains("effort")
    }

    private static func visibleText(of message: Message) -> String {
        message.content.compactMap { block -> String? in
            guard case .text(let text) = block,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }.joined(separator: "\n\n")
    }
}

/// Turns a Chat Completions chunk stream into `LLMEvent`s and, at `[DONE]`, the
/// finished `AssistantTurn`.
struct OpenAIStreamDecoder {
    private struct PendingToolCall {
        var id: String?
        var name: String?
        var arguments = ""
        var isAnnounced = false

        /// Whether a delta with these values continues this call. It starts
        /// another call instead when it carries a different id, or a function
        /// name (sent when a call starts) that differs or follows complete
        /// arguments.
        func accepts(id: String?, name: String?, fragment: String) -> Bool {
            if let id, let current = self.id { return id == current }
            guard let name, let current = self.name else { return true }
            return name == current && !(fragment.contains { !$0.isWhitespace } && hasCompleteArguments)
        }

        /// Whether `arguments` already form a complete JSON value, so no further
        /// fragment can belong to them.
        private var hasCompleteArguments: Bool {
            let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.last == "}" || trimmed.last == "\"" else { return false }
            return (try? JSONValue.parse(trimmed)) != nil
        }
    }

    private(set) var isFinished = false
    /// The field this response streamed its reasoning in; nil without reasoning.
    private(set) var reasoningField: OpenAIReasoningField?
    private var model: String?
    private var text = ""
    /// Reasoning of reasoning models (`delta.reasoning` / `reasoning_content`).
    /// Kept in the history as a thinking block, never shown to the user.
    private var reasoning = ""
    /// Tool calls in the order they started.
    private var toolCalls: [PendingToolCall] = []
    /// A stream `index` → position in `toolCalls` of the call it continues.
    private var toolCallPositions: [Int: Int] = [:]
    private var finishReason: String?
    private var usage: TokenUsage?

    init() {}

    /// Consumes one SSE event. Throws `LLMError` for error objects and malformed chunks.
    mutating func consume(_ event: SSEEvent) throws -> [LLMEvent] {
        guard !isFinished else { return [] }
        let data = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if data == "[DONE]" { return finish() }
        guard !data.isEmpty else { return [] }
        let chunk: JSONValue
        do {
            chunk = try JSONValue.parse(data)
        } catch {
            throw LLMError.invalidResponse(detail: "Malformed stream chunk")
        }
        if let error = chunk["error"], !error.isNull {
            throw OpenAIWire.streamError(error)
        }
        if model == nil, let name = chunk["model"]?.stringValue, !name.isEmpty {
            model = name
        }
        mergeUsage(chunk["usage"])
        guard let choice = chunk["choices"]?[0] else { return [] }

        var events: [LLMEvent] = []
        if let delta = choice["delta"] {
            let fragment = Self.textContent(delta["content"])
            if !fragment.isEmpty {
                text += fragment
                events.append(.textDelta(fragment))
            }
            // Some servers send both fields (with the same text) or an empty one.
            for field in OpenAIReasoningField.allCases {
                guard let thought = delta[field.rawValue]?.stringValue, !thought.isEmpty else { continue }
                reasoning += thought
                reasoningField = reasoningField ?? field
                break
            }
            for (position, call) in (delta["tool_calls"]?.arrayValue ?? []).enumerated() {
                events += mergeToolCall(call, position: position)
            }
        }
        if let reason = choice["finish_reason"]?.stringValue {
            finishReason = reason
        }
        return events
    }

    /// Called when the body ended. A stream without `[DONE]` is complete when a
    /// finish reason arrived; otherwise the response is incomplete.
    mutating func finishAtEndOfStream() throws -> [LLMEvent] {
        guard !isFinished else { return [] }
        guard finishReason != nil else {
            throw LLMError.invalidResponse(detail: "The stream ended before the response was complete")
        }
        return finish()
    }

    // MARK: Private

    /// Adds one element of a delta's `tool_calls`; `position` is its place in
    /// that array.
    private mutating func mergeToolCall(_ call: JSONValue, position: Int) -> [LLMEvent] {
        let id = call["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let function = call["function"]
        let name = function?["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let fragment = switch function?["arguments"] {
        case .string(let text)?: text
        // Some servers send the arguments as an object instead of JSON text.
        case .object(let object)?: JSONValue.object(object).jsonString()
        default: ""
        }
        let slot = toolCallSlot(index: WireNumber.int(call["index"]), id: id, name: name, fragment: fragment,
                                position: position)
        if toolCalls[slot].id == nil { toolCalls[slot].id = id }
        if toolCalls[slot].name == nil { toolCalls[slot].name = name }
        toolCalls[slot].arguments += fragment
        let pending = toolCalls[slot]
        guard !pending.isAnnounced, let id = pending.id, let name = pending.name else { return [] }
        toolCalls[slot].isAnnounced = true
        return [.toolCallStarted(id: id, name: name)]
    }

    /// The position in `toolCalls` of the call a delta belongs to; appends a
    /// call when the delta starts one. Calls are identified by `index`, but some
    /// servers omit it or reuse index 0 for every call: a delta that clearly
    /// starts another call (see `PendingToolCall.accepts`) gets a new one
    /// instead of corrupting the previous call's arguments.
    private mutating func toolCallSlot(index: Int?, id: String?, name: String?, fragment: String, position: Int) -> Int {
        if let index {
            if let slot = toolCallPositions[index], toolCalls[slot].accepts(id: id, name: name, fragment: fragment) {
                return slot
            }
            let slot = appendToolCall()
            toolCallPositions[index] = slot
            return slot
        }
        // Without an index, a known id names the call. Otherwise the first
        // element of a delta continues the latest call (fragments of one call)
        // unless it starts another one; later elements are always new calls.
        if let id, let slot = toolCalls.firstIndex(where: { $0.id == id }) {
            return slot
        }
        if position == 0, let last = toolCalls.indices.last, toolCalls[last].accepts(id: id, name: name, fragment: fragment) {
            return last
        }
        return appendToolCall()
    }

    private mutating func appendToolCall() -> Int {
        toolCalls.append(PendingToolCall())
        return toolCalls.count - 1
    }

    private mutating func finish() -> [LLMEvent] {
        isFinished = true
        var events: [LLMEvent] = []
        var calls: [ToolCall] = []
        for pending in toolCalls {
            guard pending.name != nil || !pending.arguments.isEmpty else { continue }
            // Some servers send no ids; the history needs one to pair results.
            let id = pending.id ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
            let name = pending.name ?? ""
            if !pending.isAnnounced {
                events.append(.toolCallStarted(id: id, name: name))
            }
            let call = ToolCallDecoding.toolCall(id: id, name: name, arguments: pending.arguments)
            events.append(.toolCall(call))
            calls.append(call)
        }

        var content: [ContentBlock] = []
        if !reasoning.isEmpty {
            content.append(.thinking(text: reasoning, signature: nil))
        }
        if !text.isEmpty {
            content.append(.text(text))
        }
        content += calls.map(ContentBlock.toolUse)
        let turn = AssistantTurn(
            content: content,
            stopReason: OpenAIWire.stopReason(finishReason, hasToolCalls: !calls.isEmpty),
            model: model,
            usage: usage
        )
        return events + [.end(turn)]
    }

    /// `usage` chunks. Cached prompt tokens are reported separately, as Anthropic does.
    private mutating func mergeUsage(_ json: JSONValue?) {
        guard let json, json.objectValue != nil else { return }
        let prompt = WireNumber.count(json["prompt_tokens"]) ?? 0
        let cached = min(WireNumber.count(json["prompt_tokens_details"]?["cached_tokens"]) ?? 0, prompt)
        usage = TokenUsage(
            inputTokens: prompt - cached,
            outputTokens: WireNumber.count(json["completion_tokens"]) ?? 0,
            cacheReadInputTokens: cached
        )
    }

    /// `delta.content` is a string, or with some servers an array of text parts.
    private static func textContent(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text)?:
            text
        case .array(let parts)?:
            parts.compactMap { $0["text"]?.stringValue ?? $0.stringValue }.joined()
        default:
            ""
        }
    }
}
