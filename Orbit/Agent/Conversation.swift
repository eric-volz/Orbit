import Foundation

/// A chat: the provider-neutral message history (append-only) plus the items
/// the UI shows. Persisted by `ConversationStore`.
struct Conversation: Sendable, Hashable, Codable, Identifiable {
    var id: UUID
    var title: String?
    var createdAt: Date
    var updatedAt: Date
    /// Frozen when the first request is sent; never rebuilt for this conversation.
    var systemPrompt: String?
    /// Names of the tools offered to the model, frozen with the system prompt.
    var toolNames: [String]?
    /// The exact tool definitions offered, frozen with the system prompt (older
    /// stored chats have only `toolNames`).
    var toolDefinitions: [ToolDefinition]?
    /// Endpoints that have received this conversation's history (normalized keys,
    /// e.g. "anthropic@api.anthropic.com"), so switching providers mid-chat can
    /// disclose that the history goes to a new recipient.
    var recipients: [String]?
    /// Running total of user content in the history (for disclosure on a switch).
    var disclosedContent: [ContentDisclosure]?
    /// User content in the history that no request has carried to a provider yet
    /// (e.g. tool results of a stopped run), so a later request still discloses it.
    var pendingDisclosures: [ContentDisclosure]?
    /// History sent to the provider. Append-only (see LLM/Models.swift).
    var messages: [Message]
    /// What the chat shows.
    var items: [ChatItem]

    init(id: UUID = UUID(), title: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(),
         systemPrompt: String? = nil, toolNames: [String]? = nil, toolDefinitions: [ToolDefinition]? = nil,
         recipients: [String]? = nil, disclosedContent: [ContentDisclosure]? = nil,
         pendingDisclosures: [ContentDisclosure]? = nil, messages: [Message] = [], items: [ChatItem] = []) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.systemPrompt = systemPrompt
        self.toolNames = toolNames
        self.toolDefinitions = toolDefinitions
        self.recipients = recipients
        self.disclosedContent = disclosedContent
        self.pendingDisclosures = pendingDisclosures
        self.messages = messages
        self.items = items
    }

    var isEmpty: Bool { messages.isEmpty && items.isEmpty }
}

/// Persistence for conversations (SQLite via GRDB in production).
protocol ConversationStoring: Sendable {
    func save(_ conversation: Conversation) async throws
    func mostRecent() async throws -> Conversation?
    func deleteAll() async throws
}
