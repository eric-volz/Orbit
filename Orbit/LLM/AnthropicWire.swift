import Foundation

/// Optional features of a Messages API request. The beta features and automatic
/// caching are only sent to the official API; proxies and compatible servers
/// such as Ollama get none of them.
struct AnthropicFeatures: Sendable, Hashable {
    /// Top-level `cache_control`: automatic caching of the growing conversation.
    var automaticCaching = false
    /// `eager_input_streaming: true` on every tool definition.
    var eagerInputStreaming = false
    /// `thinking: {type: adaptive, display: updates}` (beta): thinking blocks with
    /// text are short progress notes.
    var progressUpdates = false
    /// `fallbacks: "default"` (beta): server-side fallback after a refusal.
    var refusalFallback = false
    /// `output_config.effort`.
    var effort: ReasoningEffort?

    static let none = AnthropicFeatures()

    /// The features a request gets unless the endpoint rejected them before.
    static func `for`(model: String, effort: ReasoningEffort?, officialAPI: Bool) -> AnthropicFeatures {
        var features = AnthropicFeatures()
        if officialAPI {
            features.automaticCaching = true
            features.eagerInputStreaming = true
            features.progressUpdates = AnthropicModelSupport.progressUpdateModels.contains(model)
            features.refusalFallback = AnthropicModelSupport.refusalFallbackModels.contains(model)
        }
        if AnthropicModelSupport.supportsEffort(model) {
            features.effort = effort
        }
        return features
    }

    /// The `anthropic-beta` header value; nil when no beta feature is used.
    var betaHeader: String? {
        var betas: [String] = []
        if refusalFallback { betas.append(AnthropicWire.refusalFallbackBeta) }
        if progressUpdates { betas.append(AnthropicWire.progressUpdatesBeta) }
        return betas.isEmpty ? nil : betas.joined(separator: ",")
    }
}

/// Which Claude models support which optional features.
enum AnthropicModelSupport {
    /// `thinking.display: "updates"` (not Claude Mythos 5, Opus 5 or Sonnet 5).
    static let progressUpdateModels: Set<String> = [
        "claude-sonnet-5-5", "claude-opus-5-5", "claude-fable-5", "claude-fable-5-1", "claude-mythos-5-1",
    ]
    /// `fallbacks: "default"`: the models with refusal classifiers that accept
    /// it (Claude Mythos 5 runs no classifiers).
    static let refusalFallbackModels: Set<String> = [
        "claude-sonnet-5-5", "claude-opus-5-5", "claude-opus-5", "claude-fable-5", "claude-fable-5-1",
        "claude-mythos-5-1",
    ]
    private static let effortModelPrefixes = [
        "claude-sonnet-5", "claude-opus-5", "claude-fable-", "claude-mythos-",
        "claude-opus-4-5", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-4-6",
    ]

    /// Models that accept `output_config.effort`. Non-Claude models served by
    /// compatible servers (e.g. `gpt-oss:20b`) never get it.
    static func supportsEffort(_ model: String) -> Bool {
        effortModelPrefixes.contains { model.hasPrefix($0) }
    }
}

/// Request encoding for the Messages API. Bodies are built as `JSONValue` and
/// serialized deterministically, so a conversation's earlier turns go out
/// byte-identical on every request (prompt caching, thinking signatures).
enum AnthropicWire {
    static let apiVersion = "2023-06-01"
    static let defaultMaxTokens = 32_000
    static let refusalFallbackBeta = "server-side-fallback-2026-07-01"
    static let progressUpdatesBeta = "thinking-display-updates-2026-08-18"
    /// Text of a progress block that stands in for interrupted work; it is not a
    /// progress note.
    static let interruptedWorkNote = "This part of the response was interrupted before it finished."

