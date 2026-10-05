import Foundation

/// What Claude Code reported at the start of a turn (`system/init`). Used to
/// verify the isolation (no skills, no built-in tools) and the MCP connection.
struct ClaudeCodeInitInfo: Sendable, Hashable {
    var model: String?
    var version: String?
    var tools: [String]
    /// MCP server name → connection status ("connected", "failed", …).
    var mcpServers: [String: String]
    var slashCommands: [String]
    var skills: [String]
    var agents: [String]
    /// Whether an auto-memory directory is configured (it must not be).
    var hasMemoryPaths: Bool

    init(_ json: JSONValue) {
        model = json["model"]?.stringValue
        version = json["claude_code_version"]?.stringValue
        tools = (json["tools"]?.arrayValue ?? []).compactMap(\.stringValue)
        var servers: [String: String] = [:]
        for server in json["mcp_servers"]?.arrayValue ?? [] {
            if let name = server["name"]?.stringValue {
                servers[name] = server["status"]?.stringValue ?? "unknown"
            }
        }
        mcpServers = servers
        slashCommands = (json["slash_commands"]?.arrayValue ?? []).compactMap(\.stringValue)
        skills = (json["skills"]?.arrayValue ?? []).compactMap(\.stringValue)
        agents = (json["agents"]?.arrayValue ?? []).compactMap(\.stringValue)
        hasMemoryPaths = json["memory_paths"].map { !$0.isNull && $0.objectValue?.isEmpty != true } ?? false
    }
}

/// Turns the stdout messages of one Claude Code turn (`--output-format
/// stream-json --include-partial-messages`) into `LLMEvent`s and, at the
/// turn's `result`, the finished `AssistantTurn`.
///
/// A turn spans all model calls Claude Code makes for one user message (tool
/// calls run in between through Orbit's MCP bridge). Visible text of every
/// model call streams as `.textDelta`; tool calls are announced with
/// `.toolCallStarted` (names without the `mcp__orbit__` prefix). The finished
/// turn holds only the text blocks: the tool calls already ran and must not run
/// again. Error results are thrown as `LLMError` (never with the CLI's text).
struct ClaudeCodeStreamDecoder {
    /// The `uuid` of the user message that started the turn. A `result` that
    /// answers a different message (an interrupted earlier turn) is skipped.
    let turnID: String
    let toolPrefix: String
    /// The model as set in Orbit ("opus", or an id): an error about the model names it.
    let configuredModel: String

    private(set) var initInfo: ClaudeCodeInitInfo?
    private(set) var finishedTurn: AssistantTurn?
    /// Tool calls the model made in this turn.
    private(set) var toolCallCount = 0
    /// Latest usage-limit state reported during the turn.
    private(set) var rateLimit: RateLimitInfo?

    var isFinished: Bool { finishedTurn != nil }

    /// Text blocks of the turn in order (empty ones are dropped at the end).
    private var texts: [String] = []
    /// "messageID#blockIndex" → position in `texts`.
    private var textPositions: [String: Int] = [:]
    private var currentMessageID = ""
    private var streamedMessageIDs: Set<String> = []
    private var model: String?
    private var lastStopReason: String?
    private var lastStopCategory: String?
    /// Text of a synthetic error message (e.g. "Not logged in"); logged privately only.
    private var errorText: String?
    private var apiErrorStatus: Int?

    init(turnID: String, toolPrefix: String = ClaudeCodeLaunch.mcpToolPrefix, configuredModel: String = "") {
        self.turnID = turnID.lowercased()
        self.toolPrefix = toolPrefix
        self.configuredModel = configuredModel
    }

