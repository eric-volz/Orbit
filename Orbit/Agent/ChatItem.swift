import Foundation

/// Context captured when the panel opens (context chips). Passed to the model
/// with the user's request.
struct ContextAttachment: Sendable, Hashable, Codable, Identifiable {
    enum Kind: Sendable, Hashable, Codable {
        /// Files selected in Finder.
        case finderSelection(paths: [String])
        /// Text selected in the frontmost app.
        case selectedText(text: String, appName: String?)
        /// The frontmost app and window.
        case frontmostApp(name: String, bundleID: String?, windowTitle: String?)
    }

    var id: UUID
    var kind: Kind
    /// Chip label, e.g. "With selection: Angebot.pdf" (localized).
    var label: String
    /// How much was selected when the attachment holds less: the number of
    /// items selected in Finder (without `withheldCount`), or the length of
    /// the selected text (about, in characters). nil when it holds everything
    /// (and in chats saved before).
    var selectionTotal: Int? = nil
    /// Selected Finder items left out because Orbit never shares them (keys,
    /// other secrets, `~/Library`): only their number reaches the model, never
    /// their names. nil when there were none (and in chats saved before).
    var withheldCount: Int? = nil

    init(id: UUID = UUID(), kind: Kind, label: String, selectionTotal: Int? = nil, withheldCount: Int? = nil) {
        self.id = id
        self.kind = kind
        self.label = label
        self.selectionTotal = selectionTotal
        self.withheldCount = withheldCount
    }
}

/// One row in the chat, as the UI renders it. Owned and mutated by AgentLoop.
struct ChatItem: Sendable, Hashable, Codable, Identifiable {
    enum Kind: Sendable, Hashable, Codable {
        case user(text: String, attachments: [ContextAttachment])
        /// Markdown answer; `isStreaming` while tokens arrive.
        case assistant(text: String, isStreaming: Bool)
        /// Short progress note the model wrote between tool calls.
        case progress(text: String)
        case toolStatus(ToolStatus)
        case card(ResultCard)
        case confirmation(ConfirmationState)
        case notice(Notice)
        /// "3 emails sent to Claude".
        case disclosure(items: [ContentDisclosure], providerName: String)
    }

    var id: UUID
    var kind: Kind
    var createdAt: Date

    init(id: UUID = UUID(), kind: Kind, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
    }
}

struct ToolStatus: Sendable, Hashable, Codable {
    enum State: String, Sendable, Hashable, Codable {
        case running
        case succeeded
        case failed
        case cancelled
    }

    var toolCallID: String
    var toolName: String
    var category: ToolCategory?
    /// "Searching mail…" while running, "Found 12 emails" afterwards.
    var text: String
    var state: State
}

struct ConfirmationState: Sendable, Hashable, Codable {
    enum Status: String, Sendable, Hashable, Codable {
        /// Waiting for the user.
        case pending
        /// The user clicked "Run"; the action is running.
        case confirmed
        /// The action ran successfully ("Completed").
        case approved
        /// The action ran and failed.
        case failed
        /// Confirmed, but not carried out (e.g. invalid edits, stopped before it started).
        case notRun
        /// Stopped or timed out while running: it may still have happened.
        case outcomeUnknown
        /// The user declined.
        case cancelled
        /// The request ended (stop/new chat) before the user decided.
        case expired
    }

    var request: ConfirmationRequest
    var status: Status
}

struct Notice: Sendable, Hashable, Codable {
    enum Style: String, Sendable, Hashable, Codable {
        case info
        case warning
        case error
    }

    /// A button shown with the notice.
    enum Action: String, Sendable, Hashable, Codable {
        /// "Try Again" → `AgentLoop.retry()`.
        case retry
        /// "Open Settings" → `PanelState.openSettings(_:)` on the Model tab (e.g.
        /// missing API key).
        case openSettings
        /// "Open Settings" on the Permissions tab: macOS refused a permission.
        case openPermissionSettings
        /// "Sign In…" → `AgentLoop.signInAndRetry()`: Claude Code is not signed in.
        case signIn
        /// "New Chat": the conversation no longer fits the model.
        case newChat
    }

    var style: Style
    var message: String
    var action: Action?
    /// A second button after `action`, e.g. "Try Again" next to
    /// "Open Settings". nil in chats saved before.
    var secondaryAction: Action?

    init(style: Style, message: String, action: Action? = nil, secondaryAction: Action? = nil) {
        self.style = style
        self.message = message
        self.action = action
        self.secondaryAction = secondaryAction
    }

    /// The buttons, in order.
    var actions: [Action] {
        [action, secondaryAction].compactMap { $0 }
    }
}