    /// The request body. `messages` replaces `request.messages` (e.g. after
    /// thinking blocks were stripped). The system prompt carries a cache
    /// breakpoint unless `cachesSystemPrompt` is false (for compatible servers
    /// that rejected it).
    static func requestBody(
        for request: LLMRequest,
        messages: [Message],
        features: AnthropicFeatures,
        cachesSystemPrompt: Bool = true
    ) -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "max_tokens": .number(Double(request.maxTokens ?? defaultMaxTokens)),
            "stream": .bool(true),
            "messages": .array(encode(messages)),
        ]
        if !request.systemPrompt.isEmpty {
            var system: [String: JSONValue] = ["type": "text", "text": .string(request.systemPrompt)]
            if cachesSystemPrompt {
                system["cache_control"] = .object(["type": "ephemeral"])
            }
            body["system"] = .array([.object(system)])
        }
        if !request.tools.isEmpty {
            body["tools"] = .array(request.tools.map { encode($0, eagerInputStreaming: features.eagerInputStreaming) })
        }
        if features.automaticCaching {
            body["cache_control"] = .object(["type": "ephemeral"])
        }
        if features.progressUpdates {
            body["thinking"] = .object(["type": "adaptive", "display": "updates"])
        }
        if features.refusalFallback {
            body["fallbacks"] = "default"
        }
        if let effort = features.effort {
            body["output_config"] = .object(["effort": .string(effort.rawValue)])
        }
        return .object(body)
    }

    static func encode(_ tool: ToolDefinition, eagerInputStreaming: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(tool.name),
            "description": .string(tool.description),
            "input_schema": tool.inputSchema,
        ]
        if eagerInputStreaming {
            object["eager_input_streaming"] = .bool(true)
        }
        return .object(object)
    }

    /// Encodes the history. Defensive normalizations (all deterministic, so the
    /// same history always yields the same bytes): blocks with nothing to send
    /// are skipped, messages left empty are dropped, consecutive messages of the
    /// same role are merged, and `tool_result` blocks lead their user message, as
    /// the API requires.
    static func encode(_ messages: [Message]) -> [JSONValue] {
        var merged: [(role: MessageRole, toolResults: [JSONValue], others: [JSONValue])] = []
        for message in messages {
            var toolResults: [JSONValue] = []
            var others: [JSONValue] = []
            for block in message.content {
                guard let json = encode(block) else { continue }
                if message.role == .user, block.isToolResult {
                    toolResults.append(json)
                } else {
                    others.append(json)
                }
            }
            guard !toolResults.isEmpty || !others.isEmpty else { continue }
            if let last = merged.last, last.role == message.role {
                merged[merged.count - 1].toolResults += toolResults
                merged[merged.count - 1].others += others
            } else {
                merged.append((message.role, toolResults, others))
            }
        }
        return merged.map { message in
            .object([
                "role": .string(message.role.rawValue),
                "content": .array(message.toolResults + message.others),
            ])
        }
    }

    /// One content block; nil when there is nothing to send.
    static func encode(_ block: ContentBlock) -> JSONValue? {
        switch block {
        case .text(let text):
            // The API rejects empty and whitespace-only text blocks.
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return .object(["type": "text", "text": .string(text)])
        case .thinking(let text, let signature):
            guard !text.isEmpty || signature != nil else { return nil }
            var object: [String: JSONValue] = ["type": "thinking", "thinking": .string(text)]
            if let signature {
                object["signature"] = .string(signature)
            }
            return .object(object)
        case .redactedThinking(let data):
            return .object(["type": "redacted_thinking", "data": .string(data)])
        case .toolUse(let call):
            return .object([
                "type": "tool_use",
                "id": .string(call.id),
                "name": .string(call.name),
                "input": call.input.objectValue != nil ? call.input : .object([:]),
            ])
        case .toolResult(let result):
            var object: [String: JSONValue] = [
                "type": "tool_result",
                "tool_use_id": .string(result.toolCallID),
                "content": .string(result.content),
            ]
            if result.isError {
                object["is_error"] = .bool(true)
            }
            return .object(object)
        case .opaque(let value):
            return value
        }
    }

    /// Whether the history contains blocks that `removingThinking` would drop.
    static func containsThinking(_ messages: [Message]) -> Bool {
        messages.contains { $0.content.contains(where: \.isThinking) }
    }

    /// The history without `.thinking` / `.redactedThinking` blocks.
    static func removingThinking(from messages: [Message]) -> [Message] {
        messages.map { message in
            var message = message
            message.content.removeAll(where: \.isThinking)
            return message
        }
    }

    static func stopReason(_ raw: String, category: String?) -> StopReason {
        switch raw {
        case "end_turn": .endTurn
        case "tool_use": .toolUse
        case "max_tokens": .maxTokens
        case "stop_sequence": .stopSequence
        case "refusal": .refusal(category: category)
        case "model_context_window_exceeded": .contextWindowExceeded
        default: .other(raw)
        }
    }

    /// Maps an `error` event of the stream.
    static func streamError(_ error: JSONValue?) -> LLMError {
        let type = error?["type"]?.stringValue ?? "unknown_error"
        switch type {
        case "overloaded_error": return .overloaded
        case "rate_limit_error": return .rateLimited(retryAfter: nil)
        case "api_error": return .server(status: 500)
        default: return .streamError(type: type, message: error?["message"]?.stringValue ?? "")
        }
    }

    /// Whether a 400/422 says a thinking block of the history is not accepted
    /// (edited history on models with preserved thinking, a foreign or missing
    /// signature). Checked before `rejectsOptionalFeature`: its message also
    /// names the `anthropic-beta` header.
    static func rejectsHistoryThinking(_ message: String) -> Bool {
        let message = message.lowercased()
        return message.contains("bound to a different conversation")
            || (message.contains("thinking") && message.contains("signature"))
    }

    /// Whether a 400/422 is about one of the optional request features.
    static func rejectsOptionalFeature(_ message: String) -> Bool {
        let message = message.lowercased()
        return ["anthropic-beta", "fallbacks", "display", "eager_input_streaming", "output_config", "effort",
                "cache_control"].contains { message.contains($0) }
    }
}

