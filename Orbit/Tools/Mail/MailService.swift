import Foundation

/// Orbit's Mail scripts (`Resources/AppleScripts/mail-*.applescript`) with
/// typed arguments and results. Live through `LiveAppleScriptRunner`; tests
/// pass a mock runner, the DEBUG fake-data mode one that answers from invented
/// mail. The result types are Codable, so the fake answers exactly like the
/// scripts. No script ever sends a message.
///
/// Searching takes two runs: `mail-search` returns every message in the time
/// range with its subject and sender (bulk Apple Events per mailbox, no
/// per-message work in AppleScript), Orbit matches and ranks them in Swift,
/// and `mail-summaries` fetches the rest (read status, Message-ID, preview) for
/// the few messages shown.
///
/// A new message is made with its text (`mail-draft`); an answer opens Mail's
/// own reply window (`mail-reply`), which Mail fills in itself, no script
/// writes into it.
struct MailService: Sendable {
    static let searchScript = AppleScript(name: "mail-search", app: .mail, timeout: .seconds(70))
    static let summariesScript = AppleScript(name: "mail-summaries", app: .mail, timeout: .seconds(30))
    static let readScript = AppleScript(name: "mail-read", app: .mail, timeout: .seconds(40))
    static let draftScript = AppleScript(name: "mail-draft", app: .mail, timeout: .seconds(40))
    static let replyScript = AppleScript(name: "mail-reply", app: .mail, timeout: .seconds(40))
    static let showDraftScript = AppleScript(name: "mail-show-draft", app: .mail, timeout: .seconds(30))
    static let scripts = [searchScript, summariesScript, readScript, draftScript, replyScript, showDraftScript]

    /// Seconds `mail-search` may spend on mailboxes once Mail answered: it
    /// starts no mailbox after that, ends every request to Mail 15 seconds later
    /// at the latest and names the mailboxes it skipped, well before its
    /// 70-second limit (which also covers Mail starting up).
    static let searchBudgetSeconds = 35
    /// The same for `mail-summaries`, whose requests end 8 seconds later at the
    /// latest (its limit is 30 seconds). search_mail gives it less when the
    /// first step took long, and skips it after 45 seconds.
    static let summariesBudgetSeconds = 18

    let runner: any AppleScriptRunning

    /// Every message received in `since…until` in `mailboxes`, with subject and sender.
    func candidates(in mailboxes: MailboxSelection, since: Date, until: Date, unreadOnly: Bool,
                    excludedNames: [String], budgetSeconds: Int = searchBudgetSeconds) async throws -> MailCandidates {
        let arguments = [
            mailboxes.scriptKind, mailboxes.scriptName,
            Self.seconds(since), Self.seconds(until),
            unreadOnly ? "true" : "false",
            excludedNames.joined(separator: "\n"),
            String(budgetSeconds),
        ]
        let output = try await runner.run(Self.searchScript, arguments: arguments)
        try Self.checkFailure(output)
        return try Self.decode(MailCandidates.self, from: output, script: Self.searchScript)
    }

    /// Read status, Message-ID and the beginning of the text of these
    /// messages, in the same order (a message Mail cannot find is `found: false`).
    func summaries(of locators: [MailLocator], previewCharacters: Int,
                   budgetSeconds: Int = summariesBudgetSeconds) async throws -> MailSummaries {
        let arguments = [locators.map(Self.line).joined(separator: "\n"), String(previewCharacters), String(budgetSeconds)]
        let output = try await runner.run(Self.summariesScript, arguments: arguments)
        try Self.checkFailure(output)
        return try Self.decode(MailSummaries.self, from: output, script: Self.summariesScript)
    }

    /// One message with its recipients and text (cut after `maxBodyCharacters`).
    func read(_ locator: MailLocator, maxBodyCharacters: Int) async throws -> MailMessage {
        let arguments = [String(locator.messageNumber), locator.accountID, locator.mailboxPath.joined(separator: "\n"),
                         String(maxBodyCharacters)]
        let output = try await runner.run(Self.readScript, arguments: arguments)
        try Self.checkFailure(output)
        return try Self.decode(MailMessage.self, from: output, script: Self.readScript)
    }

    /// Opens a new message window in Mail with these contents; never sends it.
    func createDraft(_ draft: MailDraftContent) async throws -> CreatedMailDraft {
        let arguments = [
            draft.subject, draft.content,
            draft.to.map(Self.recipientLine).joined(separator: "\n"),
            draft.cc.map(Self.recipientLine).joined(separator: "\n"),
        ]
        let output = try await runner.run(Self.draftScript, arguments: arguments)
        try Self.checkFailure(output)
        return try Self.decode(CreatedMailDraft.self, from: output, script: Self.draftScript)
    }

