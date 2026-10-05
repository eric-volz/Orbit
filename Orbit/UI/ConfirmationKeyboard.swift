import Foundation
import Observation

/// ⌘Return and the confirmation card that waits for the user.
///
/// The card's run button has ⌘Return as its key equivalent while the input is
/// empty and the card may be run (`mayRun`): it is in view. Otherwise ⌘Return
/// reaches the input, which asks `commandReturn(inputText:pendingRequestID:mayRunPending:)`
/// what to do: send the typed text; approve the waiting card (with the values
/// the user edited on it); or, when it is not in view (scrolled away, or just
/// appearing), scroll it into view and give it the keyboard first, so the
/// next ⌘Return runs what the user now sees. ⌘Return never runs a card the
/// user cannot see, and is never swallowed without an effect.
///
/// Cards report whether they are in view (their frame against the chat's
/// visible height, which ChatView reports); a card ⌘Return brought into view,
/// or whose field has the keyboard, may be run even when it cannot tell:
/// at worst the user presses ⌘Return once more. A card's field holds the
/// keyboard only until the keyboard leaves the card (the user clicks back
/// into the input, say); ⌘Return in the input never counts it. RootView
/// creates the coordinator and hands it to the chat.
@MainActor
@Observable
final class ConfirmationKeyboard {
    /// A request to one card, by the id of its confirmation request.
    struct Request: Equatable, Sendable {
        var requestID: UUID
        var count: Int
    }

    /// What ⌘Return in the input does.
    enum Action: Equatable, Sendable {
        /// Send the typed text (while a card waits, the input explains why it does not go yet).
        case send
        /// Approve the waiting card, which the user can see, with its edited values.
        case approve(UUID)
        /// Scroll the waiting card into view and give it the keyboard.
        case reveal(UUID)
        /// Nothing to send or approve.
        case none
    }

    /// The visible height of the chat (ChatView reports it); nil outside a chat.
    var viewportHeight: CGFloat?
    /// The waiting cards that are in view.
    private(set) var cardsInView: Set<UUID> = []
    /// The card ⌘Return brought into view last, until it leaves the view again.
    private(set) var revealedCard: UUID?
    /// The card that took the keyboard from the input: the input takes it
    /// back once the card is decided.
    private(set) var keyboardHolder: UUID?
    /// Asks a card to approve itself with its edited values.
    private(set) var approveRequest: Request?
    /// Asks a card to take the keyboard (its first editable field).
    private(set) var focusRequest: Request?
    @ObservationIgnored private var requestCount = 0

    nonisolated init() {}

    /// ⌘Return in the input: typed text is sent; otherwise a waiting card is
    /// approved when it may be run, or brought into view when it may not.
    nonisolated static func commandReturn(inputText: String, pendingRequestID: UUID?, mayRunPending: Bool) -> Action {
        guard inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .send }
        guard let pendingRequestID else { return .none }
        return mayRunPending ? .approve(pendingRequestID) : .reveal(pendingRequestID)
    }

    /// Whether a card with `frame` (in the coordinate space of the chat's
    /// scroll view, whose visible part is `viewportHeight` high) is in view:
    /// wholly, or, when it is taller than the view, filling it. Without a
    /// viewport (outside a chat, or before the chat reported it) a card counts
    /// as in view.
    nonisolated static func isInView(frame: CGRect, viewportHeight: CGFloat?, tolerance: CGFloat = 2) -> Bool {
        guard let viewportHeight else { return true }
        guard viewportHeight > 0, frame.height > 0 else { return false }
        let visible = min(frame.maxY, viewportHeight) - max(frame.minY, 0)
        return visible >= min(frame.height, viewportHeight) - tolerance
    }

    /// Whether ⌘Return may run the card: it is in view, ⌘Return just brought
    /// it into view, or one of its fields has the keyboard.
    func mayRun(_ requestID: UUID) -> Bool {
        mayRunFromInput(requestID) || keyboardHolder == requestID
    }

    /// Whether ⌘Return in the input may run the card: it is in view, or
    /// ⌘Return just brought it into view. The input has the keyboard, so none
    /// of the card's fields has it, whatever the card last reported.
    func mayRunFromInput(_ requestID: UUID) -> Bool {
        cardsInView.contains(requestID) || revealedCard == requestID
    }

    /// A card came into view or left it. A card that leaves the view after
    /// ⌘Return brought it there needs ⌘Return to bring it back first.
    func setInView(_ inView: Bool, requestID: UUID) {
        guard inView != cardsInView.contains(requestID) else { return }
        if inView {
            cardsInView.insert(requestID)
        } else {
            cardsInView.remove(requestID)
            if revealedCard == requestID { revealedCard = nil }
        }
    }

    /// ⌘Return for a card the user can see.
    func approve(_ requestID: UUID) {
        requestCount += 1
        approveRequest = Request(requestID: requestID, count: requestCount)
    }

    /// ⌘Return for a card out of view: the chat scrolls to it, and it takes the keyboard.
    func reveal(_ requestID: UUID) {
        requestCount += 1
        revealedCard = requestID
        focusRequest = Request(requestID: requestID, count: requestCount)
    }

    /// The card answered a request.
    func didHandle(_ request: Request) {
        if approveRequest == request { approveRequest = nil }
        if focusRequest == request { focusRequest = nil }
    }

    /// The card gave the keyboard to one of its fields.
    func cardTookKeyboard(_ requestID: UUID) {
        keyboardHolder = requestID
    }

    /// The keyboard left the waiting card's fields (the user clicked into the
    /// input, say): from now on ⌘Return runs the card only while it is in view.
    func cardLostKeyboard(_ requestID: UUID) {
        if keyboardHolder == requestID { keyboardHolder = nil }
    }

    /// The card was decided, or its request ended. True when it had taken the
    /// keyboard from the input, which takes it back.
    func cardDone(_ requestID: UUID) -> Bool {
        cardsInView.remove(requestID)
        if revealedCard == requestID { revealedCard = nil }
        if approveRequest?.requestID == requestID { approveRequest = nil }
        if focusRequest?.requestID == requestID { focusRequest = nil }
        guard keyboardHolder == requestID else { return false }
        keyboardHolder = nil
        return true
    }
}