private extension ContentBlock {
    var isThinking: Bool {
        switch self {
        case .thinking, .redactedThinking: true
        default: false
        }
    }

    var isToolResult: Bool {
        if case .toolResult = self { return true }
        return false
    }
}

/// Turns the Messages API event stream into `LLMEvent`s and, at `message_stop`,
/// the finished `AssistantTurn`.
struct AnthropicStreamDecoder {
    private enum Kind {
        case text
        case thinking
        case redactedThinking(data: String)
        case toolUse(id: String, name: String, initialInput: JSONValue?)
        case fallback(toModel: String?)
        case opaque(JSONValue)
    }

    /// One content block. Streamed text accumulates in place in `buffer`.
    private struct Entry {
        var kind: Kind
        /// Text, thinking text, or the streamed input JSON of a tool (or opaque) block.
        var buffer = ""
        var signature = ""
        var toolCall: ToolCall?
        var isOpen = true
    }

    private static let knownEventTypes: Set<String> = [
        "message_start", "content_block_start", "content_block_delta", "content_block_stop",
        "message_delta", "message_stop", "ping", "error",
    ]

    /// Whether non-empty thinking blocks are progress notes (the request asked
    /// for `display: "updates"`). Otherwise they are raw reasoning and never shown.
    let emitsProgressNotes: Bool
    private(set) var isFinished = false
    private var model: String?
    private var usage: TokenUsage?
    private var stopReason: StopReason?
    private var entries: [Entry] = []
    /// Stream block index → position in `entries`.
    private var positions: [Int: Int] = [:]

    init(emitsProgressNotes: Bool) {
        self.emitsProgressNotes = emitsProgressNotes
    }

