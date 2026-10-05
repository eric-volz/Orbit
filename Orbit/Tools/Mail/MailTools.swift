import Foundation

/// The mail tools: search_mail, read_mail and create_mail_draft, in this
/// order in Settings too. None of them can send a message.
enum MailTools {
    static func all(context: MailToolContext) -> [any Tool] {
        [
            SearchMailTool(context: context),
            ReadMailTool(context: context),
            CreateMailDraftTool(context: context),
        ]
    }
}

/// What the mail tools share: Mail's scripts and Spotlight (injected, so tests
/// use mocks), Contacts for names, the clipboard for the text of replies, the
/// panel (which stays visible while Mail's reply window takes the keyboard),
/// the clock and the time zone.
struct MailToolContext: Sendable {
    var mail: MailService
    var spotlight: any MailSpotlightSearching
    var contacts: any ContactBook
    /// Takes the text of a reply, which the user pastes into Mail's reply window.
    var pasteboard: any PasteboardWriting
    /// Told when Mail's reply window is about to take the keyboard, so Orbit's
    /// panel (and the card that says the text is on the clipboard) stays visible.
    var keyboardHandoff: any KeyboardHandoffAnnouncing
    var now: @Sendable () -> Date
    var timeZone: TimeZone
    var locale: Locale
    var spotlightTimeout: Duration
    /// Mailboxes `mailbox: "all"` leaves out (trash, junk, drafts, outbox).
    var excludedMailboxNames: [String]
    /// Reads the beginning of a message file Spotlight found (for previews).
    var readMessageFile: @Sendable (String) -> Data?

    init(mail: MailService, spotlight: any MailSpotlightSearching = UnavailableMailSpotlight(),
         contacts: any ContactBook = UnavailableContactBook(), pasteboard: any PasteboardWriting = DisabledPasteboard(),
         keyboardHandoff: any KeyboardHandoffAnnouncing = NoKeyboardHandoff(),
         now: @escaping @Sendable () -> Date = { Date() },
         timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent,
         spotlightTimeout: Duration = .seconds(8), excludedMailboxNames: [String] = MailboxNames.excludedFromAll,
         readMessageFile: @escaping @Sendable (String) -> Data? = MailToolContext.readPrefix) {
        self.mail = mail
        self.spotlight = spotlight
        self.contacts = contacts
        self.pasteboard = pasteboard
        self.keyboardHandoff = keyboardHandoff
        self.now = now
        self.timeZone = timeZone
        self.locale = locale
        self.spotlightTimeout = spotlightTimeout
        self.excludedMailboxNames = excludedMailboxNames
        self.readMessageFile = readMessageFile
    }

    /// Bytes of a message file read for a preview: the text comes first in a
    /// message, attachments after it.
    static let previewFileBytes = 512 * 1024

    /// The first `previewFileBytes` of a file, or nil when it cannot be read.
    static func readPrefix(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: previewFileBytes)
    }

    /// Runs a Mail operation; a failed script run becomes the `ToolError` for
    /// the model (denied automation: `permissionDenied(.automationMail)`).
    func perform<Value: Sendable>(_ script: AppleScript, _ operation: () async throws -> Value) async throws -> Value {
        do {
            return try await operation()
        } catch let error as AppleScriptError {
            throw error.toolError(for: script)
        } catch MailFailure.messageNotFound {
            throw ToolError.notFound("Mail has no message with this id (anymore); it may have been moved or deleted. Search again with search_mail.")
        }
    }

    /// The `id` argument of read_mail and `reply_to_id` of create_mail_draft.
    static func locator(in arguments: ToolArguments, key: String) throws -> MailLocator? {
        guard let text = arguments.optionalString(key) else { return nil }
        guard let locator = MailID.locator(from: text) else {
            throw ToolError.invalidArgument("'\(key)' must be a message id exactly as search_mail returned it (mail:…).")
        }
        return locator
    }

    static let idDescription = "The message's id exactly as search_mail returned it (mail:…)."

    // MARK: Model text

    /// "2026-09-28 18:30" in the context's time zone.
    func date(_ date: Date) -> String {
        FileToolFormat.date(date, timeZone: timeZone)
    }

    /// "2026-09-28" in the context's time zone.
    func day(_ date: Date) -> String {
        String(FileToolFormat.date(date, timeZone: timeZone).prefix(10))
    }

    /// A single-line, neutralized value (subjects, senders, names).
    static func inline(_ value: String, maxCharacters: Int = TurnContext.maxInlineCharacters) -> String {
        TurnContext.inline(value, maxCharacters: maxCharacters)
    }

    /// "INBOX", "Archiv/Rechnungen".
    static func mailboxPath(_ path: [String]) -> String {
        path.joined(separator: "/")
    }

    /// The mailbox of a message as shown: its path, or nothing when Mail could
    /// not name it (only the Mail-wide mailbox it was found in is known).
    static func shownMailbox(_ locator: MailLocator) -> String {
        locator.isInUnnamedMailbox ? "" : mailboxPath(locator.mailboxPath)
    }

    // MARK: Cards

    /// A card row for a message.
    static func item(locator: MailLocator, messageID: String?, sender: String, subject: String, date: Date?,
                     preview: String?, accountName: String?, isRead: Bool?) -> MailItem {
        // "Lisa Beispiel <lisa@example.com>" shows the name; a bare address itself.
        let parsed = EmailAddress.parse(sender)
        let name = parsed.map { $0.name ?? $0.address } ?? sender
        return MailItem(
            id: MailID.string(for: locator),
            messageID: messageID.map(MailText.bareMessageID).flatMap { $0.isEmpty ? nil : $0 },
            sender: NoteText.singleLine(name),
            senderAddress: parsed?.address,
            subject: NoteText.singleLine(subject),
            date: date,
            preview: preview,
            mailbox: shownMailbox(locator).nilIfEmpty,
            account: accountName.flatMap { $0.isEmpty ? nil : $0 },
            isRead: isRead
        )
    }

    // MARK: Summaries

    /// "No emails found", "Found 1 email", "Found 12 emails".
    static func foundSummary(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "No emails found")
        case 1: String(localized: "Found 1 email")
        default: String(format: String(localized: "Found %lld emails"), count)
        }
    }
}

extension MailToolContext {
    /// The mail tools' context on these services, with the panel to keep visible
    /// while Mail's reply window takes the keyboard.
    init(services: AppServices, keyboardHandoff: any KeyboardHandoffAnnouncing = NoKeyboardHandoff()) {
        self.init(mail: MailService(runner: services.appleScripts), spotlight: services.mailSpotlight,
                  contacts: services.contactBook, pasteboard: services.pasteboard, keyboardHandoff: keyboardHandoff)
    }
}
