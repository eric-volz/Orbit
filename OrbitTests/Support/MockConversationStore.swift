import Foundation
@testable import Orbit

/// In-memory `ConversationStoring` that records what the agent loop saves.
actor MockConversationStore: ConversationStoring {
    struct Failure: Error {}

    private(set) var conversations: [UUID: Conversation] = [:]
    /// Every saved snapshot, in order.
    private(set) var saved: [Conversation] = []
    private(set) var deleteAllCount = 0
    private var failsDeleteAll = false

    init(conversations: [Conversation] = []) {
        for conversation in conversations {
            self.conversations[conversation.id] = conversation
        }
    }

    func save(_ conversation: Conversation) async throws {
        conversations[conversation.id] = conversation
        saved.append(conversation)
    }

    func mostRecent() async throws -> Conversation? {
        conversations.values.max { $0.updatedAt < $1.updatedAt }
    }

    func deleteAll() async throws {
        if failsDeleteAll { throw Failure() }
        conversations = [:]
        deleteAllCount += 1
    }

    func setFailsDeleteAll(_ fails: Bool) {
        failsDeleteAll = fails
    }

    func conversation(_ id: UUID) -> Conversation? {
        conversations[id]
    }
}