    /// Consumes one SSE event. Throws `LLMError` for `error` events and
    /// malformed payloads.
    mutating func consume(_ event: SSEEvent) throws -> [LLMEvent] {
        guard !isFinished else { return [] }
        let payload: JSONValue
        do {
            payload = try JSONValue.parse(event.data)
        } catch {
            if let name = event.event, !Self.knownEventTypes.contains(name) { return [] }
            throw LLMError.invalidResponse(detail: "Malformed stream event")
        }
        switch payload["type"]?.stringValue ?? event.event ?? "" {
        case "message_start":
            let message = payload["message"]
            model = message?["model"]?.stringValue ?? model
            mergeUsage(message?["usage"])
            return []
        case "content_block_start":
            return startBlock(payload)
        case "content_block_delta":
            return applyDelta(payload)
        case "content_block_stop":
            guard let index = WireNumber.int(payload["index"]), let position = positions[index] else { return [] }
            return closeBlock(at: position)
        case "message_delta":
            if let raw = payload["delta"]?["stop_reason"]?.stringValue {
                let details = payload["delta"]?["stop_details"] ?? payload["stop_details"]
                stopReason = AnthropicWire.stopReason(raw, category: details?["category"]?.stringValue)
            }
            mergeUsage(payload["usage"])
            return []
        case "message_stop":
            return finish()
        case "error":
            throw AnthropicWire.streamError(payload["error"])
        default:
            return [] // ping and future event types
        }
    }

    /// Called when the body ended. A stream that lost only its `message_stop`
    /// (the stop reason already arrived) still completes; otherwise the
    /// response is incomplete.
    mutating func finishAtEndOfStream() throws -> [LLMEvent] {
        guard !isFinished else { return [] }
        guard stopReason != nil else {
            throw LLMError.invalidResponse(detail: "The stream ended before the message was complete")
        }
        return finish()
    }

    // MARK: Blocks

    private mutating func startBlock(_ payload: JSONValue) -> [LLMEvent] {
        let index = WireNumber.int(payload["index"]) ?? entries.count
        let block = payload["content_block"] ?? .object([:])
        var events: [LLMEvent] = []
        var entry: Entry
        switch block["type"]?.stringValue {
        case "text":
            entry = Entry(kind: .text, buffer: block["text"]?.stringValue ?? "")
            if !entry.buffer.isEmpty { events.append(.textDelta(entry.buffer)) }
        case "thinking":
            entry = Entry(kind: .thinking, buffer: block["thinking"]?.stringValue ?? "")
            entry.signature = block["signature"]?.stringValue ?? ""
        case "redacted_thinking":
            entry = Entry(kind: .redactedThinking(data: block["data"]?.stringValue ?? ""))
        case "tool_use":
            let id = block["id"]?.stringValue ?? "toolu_\(UUID().uuidString)"
            let name = block["name"]?.stringValue ?? ""
            events.append(.toolCallStarted(id: id, name: name))
            entry = Entry(kind: .toolUse(id: id, name: name, initialInput: block["input"]))
        case "fallback":
            entry = Entry(kind: .fallback(toModel: block["to"]?["model"]?.stringValue))
        default:
            entry = Entry(kind: .opaque(block))
        }
        if let position = positions[index] {
            entries[position] = entry
        } else {
            positions[index] = entries.count
            entries.append(entry)
        }
        return events
    }

    private mutating func applyDelta(_ payload: JSONValue) -> [LLMEvent] {
        guard let delta = payload["delta"], let type = delta["type"]?.stringValue else { return [] }
        let index = WireNumber.int(payload["index"]) ?? -1
        if positions[index] == nil, type == "text_delta" {
            positions[index] = entries.count
            entries.append(Entry(kind: .text))
        }
        guard let position = positions[index], entries[position].isOpen else { return [] }

        switch (entries[position].kind, type) {
        case (.text, "text_delta"):
            let fragment = delta["text"]?.stringValue ?? ""
            entries[position].buffer += fragment
            return fragment.isEmpty ? [] : [.textDelta(fragment)]
        case (.thinking, "thinking_delta"):
            entries[position].buffer += delta["thinking"]?.stringValue ?? ""
        case (.thinking, "signature_delta"):
            entries[position].signature += delta["signature"]?.stringValue ?? ""
        case (.toolUse, "input_json_delta"), (.opaque, "input_json_delta"):
            entries[position].buffer += delta["partial_json"]?.stringValue ?? ""
        default:
            break // citations_delta and deltas of unknown blocks
        }
        return []
    }

