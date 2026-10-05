import Foundation

/// A tool as advertised to the model. Codable so a conversation can freeze the
/// exact definitions it started with.
struct ToolDefinition: Sendable, Hashable, Codable {
    var name: String
    var description: String
    /// JSON Schema (type "object") for the tool input.
    var inputSchema: JSONValue
}

enum ReasoningEffort: String, Codable, Sendable, Hashable, CaseIterable {
    case low
    case medium
    case high
}

/// Runs one tool call on behalf of a provider that drives the tool loop itself
/// (Claude Code calls Orbit's tools through an MCP bridge). Implemented by the
/// agent loop: validation, confirmation cards, status rows, cards, truncation and
/// the per-request tool budget work exactly as for API providers.
protocol ToolExecuting: Sendable {
    func execute(_ call: ToolCall) async -> ToolResultBlock
}

struct LLMRequest: Sendable {
    var model: String
    /// Frozen for the whole conversation (see Models.swift).
    var systemPrompt: String
    var messages: [Message]
    /// Frozen for the whole conversation (see Models.swift).
    var tools: [ToolDefinition]
    /// nil = provider default.
    var maxTokens: Int?
    /// nil = do not send an effort setting.
    var effort: ReasoningEffort?
    /// Identifies the conversation, so providers that keep per-conversation state
    /// (a Claude Code process) can reuse it across turns.
    var conversationID: UUID?
    /// Set by the agent loop for providers with `executesToolsInternally`.
    var toolExecutor: (any ToolExecuting)?

    init(model: String, systemPrompt: String, messages: [Message], tools: [ToolDefinition] = [], maxTokens: Int? = nil,
         effort: ReasoningEffort? = nil, conversationID: UUID? = nil, toolExecutor: (any ToolExecuting)? = nil) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.effort = effort
        self.conversationID = conversationID
        self.toolExecutor = toolExecutor
    }
}

/// Usage-limit state reported by subscription-based providers (Claude Code's
/// `rate_limit_event`).
struct RateLimitInfo: Sendable, Hashable, Codable {
    /// Raw status, e.g. "allowed", "allowed_warning", "rejected".
    var status: String
    /// Share of the window's limit used, 0…1.
    var utilization: Double?
    var resetsAt: Date?
    /// Raw window kind, e.g. "five_hour", "seven_day".
    var window: String?
    var isUsingOverage: Bool?

    var isWarning: Bool { status == "allowed_warning" }
    var isRejected: Bool { status == "rejected" }
}

/// Events emitted while a response streams in.
enum LLMEvent: Sendable {
    /// Visible answer text (Markdown), in order.
    case textDelta(String)
    /// A short progress note the model wrote between tool calls (shown as a
    /// subtle status line, never as part of the answer).
    case progressNote(String)
    /// The model started a tool call; its arguments are still streaming.
    case toolCallStarted(id: String, name: String)
    /// A tool call whose arguments are complete. Informational only; the agent
    /// loop runs tools after `.end`, once the stop reason is known.
    case toolCall(ToolCall)
    /// The provider had to drop thinking blocks from the history to recover from
    /// a "bound to a different conversation" error. The caller must drop all
    /// `.thinking` / `.redactedThinking` blocks from its stored history as well.
    case historyThinkingStripped
    /// Current usage-limit state of a subscription (informational).
    case rateLimit(RateLimitInfo)
    /// The response finished. Always the last event of a successful stream.
    case end(AssistantTurn)
}

enum ProviderKind: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case anthropic
    case openAICompatible
    /// The user's Claude subscription through the locally installed, unmodified
    /// Claude Code CLI (`claude`), signed in through Anthropic's own flow. Orbit
    /// never touches Claude credentials.
    case claudeCode

    var id: String { rawValue }

    /// Whether the provider authenticates with an API key from the keychain.
    var usesAPIKey: Bool { self != .claudeCode }
}

/// Everything needed to construct a provider.
struct ProviderConfiguration: Sendable, Hashable {
    var kind: ProviderKind
    /// Empty for providers that need no key (e.g. local servers).
    var apiKey: String
    /// nil = the provider's default endpoint.
    var baseURL: URL?
    /// Claude Code only: path of the `claude` executable (nil = auto-detect).
    var executablePath: String? = nil
}

protocol LLMProvider: Sendable {
    var kind: ProviderKind { get }
    /// Who receives the content, for the note "3 emails sent to Claude": a
    /// product name, a host, or a `ProviderRecipient` key (shown localized).
    var displayName: String { get }

    /// Streams one assistant turn. Errors are thrown as `LLMError`. Cancelling
    /// the consuming task cancels the underlying network request.
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMEvent, Error>

    /// Checks that the endpoint is reachable and the credentials are valid,
    /// without generating tokens where possible (e.g. `GET /v1/models`).
    func validateConfiguration(model: String) async throws

    /// True when the provider runs the tool loop itself and calls
    /// `LLMRequest.toolExecutor` for each tool call. `.end` then carries the final
    /// answer of the whole run, and the tool calls it contains must not be run again.
    var executesToolsInternally: Bool { get }
}

extension LLMProvider {
    var executesToolsInternally: Bool { false }
}

/// Builds providers from configurations. Tests inject mock providers here.
struct LLMProviderFactory: Sendable {
    var make: @Sendable (ProviderConfiguration) throws -> any LLMProvider

    init(make: @escaping @Sendable (ProviderConfiguration) throws -> any LLMProvider) {
        self.make = make
    }
}