    /// Opens Mail's own reply window for this message: to its sender, or with
    /// `toAll` to everyone who got it. Mail fills in the recipients, the subject,
    /// the quoted original and the signature; nothing is written into the
    /// window, and it is never sent.
    func reply(to locator: MailLocator, toAll: Bool) async throws -> OpenedMailReply {
        let arguments = [String(locator.messageNumber), locator.accountID, locator.mailboxPath.joined(separator: "\n"),
                         toAll ? "true" : "false"]
        let output = try await runner.run(Self.replyScript, arguments: arguments)
        try Self.checkFailure(output)
        return try Self.decode(OpenedMailReply.self, from: output, script: Self.replyScript)
    }

    /// Brings the draft window with this id to the front; false when it is
    /// no longer open (sent, saved and closed, or discarded).
    func showDraft(id: Int) async throws -> Bool {
        let output = try await runner.run(Self.showDraftScript, arguments: [String(id)])
        try Self.checkFailure(output)
        return try Self.decode(ShownMailDraft.self, from: output, script: Self.showDraftScript).shown
    }

    // MARK: Arguments

    /// Whole seconds since 1970, as the scripts read dates.
    static func seconds(_ date: Date) -> String {
        String(Int64(date.timeIntervalSince1970.rounded(.down)))
    }

    /// "4711<TAB>account<TAB>Archiv<TAB>Rechnungen"; names never contain tabs or line breaks (they are replaced).
    static func line(_ locator: MailLocator) -> String {
        ([String(locator.messageNumber), locator.accountID] + locator.mailboxPath).map(fieldText).joined(separator: "\t")
    }

    /// "address<TAB>name".
    static func recipientLine(_ recipient: MailRecipient) -> String {
        [recipient.address, recipient.name ?? ""].map(fieldText).joined(separator: "\t")
    }

    private static func fieldText(_ text: String) -> String {
        String(text.map { $0 == "\t" || $0.isNewline ? " " : $0 })
    }

    // MARK: Decoding

    /// The `{"error": …}` answers of the scripts.
    private struct ScriptFailure: Decodable {
        var error: String?
        var mailboxes: [[String]]?
    }

    private static func checkFailure(_ output: String) throws {
        guard let failure = try? JSONDecoder().decode(ScriptFailure.self, from: Data(output.utf8)),
              let error = failure.error else { return }
        switch error {
        case "notFound":
            throw MailFailure.messageNotFound
        case "mailboxNotFound":
            throw MailFailure.mailboxNotFound(existing: failure.mailboxes ?? [])
        default:
            throw AppleScriptError.invalidOutput
        }
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from output: String, script: AppleScript) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(output.utf8))
        } catch {
            Log.tools.error("AppleScript \(script.name, privacy: .public) printed output that is not the expected JSON")
            throw AppleScriptError.invalidOutput
        }
    }
}

/// What a Mail script reports instead of a result.
enum MailFailure: Error, Sendable, Hashable {
    /// No message with this locator (deleted or moved).
    case messageNotFound
    /// No mailbox has the requested name; `existing` are the paths there are.
    case mailboxNotFound(existing: [[String]])
}

/// Which mailboxes a search looks at.
enum MailboxSelection: Sendable, Hashable {
    /// The inboxes of all accounts.
    case inbox
    case sent
    case drafts
    case junk
    case trash
    /// Every mailbox except trash, junk, drafts and outbox.
    case all
    /// The mailboxes with this name or path ("Archiv/Rechnungen").
    case named(String)

    /// The kind argument of `mail-search`.
    var scriptKind: String {
        switch self {
        case .inbox: "inbox"
        case .sent: "sent"
        case .drafts: "drafts"
        case .junk: "junk"
        case .trash: "trash"
        case .all: "all"
        case .named: "named"
        }
    }

    var scriptName: String {
        if case .named(let name) = self { return name }
        return ""
    }

    /// The kind of a Mail-wide mailbox (its messages are in many mailboxes of
    /// many accounts); nil for "all" and named mailboxes.
    var mailWideKind: String? {
        switch self {
        case .inbox, .sent, .drafts, .junk, .trash: scriptKind
        case .all, .named: nil
        }
    }