    private mutating func closeBlock(at position: Int) -> [LLMEvent] {
        guard entries[position].isOpen else { return [] }
        entries[position].isOpen = false
        let entry = entries[position]
        switch entry.kind {
        case .thinking:
            let note = entry.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if emitsProgressNotes, !note.isEmpty, note != AnthropicWire.interruptedWorkNote {
                return [.progressNote(note)]
            }
        case .toolUse(let id, let name, let initialInput):
            let call: ToolCall
            if entry.buffer.isEmpty, let initialInput, let object = initialInput.objectValue, !object.isEmpty {
                // Some servers send the complete input with the block start.
                call = ToolCall(id: id, name: name, input: initialInput, rawInput: initialInput.jsonString())
            } else {
                call = ToolCallDecoding.toolCall(id: id, name: name, arguments: entry.buffer)
            }
            entries[position].toolCall = call
            return [.toolCall(call)]
        case .opaque(let value):
            // Unknown blocks with streamed input (e.g. server tools) get it back.
            if !entry.buffer.isEmpty, case .object(var object) = value, let input = try? JSONValue.parse(entry.buffer) {
                object["input"] = input
                entries[position].kind = .opaque(.object(object))
            }
        default:
            break
        }
        return []
    }

    // MARK: Finishing

    private mutating func finish() -> [LLMEvent] {
        var events: [LLMEvent] = []
        for position in entries.indices where entries[position].isOpen {
            events += closeBlock(at: position)
        }
        isFinished = true

        // After a server-side fallback, blocks other than text that precede the
        // last fallback marker must not be echoed; the marker itself is dropped.
        let boundary = entries.lastIndex { entry in
            if case .fallback = entry.kind { return true }
            return false
        }
        var content: [ContentBlock] = []
        var fallbackModel: String?
        for (position, entry) in entries.enumerated() {
            let beforeBoundary = boundary.map { position < $0 } ?? false
            switch entry.kind {
            case .fallback(let toModel):
                fallbackModel = toModel ?? fallbackModel
            case .text:
                if !entry.buffer.isEmpty { content.append(.text(entry.buffer)) }
            case _ where beforeBoundary:
                continue
            case .thinking:
                if !entry.buffer.isEmpty || !entry.signature.isEmpty {
                    content.append(.thinking(text: entry.buffer, signature: entry.signature.isEmpty ? nil : entry.signature))
                }
            case .redactedThinking(let data):
                content.append(.redactedThinking(data: data))
            case .toolUse:
                if let call = entry.toolCall { content.append(.toolUse(call)) }
            case .opaque(let value):
                content.append(.opaque(value))
            }
        }

        let hasToolCalls = content.contains { if case .toolUse = $0 { true } else { false } }
        let turn = AssistantTurn(
            content: content,
            stopReason: stopReason ?? (hasToolCalls ? .toolUse : .endTurn),
            model: fallbackModel ?? model,
            usage: usage
        )
        return events + [.end(turn)]
    }

    private mutating func mergeUsage(_ json: JSONValue?) {
        guard let json, json.objectValue != nil else { return }
        var merged = usage ?? TokenUsage()
        if let value = WireNumber.count(json["input_tokens"]) { merged.inputTokens = value }
        if let value = WireNumber.count(json["output_tokens"]) { merged.outputTokens = value }
        if let value = WireNumber.count(json["cache_read_input_tokens"]) { merged.cacheReadInputTokens = value }
        if let value = WireNumber.count(json["cache_creation_input_tokens"]) { merged.cacheCreationInputTokens = value }
        usage = merged
    }
}
