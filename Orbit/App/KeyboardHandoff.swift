import Foundation

/// Tells the panel that Orbit is about to hand the keyboard to a window of another app on
/// purpose: `create_mail_draft` opens Mail's reply window, into which the user pastes the text
/// Orbit put on the clipboard. The panel then stays visible without taking the keyboard back,
/// so the card that says what to do stays in view (see `KeyboardHandoff`). Live: `PanelState`;
/// tests and services built without a panel use `NoKeyboardHandoff`.
protocol KeyboardHandoffAnnouncing: Sendable {
    /// Right before Orbit asks `app` (a bundle identifier) to open its window. Returns the
    /// hand-off, or nil when there is none (the panel is not visible).
    func beginKeyboardHandoff(to app: String) async -> UUID?
    /// The window opened (`opened`), or opening it failed or was stopped.
    func endKeyboardHandoff(_ handoff: UUID?, opened: Bool) async
}

/// No panel to keep visible (tests, services built without one).
struct NoKeyboardHandoff: KeyboardHandoffAnnouncing {
    func beginKeyboardHandoff(to app: String) async -> UUID? { nil }
    func endKeyboardHandoff(_ handoff: UUID?, opened: Bool) async {}
}

/// Orbit's own hand-off of the keyboard to another app's window (Mail's reply window). While
/// Orbit opens the window (and for a few seconds after it opened, because the app takes the
/// keyboard a moment later), the panel stays visible when it loses the keyboard to another app,
/// without taking it back. That happens once per hand-off; afterwards the panel closes as
/// always: on a click outside it, with the hotkey or Escape once it has the keyboard again, or
/// when yet another app comes to the front. A click into the panel or closing it ends the
/// hand-off. So does another app coming to the front before the window took the keyboard (the
/// user went elsewhere): the panel then closes when it loses the keyboard, as always. If the
/// window does not open after all while the panel stays visible for it, the panel closes. Pure
/// (the time is passed in), so every decision is unit-tested.
struct KeyboardHandoff: Equatable, Sendable {
    /// How long after the window opened its taking the keyboard still counts: the app comes to
    /// the front a moment after its script returned.
    static let grace: TimeInterval = 5
    /// A hand-off whose end is never reported stops counting after this long (the agent
    /// loop's limit for a tool call).
    static let maximumDuration: TimeInterval = 90

    enum Phase: Equatable, Sendable {
        case idle
        /// Orbit is opening the window, since `since`.
        case opening(since: Date)
        /// The window opened at `at`; it may take the keyboard a moment later.
        case opened(at: Date)
        /// The window took the keyboard and the panel stayed visible without it.
        case keptVisible
    }

    private(set) var id: UUID?
    /// The app whose window takes the keyboard (bundle identifier).
    private(set) var app: String?
    /// When Orbit began opening the window.
    private(set) var startedAt: Date?
    private(set) var phase = Phase.idle

    /// Starts a hand-off to `app`, replacing any earlier one.
    @discardableResult
    mutating func begin(to app: String, now: Date) -> UUID {
        let id = UUID()
        self.id = id
        self.app = app
        startedAt = now
        phase = .opening(since: now)
        return id
    }

    /// The window opened, or not: a failed hand-off is over, an opened one still counts for
    /// `grace` seconds. A panel that already stayed visible stays so when the window opened;
    /// when it did not, the hand-off is over and the result is true: the panel, which stayed
    /// visible without the keyboard for nothing, closes. Reports for an earlier hand-off change
    /// nothing.
    @discardableResult
    mutating func end(_ handoff: UUID, opened: Bool, now: Date) -> Bool {
        guard handoff == id else { return false }
        switch phase {
        case .opening:
            if opened {
                phase = .opened(at: now)
            } else {
                reset()
            }
            return false
        case .keptVisible where !opened:
            reset()
            return true
        case .idle, .opened, .keptVisible:
            return false
        }
    }

    /// Whether the panel losing the keyboard to another app at `now` belongs to the hand-off.
    func isHandingOff(at now: Date) -> Bool {
        switch phase {
        case .idle, .keptVisible: false
        case .opening(let since): now.timeIntervalSince(since) <= Self.maximumDuration
        case .opened(let at): now.timeIntervalSince(at) <= Self.grace
        }
    }

    /// The panel stayed visible without the keyboard (see `isHandingOff(at:)`).
    mutating func keepPanelVisible() {
        guard id != nil else { return }
        phase = .keptVisible
    }

    var isPanelKeptVisible: Bool {
        phase == .keptVisible
    }

    /// Whether the keyboard is with the other app's window at `now`, or about to go there: while Orbit opens it,
    /// shortly after it opened, and while the panel stays visible without the keyboard, until the panel takes it
    /// back. Keys such as ⌘↩ meanwhile reach that window, not the panel.
    func isKeyboardAway(at now: Date) -> Bool {
        isPanelKeptVisible || isHandingOff(at: now)
    }

    /// Another app came to the front: the result says whether the panel closes now when it does
    /// not have the keyboard. While the panel stays visible without the keyboard, such an app
    /// closes it, like a click outside does. While the window is still opening (or just opened
    /// and has not taken the keyboard yet), the user went elsewhere: the hand-off is over, and
    /// the panel closes when it loses the keyboard, as always (the order in which macOS reports
    /// the app and the lost keyboard does not matter). The hand-off's own app (whose activation
    /// may be reported late) and Orbit change nothing.
    mutating func appDidActivate(_ bundleIdentifier: String?, isOrbit: Bool) -> Bool {
        guard id != nil, !isOrbit, bundleIdentifier != app else { return false }
        switch phase {
        case .opening, .opened:
            reset()
            return true
        case .keptVisible:
            return true
        case .idle:
            return false
        }
    }

    /// The panel took the keyboard back: from now on it closes as always.
    mutating func panelDidBecomeKey() {
        if isPanelKeptVisible {
            reset()
        }
    }

    /// The panel closed (or a new hand-off replaces this one).
    mutating func reset() {
        self = KeyboardHandoff()
    }

    /// The card the hand-off brought: the newest mail reply card created since it began.
    func replyCard(in items: [ChatItem]) -> ChatItem? {
        guard let startedAt else { return nil }
        return items.last { item in
            guard item.createdAt >= startedAt, case .card(.mailDraft(let draft)) = item.kind else { return false }
            return draft.reply != nil
        }
    }
}