    /// Whether only Mail knows which mailboxes these are (Spotlight cannot tell).
    var needsMail: Bool {
        switch self {
        case .sent, .drafts, .junk, .trash: true
        case .inbox, .all, .named: false
        }
    }
}

// MARK: - Results (the scripts' JSON)

/// `mail-search`: the messages in the time range, in batches, one per
/// mailbox, or one per Mail-wide mailbox such as the inbox, whose messages
/// carry their own mailbox and account.
struct MailCandidates: Sendable, Hashable, Codable {
    struct Batch: Sendable, Hashable, Codable {
        /// The account of a single mailbox (nil for a Mail-wide one).
        var account: String?
        /// The path of a single mailbox (nil for a Mail-wide one).
        var mailbox: [String]?
        /// Per message, for a Mail-wide mailbox: its account's id (nil when unknown).
        var accounts: [String?]?
        /// Per message, for a Mail-wide mailbox: its mailbox's name (nil when unknown).
        var mailboxNames: [String?]?
        /// Mail's numbers of the messages (nil entries are skipped).
        var ids: [Int?]
        /// Dates received, seconds since 1970.
        var dates: [Double?]
        var subjects: [String?]
        var senders: [String?]

        init(account: String? = nil, mailbox: [String]? = nil, accounts: [String?]? = nil,
             mailboxNames: [String?]? = nil, ids: [Int?], dates: [Double?], subjects: [String?], senders: [String?]) {
            self.account = account
            self.mailbox = mailbox
            self.accounts = accounts
            self.mailboxNames = mailboxNames
            self.ids = ids
            self.dates = dates
            self.subjects = subjects
            self.senders = senders
        }
    }

    /// A mailbox Mail could not search.
    struct Failure: Sendable, Hashable, Codable {
        /// Its path, or the kind of a Mail-wide mailbox (["inbox"]).
        var mailbox: [String]
        /// Mail's error number (1002: the mailbox changed while it was read).
        var error: Int?

        init(mailbox: [String], error: Int?) {
            self.mailbox = mailbox
            self.error = error
        }
    }

    struct Account: Sendable, Hashable, Codable {
        var id: String
        var name: String

        init(id: String, name: String) {
            self.id = id
            self.name = name
        }

        /// An id or name Mail cannot tell (null) is empty.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        }
    }

    var batches: [Batch]
    /// The accounts' names by id.
    var accounts: [Account]
    /// False when a mailbox was not searched (time ran out, or Mail failed).
    var complete: Bool
    /// The mailboxes not searched because time ran out.
    var skipped: [[String]]
    /// The mailboxes Mail could not search (empty in answers of older scripts).
    var failed: [Failure]

    init(batches: [Batch], accounts: [Account] = [], complete: Bool = true, skipped: [[String]] = [],
         failed: [Failure] = []) {
        self.batches = batches
        self.accounts = accounts
        self.complete = complete
        self.skipped = skipped
        self.failed = failed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        batches = try container.decodeIfPresent([Batch].self, forKey: .batches) ?? []
        accounts = try container.decodeIfPresent([Account].self, forKey: .accounts) ?? []
        complete = try container.decodeIfPresent(Bool.self, forKey: .complete) ?? true
        skipped = try container.decodeIfPresent([[String]].self, forKey: .skipped) ?? []
        failed = try container.decodeIfPresent([Failure].self, forKey: .failed) ?? []
    }

    /// Whether Mail searched no mailbox at all (every one was skipped or failed):
    /// then nothing is known about the messages, not even that there are none.
    var searchedNothing: Bool {
        batches.isEmpty && !(skipped.isEmpty && failed.isEmpty)
    }
}

/// `mail-summaries`.
struct MailSummaries: Sendable, Hashable, Codable {
    struct Row: Sendable, Hashable, Codable {
        var number: Int
        var found: Bool
        /// Where Mail found the message (may differ from the locator it was given).
        var account: String?
        var mailbox: [String]?
        var subject: String?
        var sender: String?
        var messageID: String?
        var read: Bool?
        var date: Double?
        /// The beginning of the message's text.
        var preview: String?

        init(number: Int, found: Bool, account: String? = nil, mailbox: [String]? = nil, subject: String? = nil,
             sender: String? = nil, messageID: String? = nil, read: Bool? = nil, date: Double? = nil,
             preview: String? = nil) {
            self.number = number
            self.found = found
            self.account = account
            self.mailbox = mailbox
            self.subject = subject
            self.sender = sender
            self.messageID = messageID
            self.read = read
            self.date = date
            self.preview = preview
        }
    }

