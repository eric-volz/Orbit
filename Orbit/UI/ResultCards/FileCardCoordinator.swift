import AppKit
import Observation

/// Connects the chat's file cards with the rest of the panel: opens and
/// reveals files through the workspace service (a file that cannot be opened
/// becomes `openFailure`, which RootView explains under the input), copies
/// paths, starts Quick Look, tells VoiceOver which row the keyboard selected,
/// moves the keyboard from the input to a card and between cards (Tab,
/// Shift-Tab) and asks the chat to scroll to the card or row the keyboard went
/// to. The chat only builds the rows near the visible part, so a card is
/// scrolled into view before it takes the keyboard. Moving the keyboard covers
/// every card it can reach: files, mails, notes, events, reminders and photos,
/// and mail drafts with buttons (see `CardKeyboard`). RootView creates it;
/// cards without one (snapshots of single views) only select rows.
@MainActor
@Observable
final class FileCardCoordinator {
    /// Asks a card to take the keyboard.
    struct FocusRequest: Equatable, Sendable {
        var cardID: UUID
        var count: Int
    }

    /// Asks the chat to scroll a card or one of its rows into view.
    struct ScrollRequest: Equatable, Sendable {
        enum Target: Hashable, Sendable {
            /// The chat item of a card.
            case card(UUID)
            /// A row, see `rowID(card:index:)`.
            case row(String)
        }

        var target: Target
        var count: Int
    }

    /// A file the user wanted to open that is gone or has no app to open it.
    struct OpenFailure: Equatable, Sendable {
        enum Reason: Sendable {
            /// Moved or deleted since the card was made.
            case notFound
            case cannotOpen
        }

        var name: String
        var reason: Reason
        /// Tells failures for the same file apart.
        var count: Int
    }

    /// The latest focus request; the card clears it once it has the keyboard.
    private(set) var focusRequest: FocusRequest?
    private(set) var scrollRequest: ScrollRequest?
    /// The latest file that could not be opened.
    private(set) var openFailure: OpenFailure?

    @ObservationIgnored let quickLook: QuickLookController?
    @ObservationIgnored private let workspace: (any FileWorkspace)?
    /// Decides whether a Finder alias's target may be opened; without it,
    /// aliases are shown in Finder.
    @ObservationIgnored private let policy: FileAccessPolicy?
    @ObservationIgnored private let pasteboard: NSPasteboard?
    @ObservationIgnored private let announcer: (any Announcing)?
    /// The chat's file cards with files, in chat order.
    @ObservationIgnored private let cardIDs: () -> [UUID]
    @ObservationIgnored private var requestCount = 0

    init(quickLook: QuickLookController?, workspace: (any FileWorkspace)?, policy: FileAccessPolicy? = nil,
         pasteboard: NSPasteboard? = .general, announcer: (any Announcing)? = nil,
         cardIDs: @escaping () -> [UUID] = { [] }) {
        self.quickLook = quickLook
        self.workspace = workspace
        self.policy = policy
        self.pasteboard = pasteboard
        self.announcer = announcer
        self.cardIDs = cardIDs
    }

    /// The scroll identity of a card's row.
    nonisolated static func rowID(card: UUID, index: Int) -> String {
        "\(card.uuidString)-row-\(index)"
    }

    /// The chat items whose cards take the keyboard, in order: files, mails,
    /// notes, events and reminders with rows, photos with tiles, and mail
    /// drafts with buttons.
    nonisolated static func keyboardCardIDs(in items: [ChatItem]) -> [UUID] {
        items.compactMap { item in
            guard case .card(let card) = item.kind, takesKeyboard(card) else { return nil }
            return item.id
        }
    }

    /// Whether the keyboard can select something on the card.
    nonisolated static func takesKeyboard(_ card: ResultCard) -> Bool {
        switch card {
        case .files(let items): !items.isEmpty
        case .mails(let items): !items.isEmpty
        case .notes(let items): !items.isEmpty
        case .mailDraft(let draft): !MailDraftButton.available(for: draft).isEmpty
        case .events(let items): !items.isEmpty
        case .reminders(let items): !items.isEmpty
        case .photos(let items): !items.isEmpty
        case .contacts, .info: false
        }
    }

    // MARK: Actions (the user's, not tool calls)

