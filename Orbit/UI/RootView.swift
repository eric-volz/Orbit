import AppKit
import SwiftUI

/// What the panel shows below the input.
enum PanelMode: Hashable, Sendable {
    /// Only the input bar (and "Continue chat" while the chat is parked).
    case compact
    /// Instant results and "Orbit fragen".
    case search
    /// The chat.
    case chat

    /// The chat while there is one, unless it is parked after a pause (see
    /// `ChatParking`); otherwise search as soon as something is typed.
    static func resolve(hasConversation: Bool, isChatParked: Bool = false, inputText: String) -> PanelMode {
        if hasConversation, !isChatParked { return .chat }
        return inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .compact : .search
    }
}

/// The panel's content: context chips, the input bar and, depending on the
/// state, instant results or the chat. It reports its natural height to
/// `PanelState.preferredContentHeight`; the panel controller resizes the
/// window accordingly (growing downward).
struct RootView: View {
    let environment: AppEnvironment

    @State private var selection = SearchSelection()
    @State private var chromeHeight: CGFloat = 58
    @State private var chatScroller = ChatScroller()
    @State private var fileCards: FileCardCoordinator
    /// Opens notes from note cards in Notes.
    @State private var noteCards: NoteCardActions
    /// Opens messages from mail cards, shows drafts in Mail and copies the text of replies.
    @State private var mailCards: MailCardActions
    /// Shows events from event cards in Calendar and reminders in Reminders.
    @State private var calendarCards: CalendarCardActions
    /// Thumbnails of photo cards, and showing their photos in Photos.
    @State private var photoCards: PhotoCardActions
    /// ⌘Return and the confirmation card waiting for the user.
    @State private var confirmationKeyboard = ConfirmationKeyboard()
    /// A short explanation under the input when Return did nothing.
    @State private var hints: InputHintPresenter
    /// The hand-off of the keyboard to Mail's reply window whose card was shown and announced.
    @State private var revealedHandoff: UUID?
    /// The query whose result count VoiceOver heard last.
    @State private var announcedQuery: String?
    /// A file result being checked before it opens (Return is ignored meanwhile).
    @State private var isCheckingResult = false
    @FocusState private var isInputFocused: Bool

    init(environment: AppEnvironment) {
        self.environment = environment
        let agentLoop = environment.agentLoop
        _fileCards = State(initialValue: FileCardCoordinator(
            quickLook: environment.quickLook, workspace: environment.services.workspace,
            policy: environment.services.fileAccess, announcer: environment.services.announcer,
            cardIDs: { FileCardCoordinator.keyboardCardIDs(in: agentLoop.items) }
        ))
        _noteCards = State(initialValue: NoteCardActions(notes: NotesService(runner: environment.services.appleScripts)))
        _mailCards = State(initialValue: MailCardActions(mail: MailService(runner: environment.services.appleScripts),
                                                         opener: environment.services.messageLinks,
                                                         pasteboard: environment.services.pasteboard))
        _calendarCards = State(initialValue: CalendarCardActions(opener: environment.services.calendarApps))
        _photoCards = State(initialValue: PhotoCardActions(photos: PhotosService(runner: environment.services.appleScripts),
                                                           opener: environment.services.photosApp,
                                                           thumbnails: environment.services.photoThumbnails))
        _hints = State(initialValue: InputHintPresenter(announcer: environment.services.announcer))
    }

    private var agentLoop: AgentLoop { environment.agentLoop }
    private var panelState: PanelState { environment.panelState }
    private var instantSearch: InstantSearch { environment.instantSearch }
    private var chatParking: ChatParking { environment.chatParking }
    private var announcer: any Announcing { environment.services.announcer }

    private var mode: PanelMode {
        PanelMode.resolve(hasConversation: agentLoop.hasConversation, isChatParked: chatParking.isParked,
                          inputText: panelState.inputText)
    }

    /// Height available below the input bar.
    private var bodyMaxHeight: CGFloat {
        max(0, panelState.maximumContentHeight - chromeHeight - 1)
    }