    var rows: [Row]
    /// False when time ran out; the remaining rows are missing.
    var complete: Bool

    init(rows: [Row], complete: Bool = true) {
        self.rows = rows
        self.complete = complete
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decodeIfPresent([Row].self, forKey: .rows) ?? []
        complete = try container.decodeIfPresent(Bool.self, forKey: .complete) ?? true
    }
}

/// `mail-read`: one message.
struct MailMessage: Sendable, Hashable, Codable {
    struct Address: Sendable, Hashable, Codable {
        var name: String?
        var address: String?

        /// "Lisa Beispiel <lisa@example.com>", or whichever part there is.
        var display: String {
            let name = (name ?? "").trimmingCharacters(in: .whitespaces)
            let address = (address ?? "").trimmingCharacters(in: .whitespaces)
            if name.isEmpty || name == address { return address }
            return address.isEmpty ? name : "\(name) <\(address)>"
        }
    }

    struct Attachment: Sendable, Hashable, Codable {
        var name: String
        var size: Int?
    }

    var number: Int
    var account: String?
    var accountName: String?
    /// The addresses of the message's account (to answer from the right one).
    var accountAddresses: [String]
    var mailbox: [String]
    var messageID: String?
    var subject: String
    var sender: String
    var replyTo: String?
    var to: [Address]
    var cc: [Address]
    var dateReceived: Date?
    var dateSent: Date?
    var isRead: Bool?
    var isFlagged: Bool?
    var attachments: [Attachment]
    /// The message's text, possibly cut.
    var body: String
    /// Characters of the whole text.
    var bodyLength: Int

    enum CodingKeys: String, CodingKey {
        case number, account, accountName, accountAddresses, mailbox, messageID, subject, sender, replyTo, to, cc
        case dateReceived, dateSent, isRead = "read", isFlagged = "flagged", attachments, body, bodyLength
    }

    init(number: Int, account: String? = nil, accountName: String? = nil, accountAddresses: [String] = [],
         mailbox: [String] = [], messageID: String? = nil, subject: String, sender: String, replyTo: String? = nil,
         to: [Address] = [], cc: [Address] = [], dateReceived: Date? = nil, dateSent: Date? = nil,
         isRead: Bool? = nil, isFlagged: Bool? = nil, attachments: [Attachment] = [], body: String,
         bodyLength: Int? = nil) {
        self.number = number
        self.account = account
        self.accountName = accountName
        self.accountAddresses = accountAddresses
        self.mailbox = mailbox
        self.messageID = messageID
        self.subject = subject
        self.sender = sender
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.dateReceived = dateReceived
        self.dateSent = dateSent
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.attachments = attachments
        self.body = body
        self.bodyLength = bodyLength ?? body.count
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int.self, forKey: .number)
        account = try container.decodeIfPresent(String.self, forKey: .account)
        accountName = try container.decodeIfPresent(String.self, forKey: .accountName)
        accountAddresses = (try container.decodeIfPresent([String?].self, forKey: .accountAddresses) ?? []).compactMap { $0 }
        mailbox = (try container.decodeIfPresent([String?].self, forKey: .mailbox) ?? []).compactMap { $0 }
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        subject = try container.decodeIfPresent(String.self, forKey: .subject) ?? ""
        sender = try container.decodeIfPresent(String.self, forKey: .sender) ?? ""
        replyTo = try container.decodeIfPresent(String.self, forKey: .replyTo)
        to = try container.decodeIfPresent([Address].self, forKey: .to) ?? []
        cc = try container.decodeIfPresent([Address].self, forKey: .cc) ?? []
        dateReceived = try container.decodeIfPresent(Double.self, forKey: .dateReceived).map(Date.init(timeIntervalSince1970:))
        dateSent = try container.decodeIfPresent(Double.self, forKey: .dateSent).map(Date.init(timeIntervalSince1970:))
        isRead = try container.decodeIfPresent(Bool.self, forKey: .isRead)
        isFlagged = try container.decodeIfPresent(Bool.self, forKey: .isFlagged)
        attachments = try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? []
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        bodyLength = try container.decodeIfPresent(Int.self, forKey: .bodyLength) ?? body.count
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(number, forKey: .number)
        try container.encodeIfPresent(account, forKey: .account)
        try container.encodeIfPresent(accountName, forKey: .accountName)
        try container.encode(accountAddresses, forKey: .accountAddresses)
        try container.encode(mailbox, forKey: .mailbox)
        try container.encodeIfPresent(messageID, forKey: .messageID)
        try container.encode(subject, forKey: .subject)
        try container.encode(sender, forKey: .sender)
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
        try container.encode(to, forKey: .to)
        try container.encode(cc, forKey: .cc)
        try container.encodeIfPresent(dateReceived?.timeIntervalSince1970, forKey: .dateReceived)
        try container.encodeIfPresent(dateSent?.timeIntervalSince1970, forKey: .dateSent)
        try container.encodeIfPresent(isRead, forKey: .isRead)
        try container.encodeIfPresent(isFlagged, forKey: .isFlagged)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(body, forKey: .body)
        try container.encode(bodyLength, forKey: .bodyLength)
    }

    /// Where the message is, as Mail reported it.
    var locator: MailLocator {
        MailLocator(messageNumber: number, accountID: account ?? "", mailboxPath: mailbox)
    }
}