    /// Consumes one stdout message. Throws `LLMError` when the turn failed.
    mutating func consume(_ message: JSONValue) throws -> [LLMEvent] {
        guard !isFinished else { return [] }
        // Messages of subagents carry their parent's tool id; Orbit never runs any.
        if let parent = message["parent_tool_use_id"], !parent.isNull { return [] }
        switch message["type"]?.stringValue {
        case "system":
            if message["subtype"]?.stringValue == "init" {
                let info = ClaudeCodeInitInfo(message)
                initInfo = info
                model = model ?? info.model
            }
            return []
        case "stream_event":
            return streamEvent(message["event"] ?? .null)
        case "assistant":
            return assistantMessage(message)
        case "rate_limit_event":
            guard let info = Self.rateLimitInfo(message["rate_limit_info"]) else { return [] }
            rateLimit = info
            return [.rateLimit(info)]
        case "result":
            return try result(message)
        default:
            // user (tool results), command_lifecycle, control messages, status, …
            return []
        }
    }

    // MARK: Streamed model output

    private mutating func streamEvent(_ event: JSONValue) -> [LLMEvent] {
        switch event["type"]?.stringValue {
        case "message_start":
            let message = event["message"]
            currentMessageID = message?["id"]?.stringValue ?? UUID().uuidString
            streamedMessageIDs.insert(currentMessageID)
            model = message?["model"]?.stringValue ?? model
            return []
        case "content_block_start":
            let index = WireNumber.int(event["index"]) ?? 0
            let block = event["content_block"] ?? .null
            switch block["type"]?.stringValue {
            case "text":
                let initial = block["text"]?.stringValue ?? ""
                textPositions[textKey(index)] = texts.count
                texts.append(initial)
                return initial.isEmpty ? [] : [.textDelta(initial)]
            case "tool_use":
                toolCallCount += 1
                let id = block["id"]?.stringValue ?? ""
                let name = strippingPrefix(block["name"]?.stringValue ?? "")
                return [.toolCallStarted(id: id, name: name)]
            default:
                return [] // thinking and other blocks are not shown
            }
        case "content_block_delta":
            let index = WireNumber.int(event["index"]) ?? 0
            guard event["delta"]?["type"]?.stringValue == "text_delta",
                  let fragment = event["delta"]?["text"]?.stringValue, !fragment.isEmpty else { return [] }
            let key = textKey(index)
            if let position = textPositions[key] {
                texts[position] += fragment
            } else {
                textPositions[key] = texts.count
                texts.append(fragment)
            }
            return [.textDelta(fragment)]
        case "message_delta":
            if let reason = event["delta"]?["stop_reason"]?.stringValue {
                lastStopReason = reason
                lastStopCategory = (event["delta"]?["stop_details"] ?? event["stop_details"])?["category"]?.stringValue
            }
            return []
        default:
            return []
        }
    }

