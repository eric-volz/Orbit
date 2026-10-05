import Foundation

// Provider-neutral conversation model.
//
// The conversation history is APPEND-ONLY: once a message has been sent to a
// provider it must never be edited, reordered or removed, and the system prompt
// and tool list of a conversation are frozen when it starts. Anthropic binds
// thinking blocks to the exact prefix they were produced with; changing it makes
// the API reject the request (HTTP 400) on newer accounts.
//
// The one exception: after a refusal, a trailing user message that no assistant
// turn answered (and that carries no tool results) is removed, so the refused
// request is not re-sent with every follow-up. No thinking block depends on it.

enum MessageRole: String, Codable, Sendable, Hashable {
    case user
    case assistant
}

/// A tool invocation requested by the model.
struct ToolCall: Codable, Sendable, Hashable, Identifiable {
    /// Provider-assigned id (`toolu_…`, `call_…`). Tool results must echo it.
    var id: String
    var name: String
    /// Parsed arguments. `.object([:])` when the model sent no arguments.
    var input: JSONValue
    /// The raw argument JSON as streamed by the provider, when available.
    var rawInput: String?
    /// Set when `rawInput` could not be parsed. The agent loop must then not run
    /// the tool and instead return an `INVALID_JSON` error result to the model.
    var inputParseError: String?

    init(id: String, name: String, input: JSONValue = .object([:]), rawInput: String? = nil, inputParseError: String? = nil) {
        self.id = id
        self.name = name
        self.input = input
        self.rawInput = rawInput
        self.inputParseError = inputParseError
    }
}

/// The result of a tool call, sent back to the model in a user message.
struct ToolResultBlock: Codable, Sendable, Hashable {
    var toolCallID: String
    var content: String
    var isError: Bool

    init(toolCallID: String, content: String, isError: Bool = false) {
        self.toolCallID = toolCallID
        self.content = content
        self.isError = isError
    }
}

enum ContentBlock: Codable, Sendable, Hashable {
    /// Visible text (Markdown for assistant messages).
    case text(String)
    /// Model reasoning. Must be echoed back unchanged (including the signature)
    /// to the provider that produced it. `signature` is nil for providers that
    /// do not sign thinking (e.g. Ollama's Anthropic-compatible endpoint).
    case thinking(text: String, signature: String?)
    /// Encrypted reasoning (Anthropic). Echo back unchanged.
    case redactedThinking(data: String)
    case toolUse(ToolCall)
    case toolResult(ToolResultBlock)
    /// A provider-specific block that must be echoed back verbatim but has no
    /// meaning for Orbit (e.g. Anthropic's `fallback` marker).
    case opaque(JSONValue)
}

struct Message: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var role: MessageRole
    var content: [ContentBlock]
    var createdAt: Date
    /// For assistant messages: the model that produced the message (a server-side
    /// fallback may differ from the requested model).
    var model: String?

    init(id: UUID = UUID(), role: MessageRole, content: [ContentBlock], createdAt: Date = Date(), model: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.model = model
    }

    static func user(_ text: String) -> Message {
        Message(role: .user, content: [.text(text)])
    }
}

extension Message {
    /// Concatenated visible text of the message.
    var text: String {
        content.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n\n")
    }

    var toolCalls: [ToolCall] {
        content.compactMap { block -> ToolCall? in
            if case .toolUse(let call) = block { return call }
            return nil
        }
    }

    var toolResults: [ToolResultBlock] {
        content.compactMap { block -> ToolResultBlock? in
            if case .toolResult(let result) = block { return result }
            return nil
        }
    }
}

enum StopReason: Sendable, Hashable, Codable {
    case endTurn
    case toolUse
    case maxTokens
    case stopSequence
    /// The provider declined the request (Anthropic safety classifiers). Partial
    /// output must be discarded and tool calls of that turn must not run.
    case refusal(category: String?)
    /// The model's context window is exhausted.
    case contextWindowExceeded
    case other(String)
}

struct TokenUsage: Sendable, Hashable, Codable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadInputTokens: Int = 0
    var cacheCreationInputTokens: Int = 0
}

/// A finished assistant turn as produced by a provider.
struct AssistantTurn: Sendable, Hashable {
    /// Content blocks exactly as they must be appended to the history (thinking
    /// blocks included, in order). Providers already drop blocks that must not be
    /// echoed (e.g. blocks before an Anthropic fallback marker).
    var content: [ContentBlock]
    var stopReason: StopReason
    /// The model that actually produced the turn.
    var model: String?
    var usage: TokenUsage?

    init(content: [ContentBlock], stopReason: StopReason, model: String? = nil, usage: TokenUsage? = nil) {
        self.content = content
        self.stopReason = stopReason
        self.model = model
        self.usage = usage
    }

    var toolCalls: [ToolCall] {
        content.compactMap { block -> ToolCall? in
            if case .toolUse(let call) = block { return call }
            return nil
        }
    }

    var text: String {
        content.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined()
    }
}
