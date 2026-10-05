import Foundation
import Observation

/// "Nach Pause: Suche zuerst": Orbit is a launcher first. When the panel is
/// shown after it was hidden for `pause` or longer, it opens in search mode and
/// the chat waits one step away: "Continue chat" under the empty input, or ↑
/// in it. Reopened sooner, the chat is still there. Parking only changes what
/// the panel shows (AgentLoop keeps the conversation), and a chat that needs
/// the user (an answer running, a confirmation waiting, a message typed into
/// its input but not sent) is never parked. A chat restored at launch starts
/// parked: how long the panel was hidden is unknown then, so it counts as a
/// pause.
@MainActor
@Observable
final class ChatParking {
    /// How long the panel must have been hidden for Orbit to open in search mode.
    nonisolated static let pause: TimeInterval = 5 * 60

    /// The conversation kept out of sight; the chat is parked while it is the current one.
    private(set) var parkedConversationID: UUID?

    @ObservationIgnored private let agentLoop: AgentLoop
    @ObservationIgnored private let panelState: PanelState
    /// The clock (tests set their own).
    @ObservationIgnored var now: () -> Date
    /// When the panel was last hidden; nil before it was hidden once.
    @ObservationIgnored private var hiddenAt: Date?

    init(agentLoop: AgentLoop, panelState: PanelState, now: @escaping () -> Date = { Date() }) {
        self.agentLoop = agentLoop
        self.panelState = panelState
        self.now = now
    }

    /// Whether the chat is parked: it exists, but the panel shows search.
    var isParked: Bool {
        agentLoop.hasConversation && parkedConversationID == agentLoop.conversationID
    }

    /// The panel is about to appear after it was hidden: after a pause an idle
    /// chat is parked.
    func panelWillAppear() {
        guard Self.parks(hasConversation: agentLoop.hasConversation, isRunning: agentLoop.isRunning,
                         hasPendingConfirmation: agentLoop.pendingConfirmation != nil,
                         hasUnsentMessage: hasUnsentMessage,
                         hiddenFor: hiddenAt.map { now().timeIntervalSince($0) }) else { return }
        park()
    }

    /// The panel was hidden.
    func panelDidHide() {
        hiddenAt = now()
    }

    /// Shows the parked chat again ("Continue chat", or ↑ in the empty input).
    func unpark() {
        parkedConversationID = nil
    }

    /// At launch: restores the most recent chat (see `AgentLoop`), parked.
    func restoreMostRecentChat() async {
        let current = agentLoop.conversationID
        await agentLoop.restoreMostRecentConversation()
        // Nothing was restored when the user started a chat meanwhile.
        guard agentLoop.conversationID != current, agentLoop.hasConversation else { return }
        park()
    }

    private func park() {
        parkedConversationID = agentLoop.conversationID
    }

    /// Text in the chat's input that was not sent: a follow-up the user is
    /// writing. (While the chat is parked, the input holds a search.)
    private var hasUnsentMessage: Bool {
        !isParked && !panelState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether showing the panel parks the chat. `hiddenFor`: how long the
    /// panel was hidden; nil when it was not hidden since launch (a chat
    /// restored at launch is parked when it is restored).
    nonisolated static func parks(hasConversation: Bool, isRunning: Bool, hasPendingConfirmation: Bool,
                                  hasUnsentMessage: Bool, hiddenFor: TimeInterval?,
                                  pause: TimeInterval = pause) -> Bool {
        guard hasConversation, !isRunning, !hasPendingConfirmation, !hasUnsentMessage, let hiddenFor else {
            return false
        }
        return hiddenFor >= pause
    }
}