    var body: some View {
        @Bindable var panelState = environment.panelState
        let mode = mode

        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if !panelState.attachments.isEmpty {
                    ContextChips(attachments: panelState.attachments, onRemove: removeAttachment)
                        .padding(.horizontal, Theme.contentInset)
                        .padding(.top, 12)
                }
                InputBar(
                    text: $panelState.inputText,
                    mode: mode,
                    isRunning: agentLoop.isRunning,
                    isFocused: $isInputFocused,
                    commands: inputCommands,
                    onStop: { agentLoop.cancel() },
                    onNewChat: { startNewChat() },
                    canContinueChat: mode == .compact && chatParking.isParked
                )
                if let inputHint = hints.hint {
                    Text(inputHint.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, Theme.contentInset + 36)
                        .padding(.bottom, 10)
                        .transition(.opacity)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                chromeHeight = height
            }

            switch mode {
            case .compact:
                if chatParking.isParked {
                    Divider()
                    ContinueChatRow(title: agentLoop.conversation.title, action: continueChat)
                }
            case .search:
                Divider()
                SearchView(
                    query: panelState.inputText,
                    groups: instantSearch.groups,
                    selection: selection,
                    maxHeight: bodyMaxHeight,
                    onAsk: sendToAgent,
                    onOpen: openResult(at:)
                )
            case .chat:
                Divider()
                ChatView(
                    items: agentLoop.items,
                    isRunning: agentLoop.isRunning,
                    isSigningIn: agentLoop.isSigningIn,
                    conversationID: agentLoop.conversationID,
                    maxHeight: bodyMaxHeight,
                    approveShortcutEnabled: panelState.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    scroller: chatScroller,
                    actions: chatActions
                )
                .environment(fileCards)
                .environment(noteCards)
                .environment(mailCards)
                .environment(calendarCards)
                .environment(photoCards)
                .environment(confirmationKeyboard)
            }
        }
        // Ideal width 720 so hosting views that size to their content keep the panel width.
        .frame(idealWidth: Theme.panelWidth, maxWidth: Theme.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            reportHeight(height)
        }
        // Min and max so the frame always takes the window's size: while the panel
        // animates to a new height, the content stays pinned to the top edge.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        // Only web and mail links in anything the model wrote (also outside MarkdownView).
        .environment(\.openURL, OpenURLAction { url in
            MarkdownLinkPolicy.allows(url) ? .systemAction : .discarded
        })
        // Date pickers in the interface's language (see `AppLanguage.locale`).
        .environment(\.locale, AppLanguage.locale)
        // Escape while something other than the input has focus.
        .onExitCommand { environment.handleEscape() }
        .onAppear { focusInput(selectAll: false) }
        .onChange(of: panelState.showCount) {
            focusInput(selectAll: true)
            guard mode != .chat else { return }
            // Files may have changed while the panel was hidden; text typed for a chat that is
            // gone now (history cleared in Settings) is a search. (A chat with unsent text is
            // never parked, see ChatParking.)
            instantSearch.refresh()
            instantSearch.search(panelState.inputText)
        }
        .onChange(of: panelState.inputText) { _, text in inputChanged(text) }
        .onChange(of: instantSearch.isSearching) { _, isSearching in
            if !isSearching { announceResultCount() }
        }
        .onChange(of: fileCards.openFailure) { _, failure in
            guard let failure else { return }
            hints.show(failure.reason == .notFound ? .fileNotFound(name: failure.name) : .cannotOpen(name: failure.name))
        }
        .onChange(of: noteCards.openFailure) { _, failure in
            guard let failure else { return }
            hints.show(InputHint(noteFailure: failure))
        }
        .onChange(of: mailCards.failure) { _, failure in
            guard let failure else { return }
            hints.show(InputHint(mailFailure: failure))
        }
        .onChange(of: calendarCards.failure) { _, failure in
            guard let failure else { return }
            hints.show(InputHint(calendarFailure: failure))
        }
        .onChange(of: photoCards.failure) { _, failure in
            guard let failure else { return }
            hints.show(InputHint(photoFailure: failure))
        }
        // Orbit handed the keyboard to Mail's reply window: its card says the text is on the clipboard.
        .onChange(of: agentLoop.items.count) { revealHandoffReplyCard() }
        .onChange(of: panelState.keyboardHandoff) { revealHandoffReplyCard() }
        // Another chat: a preview never outlives its card, and the keyboard goes back to the input.
        .onChange(of: agentLoop.conversationID) {
            environment.quickLook.close()
            focusInput(selectAll: false)
        }
        // The waiting card was decided; if it had taken the keyboard (⌘Return brought it into view), the input
        // takes it back.
        .onChange(of: agentLoop.pendingConfirmation?.id) { old, _ in
            guard let old, confirmationKeyboard.cardDone(old) else { return }
            focusInput(selectAll: false)
        }
        .onChange(of: instantSearch.results.map(\.id)) { _, ids in selection.updateResults(ids) }
    }

    // MARK: Actions

    private var inputCommands: InputCommands {
        InputCommands(
            submit: submit,
            commandSubmit: commandSubmit,
            moveUp: {
                if mode == .compact, chatParking.isParked {
                    continueChat()
                    return true
                }
                guard mode == .search else { return false }
                selection.moveUp()
                announceHighlight()
                return true
            },
            moveDown: {
                guard mode == .search else { return false }
                selection.moveDown()
                announceHighlight()
                return true
            },
            openResult: { number in
                guard mode == .search else { return false }
                if let index = SearchSelection.resultIndex(forShortcut: number, resultCount: instantSearch.results.count) {
                    openResult(at: index)
                }
                return true
            },
            scroll: { target in
                guard mode == .chat else { return false }
                chatScroller.scroll(target)
                // Handled even at the end, so the keys never reach the text field.
                return true
            },
            focusCard: {
                guard mode == .chat, let card = latestCardID else { return false }
                fileCards.focus(card: card)
                return true
            },
            removeLastChip: {
                guard let chip = ContextChipRemoval.chipToRemove(inputText: panelState.inputText,
                                                                 attachments: panelState.attachments) else { return false }
                removeAttachment(chip)
                return true
            },
            escape: { environment.handleEscape() }
        )
    }

    /// The most recent card the keyboard can reach (files, mails, notes,
    /// events, reminders, photos, a draft's buttons): the one Tab in the input moves to.
    private var latestCardID: UUID? {
        FileCardCoordinator.keyboardCardIDs(in: agentLoop.items).last
    }

    private var chatActions: ChatActions {
        ChatActions(
            resolveConfirmation: { id, decision in agentLoop.resolveConfirmation(id, decision: decision) },
            retry: { agentLoop.retry() },
            openSettings: { tab in panelState.openSettings(tab) },
            signIn: { agentLoop.signInAndRetry() },
            cancelSignIn: { agentLoop.cancelSignIn() },
            newChat: { startNewChat() }
        )
    }

    /// Return: in search mode opens the highlighted result or asks Orbit; in
    /// chat mode sends the message (ignored while a response is running).
    private func submit() {
        switch mode {
        case .compact:
            break
        case .chat:
            sendToAgent()
        case .search:
            switch selection.returnAction(commandPressed: false) {
            case .askAgent: sendToAgent()
            case .openResult(let index): openResult(at: index)
            }
        }
    }

    /// ⌘Return in the input: sends typed text; with an empty input it runs
    /// the waiting confirmation card when the user can see it, otherwise
    /// brings the card into view first (`ConfirmationKeyboard`). The card's
    /// own key equivalent handles the usual case (a card in view) before
    /// the input gets the key. False when there is nothing to do.
    private func commandSubmit() -> Bool {
        let pending = agentLoop.pendingConfirmation?.id
        // The input has the keyboard: only a card in view (or just brought into view) may run.
        let action = ConfirmationKeyboard.commandReturn(inputText: panelState.inputText, pendingRequestID: pending,
                                                        mayRunPending: pending.map(confirmationKeyboard.mayRunFromInput) ?? false)
        switch action {
        case .send:
            sendToAgent()
        case .approve(let requestID):
            confirmationKeyboard.approve(requestID)
        case .reveal(let requestID):
            revealConfirmation(requestID)
        case .none:
            return false
        }
        return true
    }

    /// Scrolls the waiting card into view and gives it the keyboard; the hint
    /// (read out by VoiceOver) says how to run or cancel it.
    private func revealConfirmation(_ requestID: UUID) {
        let item = agentLoop.items.last { item in
            if case .confirmation(let state) = item.kind { return state.request.id == requestID }
            return false
        }
        if let item {
            fileCards.scroll(to: .card(item.id))
        }
        confirmationKeyboard.reveal(requestID)
        hints.show(.confirmationWaiting)
    }

    private func sendToAgent() {
        let text = panelState.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard !agentLoop.isRunning else {
            // Keep the text and say why nothing happened.
            hints.show(agentLoop.pendingConfirmation != nil ? .confirmFirst : .stillRunning)
            return
        }
        hints.hide()
        let attachments = panelState.attachments
        if chatParking.isParked {
            // After a pause the text starts a new chat, like ⌘N and Return.
            environment.startNewChat()
        }
        agentLoop.send(text, attachments: attachments)
        // A capture still running belongs to this message's open: its chips would come too late.
        environment.contextCapture.messageSent()
        panelState.inputText = ""
        panelState.attachments = []
        instantSearch.clear()
        selection = SearchSelection()
    }

    /// Opens a result and closes the panel. A file is checked first (off the
    /// main actor): when it was moved or deleted since the search, the panel
    /// stays and says so, and the results are searched again.
    private func openResult(at index: Int) {
        let results = instantSearch.results
        guard results.indices.contains(index), !isCheckingResult else { return }
        let result = results[index]
        guard case .file(let url) = result.kind else {
            finishOpening(result)
            return
        }
        isCheckingResult = true
        let workspace = environment.services.workspace
        Task { @MainActor in
            let exists = await workspace.itemExists(at: url)
            isCheckingResult = false
            guard exists else {
                hints.show(.fileNotFound(name: result.title))
                instantSearch.refresh()
                return
            }
            finishOpening(result)
        }
    }

    private func finishOpening(_ result: SearchResult) {
        hints.hide()
        instantSearch.open(result)
        panelState.inputText = ""
        panelState.closePanel()
    }

    /// ↑ in the empty input or "Continue chat": the parked chat comes back,
    /// the keyboard in the input. The chat view appears scrolled to its end.
    private func continueChat() {
        chatParking.unpark()
        focusInput(selectAll: false)
    }

    /// VoiceOver says which row the arrow keys highlighted: the keyboard stays
    /// in the input, so it would not notice.
    private func announceHighlight() {
        announcer.announce(SearchAnnouncement.text(for: selection, query: panelState.inputText,
                                                   results: instantSearch.results), priority: .high)
    }

    /// Once per query, when its search is done: how many results there are.
    private func announceResultCount() {
        let query = panelState.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard mode == .search, query != announcedQuery else { return }
        announcedQuery = query
        announcer.announce(SearchAnnouncement.resultCount(instantSearch.results.count), priority: .medium)
    }

    /// ⌘N, the input's button and a notice's "New Chat": a request the chat
    /// could no longer answer goes into the new chat's input (see
    /// `AppEnvironment.startNewChat()`).
    private func startNewChat() {
        environment.startNewChat()
        selection = SearchSelection()
        focusInput(selectAll: false)
    }

    /// A chip's ×, VoiceOver's "Remove" or ⌫ in the empty input: the chip
    /// goes, and VoiceOver hears which one.
    private func removeAttachment(_ attachment: ContextAttachment) {
        panelState.attachments.removeAll { $0.id == attachment.id }
        announcer.announce(ContextChipRemoval.announcement(for: attachment), priority: .high)
    }

    private func inputChanged(_ text: String) {
        guard mode != .chat else { return }
        selection.reset()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            instantSearch.clear()
            announcedQuery = nil
        } else {
            instantSearch.search(text)
        }
    }

    /// Once per hand-off, when the reply's card is in the chat: the chat scrolls it into view
    /// and VoiceOver (whose focus went to Mail's reply window) hears where the text is.
    private func revealHandoffReplyCard() {
        let handoff = panelState.keyboardHandoff
        guard let id = handoff.id, id != revealedHandoff, let card = handoff.replyCard(in: agentLoop.items),
              case .card(.mailDraft(let draft)) = card.kind, let reply = draft.reply else { return }
        revealedHandoff = id
        fileCards.scroll(to: .card(card.id))
        announcer.announce(MailDraftCardView.replyStatus(reply, hasText: !draft.body.isEmpty), priority: .medium)
    }

    private func reportHeight(_ height: CGFloat) {
        let rounded = height.rounded(.up)
        if abs(panelState.preferredContentHeight - rounded) >= 0.5 {
            panelState.preferredContentHeight = rounded
        }
    }

    /// Focuses the input. When the panel is shown again in search mode, the
    /// previous query is selected so typing replaces it (like Spotlight).
    private func focusInput(selectAll: Bool) {
        isInputFocused = true
        Task { @MainActor in
            // The panel may become key only after this state change is processed.
            await Task.yield()
            isInputFocused = true
            if selectAll, mode != .chat, !panelState.inputText.isEmpty {
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }
}

/// Shows an `InputHint` under the input for a few seconds and has VoiceOver
/// read it: the keyboard stays where it was, so VoiceOver would not notice it.
@MainActor
@Observable
final class InputHintPresenter {
    static let duration: Duration = .seconds(4)

    private(set) var hint: InputHint?
    /// Whether macOS asks to reduce motion (Accessibility > Display), read for every change.
    @ObservationIgnored var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    @ObservationIgnored private let announcer: any Announcing
    @ObservationIgnored private let duration: Duration
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    init(announcer: any Announcing, duration: Duration = InputHintPresenter.duration) {
        self.announcer = announcer
        self.duration = duration
    }

    /// How the hint comes and goes: it changes the height above the chat or
    /// the results, which slide with it, not with Reduce Motion.
    var animation: Animation? {
        reducesMotion() ? nil : .easeOut(duration: 0.15)
    }

    func show(_ hint: InputHint) {
        withAnimation(animation) { self.hint = hint }
        announcer.announce(hint.text, priority: .high)
        hideTask?.cancel()
        let duration = duration
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        hideTask = nil
        guard hint != nil else { return }
        withAnimation(animation) { hint = nil }
    }
}

/// Why Return (or opening a file) did nothing.
enum InputHint: Equatable, Sendable {
    /// A confirmation card is waiting.
    case confirmFirst
    /// ⌘Return brought the waiting confirmation card into view.
    case confirmationWaiting
    /// An answer is still running.
    case stillRunning
    /// A file from a card or instant search was moved or deleted since.
    case fileNotFound(name: String)
    /// No app opened a file from a card.
    case cannotOpen(name: String)
    /// A note from a card no longer exists in Notes.
    case noteNotFound(title: String)
    /// macOS does not let Orbit control Notes.
    case notesNotPermitted
    /// Notes could not show a note from a card.
    case noteNotOpened(title: String)
    /// No app opened a message from a mail card.
    case mailNotOpened(subject: String)
    /// The draft of a draft card is no longer open in Mail.
    case mailDraftClosed
    /// macOS does not let Orbit control Mail.
    case mailNotPermitted
    /// Mail did not show the draft of a draft card.
    case mailDraftNotShown
    /// The text of a reply card could not be put on the clipboard.
    case mailTextNotCopied
    /// Calendar did not open for an event card.
    case calendarNotOpened
    /// Reminders did not open for a reminder card.
    case remindersNotOpened
    /// macOS does not let Orbit control Photos (a photo card's tile).
    case photosNotPermitted
    /// Photos does not have the photo of a tile; Photos opened instead.
    case photoNotFound
    /// Photos could not show the photo of a tile; Photos opened instead.
    case photoNotShown
    /// Photos did not open for a photo card.
    case photosNotOpened

    init(noteFailure failure: NoteCardActions.OpenFailure) {
        let title = failure.title.isEmpty ? String(localized: "New Note") : failure.title
        switch failure.reason {
        case .notFound: self = .noteNotFound(title: title)
        case .notPermitted: self = .notesNotPermitted
        case .failed: self = .noteNotOpened(title: title)
        }
    }

    init(mailFailure failure: MailCardActions.Failure) {
        switch failure.reason {
        case .messageNotOpened:
            self = .mailNotOpened(subject: failure.subject.isEmpty ? String(localized: "(No Subject)") : failure.subject)
        case .draftClosed: self = .mailDraftClosed
        case .notPermitted: self = .mailNotPermitted
        case .draftNotShown: self = .mailDraftNotShown
        case .textNotCopied: self = .mailTextNotCopied
        }
    }

    init(calendarFailure failure: CalendarCardActions.Failure) {
        switch failure.reason {
        case .calendarNotOpened: self = .calendarNotOpened
        case .remindersNotOpened: self = .remindersNotOpened
        }
    }

    init(photoFailure failure: PhotoCardActions.Failure) {
        switch failure.reason {
        case .notPermitted: self = .photosNotPermitted
        case .notFound: self = .photoNotFound
        case .notShown: self = .photoNotShown
        case .photosNotOpened: self = .photosNotOpened
        }
    }

    var text: String {
        switch self {
        case .confirmFirst: String(localized: "Please confirm or cancel the action above first. Your message stays here.")
        case .confirmationWaiting:
            String(localized: "The action above is waiting for your confirmation: ⌘↩ runs it, ⌘. cancels it.")
        case .stillRunning: String(localized: "Orbit is still answering. Wait a moment or stop the answer with Esc.")
        case .fileNotFound(let name):
            String(format: String(localized: "“%@” was not found. It may have been moved or deleted."), name)
        case .cannotOpen(let name): String(format: String(localized: "“%@” could not be opened."), name)
        case .noteNotFound(let title):
            String(format: String(localized: "The note “%@” was not found in Notes. It may have been deleted."), title)
        case .notesNotPermitted:
            String(localized: "Orbit is not allowed to control Notes. You can allow it in Orbit’s settings under “Permissions”.")
        case .noteNotOpened(let title):
            String(format: String(localized: "The note “%@” could not be opened in Notes."), title)
        case .mailNotOpened(let subject):
            String(format: String(localized: "The email “%@” could not be opened in Mail."), subject)
        case .mailDraftClosed:
            String(localized: "The draft is no longer open in Mail. If you saved it, you’ll find it in “Drafts”.")
        case .mailNotPermitted:
            String(localized: "Orbit is not allowed to control Mail. You can allow it in Orbit’s settings under “Permissions”.")
        case .mailDraftNotShown:
            String(localized: "The draft could not be shown in Mail.")
        case .mailTextNotCopied:
            String(localized: "The text could not be copied to the clipboard.")
        case .calendarNotOpened:
            String(localized: "The Calendar app could not be opened.")
        case .remindersNotOpened:
            String(localized: "The Reminders app could not be opened.")
        case .photosNotPermitted:
            String(localized: "Orbit is not allowed to control Photos, so it cannot show the photo. You can allow it in Orbit’s settings under “Permissions”.")
        case .photoNotFound:
            String(localized: "Photos did not find the photo, so Orbit opened the Photos app instead.")
        case .photoNotShown:
            String(localized: "Photos could not show the photo, so Orbit opened the Photos app instead.")
        case .photosNotOpened:
            String(localized: "The Photos app could not be opened.")
        }
    }
}