    /// Complete messages. Streamed ones are already known from their deltas;
    /// a message that was not streamed contributes its text here. Synthetic
    /// messages (errors Claude Code reports as assistant text) never do.
    private mutating func assistantMessage(_ message: JSONValue) -> [LLMEvent] {
        let body = message["message"] ?? .null
        if message["is_api_error_message"]?.boolValue == true || body["model"]?.stringValue == "<synthetic>" {
            let text = Self.text(of: body)
            if !text.isEmpty { errorText = text }
            apiErrorStatus = WireNumber.int(message["api_error_status"]) ?? apiErrorStatus
            return []
        }
        let id = body["id"]?.stringValue ?? ""
        guard !id.isEmpty, !streamedMessageIDs.contains(id) else { return [] }
        streamedMessageIDs.insert(id)
        model = body["model"]?.stringValue ?? model
        var events: [LLMEvent] = []
        for block in body["content"]?.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text":
                let text = block["text"]?.stringValue ?? ""
                guard !text.isEmpty else { continue }
                texts.append(text)
                events.append(.textDelta(text))
            case "tool_use":
                toolCallCount += 1
                events.append(.toolCallStarted(id: block["id"]?.stringValue ?? "",
                                               name: strippingPrefix(block["name"]?.stringValue ?? "")))
            default:
                continue
            }
        }
        return events
    }

    // MARK: Result

    private mutating func result(_ message: JSONValue) throws -> [LLMEvent] {
        if let answered = message["user_message_uuid"]?.stringValue, answered.lowercased() != turnID {
            return [] // the end of an earlier, interrupted turn
        }
        let subtype = message["subtype"]?.stringValue ?? "success"
        let isError = message["is_error"]?.boolValue ?? (subtype != "success")
        let usage = Self.usage(message["usage"])
        let stopReason = message["stop_reason"]?.stringValue ?? lastStopReason

        if subtype == "error_max_turns" || (!isError && subtype == "success") {
            var events: [LLMEvent] = []
            var content = texts.filter { !$0.isEmpty }.map(ContentBlock.text)
            if content.isEmpty, let text = message["result"]?.stringValue, !text.isEmpty, subtype == "success" {
                // Nothing was streamed; the result carries the final answer.
                content = [.text(text)]
                events.append(.textDelta(text))
            }
            finishedTurn = AssistantTurn(
                content: content,
                stopReason: subtype == "error_max_turns" ? .other("max_turns") : Self.stopReason(stopReason, category: lastStopCategory),
                model: model,
                usage: usage
            )
            return events
        }

        let resultText = message["result"]?.stringValue
        let errors = (message["errors"]?.arrayValue ?? []).compactMap(\.stringValue)
        throw ClaudeCodeErrorClassifier.classify(ClaudeCodeErrorClassifier.Report(
            subtype: subtype,
            terminalReason: message["terminal_reason"]?.stringValue,
            apiErrorStatus: WireNumber.int(message["api_error_status"]) ?? apiErrorStatus,
            text: ([resultText, errorText].compactMap { $0 } + errors).joined(separator: "\n"),
            rateLimit: rateLimit,
            model: configuredModel.isEmpty ? (model ?? initInfo?.model ?? "") : configuredModel
        ))
    }

    // MARK: Helpers

    private func textKey(_ index: Int) -> String {
        "\(currentMessageID)#\(index)"
    }

    private func strippingPrefix(_ name: String) -> String {
        name.hasPrefix(toolPrefix) ? String(name.dropFirst(toolPrefix.count)) : name
    }

    /// Claude Code finishes a turn after the tools ran, so `tool_use` as the last
    /// stop reason only means the run ended early; the answer is complete.
    static func stopReason(_ raw: String?, category: String?) -> StopReason {
        guard let raw else { return .endTurn }
        switch raw {
        case "tool_use": return .endTurn
        default: return AnthropicWire.stopReason(raw, category: category)
        }
    }

    static func rateLimitInfo(_ json: JSONValue?) -> RateLimitInfo? {
        guard let json, let status = json["status"]?.stringValue else { return nil }
        let resetsAt = json["resetsAt"]?.doubleValue.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        return RateLimitInfo(
            status: status,
            utilization: json["utilization"]?.doubleValue,
            resetsAt: resetsAt,
            window: json["rateLimitType"]?.stringValue,
            isUsingOverage: json["isUsingOverage"]?.boolValue
        )
    }

    static func usage(_ json: JSONValue?) -> TokenUsage? {
        guard let json, json.objectValue != nil else { return nil }
        return TokenUsage(
            inputTokens: WireNumber.count(json["input_tokens"]) ?? 0,
            outputTokens: WireNumber.count(json["output_tokens"]) ?? 0,
            cacheReadInputTokens: WireNumber.count(json["cache_read_input_tokens"]) ?? 0,
            cacheCreationInputTokens: WireNumber.count(json["cache_creation_input_tokens"]) ?? 0
        )
    }

    private static func text(of message: JSONValue) -> String {
        if let text = message["content"]?.stringValue { return text }
        return (message["content"]?.arrayValue ?? []).compactMap { block -> String? in
            block["type"]?.stringValue == "text" ? block["text"]?.stringValue : nil
        }.joined(separator: "\n")
    }
}