/// A recipient of a draft.
struct MailRecipient: Sendable, Hashable, Codable {
    var address: String
    var name: String?

    /// "Lisa Beispiel <lisa@example.com>" or the address.
    var display: String {
        guard let name, !name.isEmpty, name != address else { return address }
        return "\(name) <\(address)>"
    }
}

/// What `mail-draft` puts into the new message window (Mail writes from the
/// account it chooses).
struct MailDraftContent: Sendable, Hashable {
    var subject: String
    var content: String
    var to: [MailRecipient]
    var cc: [MailRecipient]
}

/// `mail-draft`.
struct CreatedMailDraft: Sendable, Hashable, Codable {
    /// The draft window's id (for "Show in Mail").
    var id: Int
    /// Recipients Mail did not accept.
    var failed: [String]

    init(id: Int, failed: [String] = []) {
        self.id = id
        self.failed = failed
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        failed = try container.decodeIfPresent([String].self, forKey: .failed) ?? []
    }
}

/// `mail-reply`: Mail's reply window for a message, as Mail filled it in, and
/// what the answered message says about whom it answers.
struct OpenedMailReply: Sendable, Hashable, Codable {
    /// The reply window's id (for "Show in Mail"); nil when Mail did not tell.
    var id: Int?
    /// The reply's subject as Mail set it; nil when Mail did not tell.
    var subject: String?
    /// The reply's recipients as Mail set them; empty when Mail did not tell.
    var to: [MailMessage.Address]
    var cc: [MailMessage.Address]
    /// The answered message's sender, Reply-To, subject and date received.
    var sender: String
    var replyTo: String?
    var originalSubject: String
    var dateReceived: Date?

    enum CodingKeys: String, CodingKey {
        case id, subject, to, cc, sender, replyTo, originalSubject, dateReceived
    }

    init(id: Int?, subject: String? = nil, to: [MailMessage.Address] = [], cc: [MailMessage.Address] = [],
         sender: String, replyTo: String? = nil, originalSubject: String, dateReceived: Date? = nil) {
        self.id = id
        self.subject = subject
        self.to = to
        self.cc = cc
        self.sender = sender
        self.replyTo = replyTo
        self.originalSubject = originalSubject
        self.dateReceived = dateReceived
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        subject = try container.decodeIfPresent(String.self, forKey: .subject)
        to = try container.decodeIfPresent([MailMessage.Address].self, forKey: .to) ?? []
        cc = try container.decodeIfPresent([MailMessage.Address].self, forKey: .cc) ?? []
        sender = try container.decodeIfPresent(String.self, forKey: .sender) ?? ""
        replyTo = try container.decodeIfPresent(String.self, forKey: .replyTo)
        originalSubject = try container.decodeIfPresent(String.self, forKey: .originalSubject) ?? ""
        dateReceived = try container.decodeIfPresent(Double.self, forKey: .dateReceived).map(Date.init(timeIntervalSince1970:))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encodeIfPresent(subject, forKey: .subject)
        try container.encode(to, forKey: .to)
        try container.encode(cc, forKey: .cc)
        try container.encode(sender, forKey: .sender)
        try container.encodeIfPresent(replyTo, forKey: .replyTo)
        try container.encode(originalSubject, forKey: .originalSubject)
        try container.encodeIfPresent(dateReceived?.timeIntervalSince1970, forKey: .dateReceived)
    }
}

/// `mail-show-draft`.
struct ShownMailDraft: Sendable, Hashable, Codable {
    var shown: Bool
}