    /// Opens the file with its default app, the folder in Finder. The agent
    /// chose what the card lists, so (like its `open_file`) anything that
    /// could run code when opened (apps, programs, scripts, installers, link
    /// files) is shown in Finder instead, where the user can open it. A Finder
    /// alias opens its target only when the target passes the same checks and
    /// the file access policy; otherwise the alias is shown in Finder. A file
    /// that was moved or deleted since, or that no app opens, becomes
    /// `openFailure`.
    @discardableResult
    func open(_ item: FileItem) -> Task<Void, Never>? {
        guard let workspace else { return nil }
        let url = item.url
        let policy = policy
        return Task {
            guard await workspace.itemExists(at: url) else {
                Log.panel.info("A card item to open no longer exists")
                reportFailure(of: item, .notFound)
                return
            }
            let verdict = await Task.detached(priority: .userInitiated) {
                OpenFileSafety.verdict(forOpening: url.path, policy: policy)
            }.value
            guard case .open(let target) = verdict else {
                Log.panel.info("A card item that could run code or is an alias to a denied target was shown in Finder instead")
                await workspace.reveal(url)
                return
            }
            let targetURL = URL(fileURLWithPath: target)
            do {
                try await workspace.open(targetURL)
            } catch {
                Log.panel.error("Opening a file from a card failed: \(String(describing: type(of: error)), privacy: .public)")
                reportFailure(of: item, await workspace.itemExists(at: targetURL) ? .cannotOpen : .notFound)
            }
        }
    }

    private func reportFailure(of item: FileItem, _ reason: OpenFailure.Reason) {
        openFailure = OpenFailure(name: item.name, reason: reason, count: (openFailure?.count ?? 0) + 1)
    }

    /// Shows the item selected in Finder.
    @discardableResult
    func reveal(_ item: FileItem) -> Task<Void, Never>? {
        guard let workspace else { return nil }
        let url = item.url
        return Task {
            await workspace.reveal(url)
        }
    }

    /// Puts the full path on the pasteboard; VoiceOver hears that it did
    /// (nothing on the screen changes).
    func copyPath(_ item: FileItem) {
        guard let pasteboard else { return }
        pasteboard.clearContents()
        pasteboard.setString(item.path, forType: .string)
        announcer?.announce(String(localized: "Path copied"), priority: .medium)
    }

    /// VoiceOver says which row the keyboard selected: it stays on the card
    /// and would not notice.
    func announceSelection(of item: FileItem, priority: NSAccessibilityPriorityLevel) {
        announce(FileCardFormat.announcement(for: item), priority: priority)
    }

    /// VoiceOver says what the keyboard selected on a card (a row, a button).
    func announce(_ text: String, priority: NSAccessibilityPriorityLevel) {
        announcer?.announce(text, priority: priority)
    }

    // MARK: Keyboard focus and scrolling

    /// Tab in the input: scrolls the card into view and gives it the keyboard.
    func focus(card: UUID) {
        requestCount += 1
        focusRequest = FocusRequest(cardID: card, count: requestCount)
        scroll(to: .card(card))
    }

    /// Tab or Shift-Tab in a card: the next or previous file card takes the
    /// keyboard. False at either end, where the keyboard moves on as usual
    /// (e.g. back to the input).
    @discardableResult
    func focusCard(nextTo card: UUID, backward: Bool) -> Bool {
        let ids = cardIDs()
        guard let index = ids.firstIndex(of: card) else { return false }
        let neighbor = backward ? index - 1 : index + 1
        guard ids.indices.contains(neighbor) else { return false }
        focus(card: ids[neighbor])
        return true
    }

    /// The card has the keyboard; the request is done.
    func didTakeFocus(_ request: FocusRequest) {
        if focusRequest == request {
            focusRequest = nil
        }
    }

    func scroll(to target: ScrollRequest.Target) {
        requestCount += 1
        scrollRequest = ScrollRequest(target: target, count: requestCount)
    }
}

/// Dragging a row out of a card.
enum FileDrag {
    /// The file itself for Finder, Mail and other apps: its URL, and for files
    /// also their content type (so apps that accept, say, images take it).
    static func itemProvider(for item: FileItem) -> NSItemProvider {
        let url = item.url
        if !item.isDirectory, let provider = NSItemProvider(contentsOf: url) {
            return provider
        }
        return NSItemProvider(object: url as NSURL)
    }
}
