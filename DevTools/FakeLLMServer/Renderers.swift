import Foundation

/// One Server-Sent Event. `paced` events are sent after the turn's chunk delay.
struct SSEEvent: Sendable {
    var name: String?
    var data: String
    var paced: Bool

    var wireFormat: Data {
        var text = ""
        if let name { text += "event: \(name)\n" }
        text += "data: \(data)\n\n"
        return Data(text.utf8)
    }
}

/// Rough token estimate: about four characters per token.
func estimatedTokens(_ characters: Int) -> Int {
    max(1, characters / 4)
}

// MARK: - Anthropic Messages API

enum AnthropicRenderer {
    static func events(for turn: ScriptedTurn, request: ChatRequest, messageID: String, inputTokens: Int) -> [SSEEvent] {
        var events: [SSEEvent] = []
        func add(_ name: String, _ payload: JSON, paced: Bool = false) {
            events.append(SSEEvent(name: name, data: payload.serialized, paced: paced))
        }

        add("message_start", [
            "type": "message_start",
            "message": [
                "id": .string(messageID),
                "type": "message",
                "role": "assistant",
                "model": .string(request.model),
                "content": [],
                "stop_reason": nil,
                "stop_sequence": nil,
                "usage": [
                    "input_tokens": .int(inputTokens),
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 1,
                ],
            ],
        ])
        add("ping", ["type": "ping"])

        var outputCharacters = 0
        for (index, block) in turn.blocks.enumerated() {
            let blockIndex = JSON.int(index)
            switch block {
            case .thinking(let text, let signature):
                add("content_block_start", ["type": "content_block_start", "index": blockIndex,
                                            "content_block": ["type": "thinking", "thinking": "", "signature": ""]])
                for chunk in ScenarioBuilder.wordChunks(text) {
                    add("content_block_delta", ["type": "content_block_delta", "index": blockIndex,
                                                "delta": ["type": "thinking_delta", "thinking": .string(chunk)]], paced: true)
                }
                add("content_block_delta", ["type": "content_block_delta", "index": blockIndex,
                                            "delta": ["type": "signature_delta", "signature": .string(signature)]], paced: true)
                outputCharacters += text.count
            case .redactedThinking(let data):
                add("content_block_start", ["type": "content_block_start", "index": blockIndex,
                                            "content_block": ["type": "redacted_thinking", "data": .string(data)]], paced: true)
            case .text(let text):
                add("content_block_start", ["type": "content_block_start", "index": blockIndex,
                                            "content_block": ["type": "text", "text": ""]])
                for chunk in ScenarioBuilder.wordChunks(text) {
                    add("content_block_delta", ["type": "content_block_delta", "index": blockIndex,
                                                "delta": ["type": "text_delta", "text": .string(chunk)]], paced: true)
                }
                outputCharacters += text.count
            case .toolUse(let id, let name, let inputJSON):
                add("content_block_start", ["type": "content_block_start", "index": blockIndex,
                                            "content_block": ["type": "tool_use", "id": .string(id), "name": .string(name), "input": [:]]])
                for fragment in ScenarioBuilder.fragments(inputJSON) {
                    add("content_block_delta", ["type": "content_block_delta", "index": blockIndex,
                                                "delta": ["type": "input_json_delta", "partial_json": .string(fragment)]], paced: true)
                }
                outputCharacters += inputJSON.count + name.count
            }
            if turn.stop == nil, index == turn.blocks.count - 1 {
                // Mid-stream failure: the last block never completes.
                break
            }
            add("content_block_stop", ["type": "content_block_stop", "index": blockIndex])
        }

        guard let stop = turn.stop else {
            add("error", ["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]], paced: true)
            return events
        }
        var delta: [(key: String, value: JSON)] = [
            (key: "stop_reason", value: .string(stopReason(stop))),
            (key: "stop_sequence", value: .null),
        ]
        if case .refusal(let category) = stop {
            delta.append((key: "stop_details", value: [
                "type": "refusal",
                "category": .string(category),
                "explanation": "FakeLLMServer: simulated safety refusal.",
            ]))
        }
        add("message_delta", ["type": "message_delta", "delta": .object(delta),
                              "usage": ["output_tokens": .int(estimatedTokens(outputCharacters))]], paced: true)
        add("message_stop", ["type": "message_stop"])
        return events
    }

    /// Non-streaming `Message` object.
    static func message(for turn: ScriptedTurn, request: ChatRequest, messageID: String, inputTokens: Int) -> JSON {
        var content: [JSON] = []
        var outputCharacters = 0
        for block in turn.blocks {
            switch block {
            case .thinking(let text, let signature):
                content.append(["type": "thinking", "thinking": .string(text), "signature": .string(signature)])
                outputCharacters += text.count
            case .redactedThinking(let data):
                content.append(["type": "redacted_thinking", "data": .string(data)])
            case .text(let text):
                content.append(["type": "text", "text": .string(text)])
                outputCharacters += text.count
            case .toolUse(let id, let name, let inputJSON):
                let input = (try? JSON.parse(Data(inputJSON.utf8))) ?? [:]
                content.append(["type": "tool_use", "id": .string(id), "name": .string(name), "input": input])
                outputCharacters += inputJSON.count
            }
        }
        let stop = turn.stop ?? .endTurn
        var stopDetails: JSON = .null
        if case .refusal(let category) = stop {
            stopDetails = ["type": "refusal", "category": .string(category),
                           "explanation": "FakeLLMServer: simulated safety refusal."]
        }
        return [
            "id": .string(messageID),
            "type": "message",
            "role": "assistant",
            "model": .string(request.model),
            "content": .array(content),
            "stop_reason": .string(stopReason(stop)),
            "stop_sequence": nil,
            "stop_details": stopDetails,
            "usage": ["input_tokens": .int(inputTokens), "output_tokens": .int(estimatedTokens(outputCharacters))],
        ]
    }

    static func stopReason(_ stop: ScriptedTurn.Stop) -> String {
        switch stop {
        case .endTurn: "end_turn"
        case .toolUse: "tool_use"
        case .maxTokens: "max_tokens"
        case .refusal: "refusal"
        }
    }

    static func errorBody(type: String, message: String, requestID: String) -> JSON {
        ["type": "error", "error": ["type": .string(type), "message": .string(message)], "request_id": .string(requestID)]
    }
}

// MARK: - OpenAI Chat Completions

enum OpenAIRenderer {
    static func events(for turn: ScriptedTurn, request: ChatRequest, completionID: String, inputTokens: Int) -> [SSEEvent] {
        let created = JSON.int(Int(Date().timeIntervalSince1970))
        var events: [SSEEvent] = []
        func chunk(delta: JSON, finishReason: JSON = nil, paced: Bool = true) {
            let payload: JSON = [
                "id": .string(completionID),
                "object": "chat.completion.chunk",
                "created": created,
                "model": .string(request.model),
                "system_fingerprint": "fp_fake",
                "choices": [["index": 0, "delta": delta, "logprobs": nil, "finish_reason": finishReason]],
            ]
            events.append(SSEEvent(name: nil, data: payload.serialized, paced: paced))
        }

        chunk(delta: ["role": "assistant", "content": ""], paced: false)
        var outputCharacters = 0
        var toolIndex = 0
        for block in turn.blocks {
            switch block {
            case .thinking(let text, _):
                // Ollama-style reasoning deltas; there is no signature in this dialect.
                for piece in ScenarioBuilder.wordChunks(text) {
                    chunk(delta: ["reasoning": .string(piece)])
                }
                outputCharacters += text.count
            case .redactedThinking:
                continue
            case .text(let text):
                for piece in ScenarioBuilder.wordChunks(text) {
                    chunk(delta: ["content": .string(piece)])
                }
                outputCharacters += text.count
            case .toolUse(let id, let name, let inputJSON):
                let index = JSON.int(toolIndex)
                chunk(delta: ["tool_calls": [["index": index, "id": .string(id), "type": "function",
                                              "function": ["name": .string(name), "arguments": ""]]]])
                for fragment in ScenarioBuilder.fragments(inputJSON) {
                    chunk(delta: ["tool_calls": [["index": index, "function": ["arguments": .string(fragment)]]]])
                }
                toolIndex += 1
                outputCharacters += inputJSON.count
            }
        }

        guard let stop = turn.stop else {
            let error: JSON = ["error": ["message": "Overloaded", "type": "overloaded_error", "param": nil, "code": "overloaded"]]
            events.append(SSEEvent(name: nil, data: error.serialized, paced: true))
            return events
        }
        chunk(delta: [:], finishReason: .string(finishReason(stop)))
        if request.includeUsage {
            let outputTokens = estimatedTokens(outputCharacters)
            let usage: JSON = [
                "id": .string(completionID),
                "object": "chat.completion.chunk",
                "created": created,
                "model": .string(request.model),
                "system_fingerprint": "fp_fake",
                "choices": [],
                "usage": ["prompt_tokens": .int(inputTokens), "completion_tokens": .int(outputTokens),
                          "total_tokens": .int(inputTokens + outputTokens)],
            ]
            events.append(SSEEvent(name: nil, data: usage.serialized, paced: false))
        }
        events.append(SSEEvent(name: nil, data: "[DONE]", paced: false))
        return events
    }

    /// Non-streaming `chat.completion` object.
    static func completion(for turn: ScriptedTurn, request: ChatRequest, completionID: String, inputTokens: Int) -> JSON {
        var reasoning = ""
        var text = ""
        var toolCalls: [JSON] = []
        for block in turn.blocks {
            switch block {
            case .thinking(let thinking, _): reasoning += thinking
            case .redactedThinking: continue
            case .text(let value): text += value
            case .toolUse(let id, let name, let inputJSON):
                toolCalls.append(["id": .string(id), "type": "function",
                                  "function": ["name": .string(name), "arguments": .string(inputJSON)]])
            }
        }
        var message: [(key: String, value: JSON)] = [(key: "role", value: "assistant"), (key: "content", value: .string(text))]
        if !reasoning.isEmpty { message.append((key: "reasoning", value: .string(reasoning))) }
        if !toolCalls.isEmpty { message.append((key: "tool_calls", value: .array(toolCalls))) }
        let outputTokens = estimatedTokens(reasoning.count + text.count)
        return [
            "id": .string(completionID),
            "object": "chat.completion",
            "created": .int(Int(Date().timeIntervalSince1970)),
            "model": .string(request.model),
            "choices": [["index": 0, "message": .object(message), "logprobs": nil,
                         "finish_reason": .string(finishReason(turn.stop ?? .endTurn))]],
            "usage": ["prompt_tokens": .int(inputTokens), "completion_tokens": .int(outputTokens),
                      "total_tokens": .int(inputTokens + outputTokens)],
        ]
    }

    static func finishReason(_ stop: ScriptedTurn.Stop) -> String {
        switch stop {
        case .endTurn: "stop"
        case .toolUse: "tool_calls"
        case .maxTokens: "length"
        case .refusal: "content_filter"
        }
    }

    /// OpenAI's error object inside an Anthropic-style envelope, so clients of
    /// either dialect can read it.
    static func errorBody(type: String, message: String, code: String?) -> JSON {
        ["type": "error", "error": ["message": .string(message), "type": .string(type), "param": nil, "code": .optional(code)]]
    }
}

// MARK: - Errors

/// Anthropic error type, default message and OpenAI error code for a status.
func errorDescription(status: Int, model: String) -> (type: String, message: String, code: String?) {
    switch status {
    case 400: ("invalid_request_error", "FakeLLMServer: simulated invalid request.", nil)
    case 401: ("authentication_error", "invalid x-api-key", "invalid_api_key")
    case 402: ("billing_error", "Your credit balance is too low to access the API.", "insufficient_quota")
    case 403: ("permission_error", "Your API key does not have permission to use the specified resource.", nil)
    case 404: ("not_found_error", "model: \(model)", "model_not_found")
    case 413: ("request_too_large", "Request exceeds the maximum allowed number of bytes.", nil)
    case 429: ("rate_limit_error", "Number of request tokens has exceeded your per-minute rate limit.", "rate_limit_exceeded")
    case 504: ("timeout_error", "Request timed out.", nil)
    case 529: ("overloaded_error", "Overloaded", "overloaded")
    case 400..<500: ("invalid_request_error", "FakeLLMServer: simulated error \(status).", nil)
    default: ("api_error", "Internal server error", nil)
    }
}
