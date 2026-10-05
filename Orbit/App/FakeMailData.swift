#if DEBUG
import Foundation
import os

/// DEBUG only: invented mail for the fake-data mode (`FakePersonalData`,
/// ORBIT_DEBUG_FAKE_PERSONAL_DATA). Answers Orbit's mail scripts from
/// `mails.json` with exactly the JSON the scripts print (the same Codable
/// types); Mail is never contacted. Drafts and reply windows are recorded
/// instead of opened, and "Show in Mail", messages opened from cards and
/// the text Orbit would put on the clipboard (a reply's text, "Copy
/// Text") are recorded too; `orbitctl state` reports them.
///
/// `mails.json` (every key optional):
/// `{"automation": "granted" | "denied",
///   "accounts": [{"id": "ORBIT-FAKE-PRIVAT", "name": "Privat", "emails": ["erika@example.org"],
///     "mailboxes": [{"path": "INBOX", "role": "inbox"}, {"path": "Archiv/Rechnungen"}]}],
///   "messages": [{"id": 101, "account": "ORBIT-FAKE-PRIVAT", "mailbox": "INBOX",
///     "messageID": "…@example.com", "from": "Lisa Beispiel <lisa@example.com>", "to": ["…"], "cc": [],
///     "replyTo": "…", "subject": "…", "date": "-2d", "read": false, "flagged": false, "body": "…",
///     "attachments": [{"name": "Rechnung.pdf", "size": 120000}]}]}`
/// Roles: inbox, sent, drafts, junk, trash (Mail's special mailboxes). Dates
/// like in notes.json ("-2d", ISO 8601).
final class FakeMailData: Sendable {
    static let file = "mails.json"

    struct Mailbox: Sendable, Hashable {
        var accountID: String
        var path: [String]
        var role: String?
    }

    struct Message: Sendable, Hashable {
        var number: Int
        var accountID: String
        var mailbox: [String]
        var messageID: String
        var from: String
        var to: [String]
        var cc: [String]
        var replyTo: String?
        var subject: String
        var date: Date
        var isRead: Bool
        var isFlagged: Bool
        var body: String
        var attachments: [MailMessage.Attachment]
    }

    /// A reply window "opened" for a message.
    private struct Reply: Sendable {
        var id: Int
        var message: Int
        var subject: String
        var to: [String]
        var cc: [String]
        var toAll: Bool
        /// What went to the clipboard after it was opened.
        var text: String?
    }

    private struct State: Sendable {
        var drafts: [JSONValue] = []
        var replies: [Reply] = []
        var shownDrafts: [Int] = []
        var openedMessages: [String] = []
        var clipboard: [String] = []
        var nextDraftID = 1
    }

    let accounts: [CandidatesAccount]
    let accountAddresses: [String: [String]]
    let mailboxes: [Mailbox]
    let messages: [Message]
    let automationDenied: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// An account as `mail-search` lists it.
    typealias CandidatesAccount = MailCandidates.Account

    init(folder: URL?, now: Date, errors: inout [String]) {
        let file = folder.flatMap { FakeMailData.decode($0.appendingPathComponent(Self.file), errors: &errors) } ?? MailsFile()
        var accounts: [CandidatesAccount] = []
        var addresses: [String: [String]] = [:]
        var mailboxes: [Mailbox] = []
        for account in file.accounts ?? [] {
            accounts.append(CandidatesAccount(id: account.id, name: account.name ?? account.id))
            addresses[account.id] = account.emails ?? []
            for box in account.mailboxes ?? [] {
                let path = box.path.split(separator: "/").map(String.init)
                if !path.isEmpty { mailboxes.append(Mailbox(accountID: account.id, path: path, role: box.role?.lowercased())) }
            }
        }
        var messages: [Message] = []
        for (index, entry) in (file.messages ?? []).enumerated() {
            let accountID = entry.account ?? accounts.first?.id ?? ""
            let path = (entry.mailbox ?? "INBOX").split(separator: "/").map(String.init)
            if !mailboxes.contains(where: { $0.accountID == accountID && $0.path == path }) {
                mailboxes.append(Mailbox(accountID: accountID, path: path, role: path == ["INBOX"] ? "inbox" : nil))
            }
            messages.append(Message(
                number: entry.id ?? 9_000 + index, accountID: accountID, mailbox: path,
                messageID: entry.messageID ?? "orbit-fake-\(index + 1)@example.com",
                from: entry.from ?? "", to: entry.to ?? [], cc: entry.cc ?? [], replyTo: entry.replyTo,
                subject: entry.subject ?? "", date: FakePersonalData.date(entry.date, now: now, errors: &errors),
                isRead: entry.read ?? true, isFlagged: entry.flagged ?? false, body: entry.body ?? "",
                attachments: entry.attachments ?? []))
        }
        self.accounts = accounts
        accountAddresses = addresses
        self.mailboxes = mailboxes
        self.messages = messages
        automationDenied = file.automation?.lowercased() == "denied"
    }

    // MARK: Scripts

    /// Answers a mail script like the real one, or nil when `name` is no mail script.
    func runScript(_ name: String, arguments: [String]) throws -> String? {
        switch name {
        case MailService.searchScript.name: try search(arguments)
        case MailService.summariesScript.name: try summaries(arguments)
        case MailService.readScript.name: try read(arguments)
        case MailService.draftScript.name: try draft(arguments)
        case MailService.replyScript.name: try reply(arguments)
        case MailService.showDraftScript.name: try showDraft(arguments)
        default: nil
        }
    }

    private func search(_ arguments: [String]) throws -> String {
        try check(arguments, count: 7)
        let kind = arguments[0]
        let since = Date(timeIntervalSince1970: Double(arguments[2]) ?? 0)
        let until = Date(timeIntervalSince1970: Double(arguments[3]) ?? 0)
        let unreadOnly = arguments[4] == "true"
        let excluded = FakePersonalData.lines(arguments[5])
        func inRange(_ message: Message) -> Bool {
            message.date >= since && message.date <= until && (!unreadOnly || !message.isRead)
        }
        var batches: [MailCandidates.Batch] = []
        if ["inbox", "sent", "drafts", "junk", "trash"].contains(kind) {
            let boxes = mailboxes.filter { $0.role == kind }
            let found = messages.filter { message in
                inRange(message) && boxes.contains { $0.accountID == message.accountID && $0.path == message.mailbox }
            }
            batches.append(MailCandidates.Batch(
                accounts: found.map(\.accountID), mailboxNames: found.map { $0.mailbox.last },
                ids: found.map(\.number), dates: found.map { $0.date.timeIntervalSince1970 },
                subjects: found.map(\.subject), senders: found.map(\.from)))
        } else {
            let boxes = mailboxes.filter { box in
                kind == "all" ? !box.path.contains { MailboxNames.contains(excluded, $0) }
                    : MailboxNames.path(box.path, isNamed: arguments[1])
            }
            if kind == "named", boxes.isEmpty {
                return try FakePersonalData.encode(MailboxListFailure(error: "mailboxNotFound", mailboxes: mailboxes.map(\.path)))
            }
            for box in boxes {
                let found = messages.filter { $0.accountID == box.accountID && $0.mailbox == box.path && inRange($0) }
                batches.append(MailCandidates.Batch(
                    account: box.accountID, mailbox: box.path, ids: found.map(\.number),
                    dates: found.map { $0.date.timeIntervalSince1970 }, subjects: found.map(\.subject),
                    senders: found.map(\.from)))
            }
        }
        return try FakePersonalData.encode(MailCandidates(batches: batches, accounts: accounts))
    }

    private func summaries(_ arguments: [String]) throws -> String {
        try check(arguments, count: 3)
        let previewLength = Int(arguments[1]) ?? 0
        let rows = FakePersonalData.lines(arguments[0]).map { line -> MailSummaries.Row in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            let number = Int(fields.first ?? "") ?? 0
            guard let message = find(number, accountID: fields.count > 1 ? fields[1] : "",
                                      path: Array(fields.dropFirst(2)).filter { !$0.isEmpty }) else {
                return MailSummaries.Row(number: number, found: false)
            }
            return MailSummaries.Row(number: number, found: true, account: message.accountID, mailbox: message.mailbox,
                                     subject: message.subject, sender: message.from, messageID: message.messageID,
                                     read: message.isRead, date: message.date.timeIntervalSince1970,
                                     preview: String(message.body.prefix(max(0, previewLength))))
        }
        return try FakePersonalData.encode(MailSummaries(rows: rows))
    }

    private func read(_ arguments: [String]) throws -> String {
        try check(arguments, count: 4)
        guard let message = find(Int(arguments[0]) ?? 0, accountID: arguments[1],
                                 path: FakePersonalData.lines(arguments[2])) else {
            return try FakePersonalData.encode(["error": "notFound"])
        }
        let maxBody = max(0, Int(arguments[3]) ?? 0)
        let account = accounts.first { $0.id == message.accountID }
        return try FakePersonalData.encode(MailMessage(
            number: message.number, account: message.accountID, accountName: account?.name,
            accountAddresses: accountAddresses[message.accountID] ?? [], mailbox: message.mailbox,
            messageID: message.messageID, subject: message.subject, sender: message.from, replyTo: message.replyTo,
            to: message.to.map(Self.address), cc: message.cc.map(Self.address), dateReceived: message.date,
            dateSent: message.date, isRead: message.isRead, isFlagged: message.isFlagged,
            attachments: message.attachments, body: String(message.body.prefix(maxBody)),
            bodyLength: message.body.count))
    }

    private func draft(_ arguments: [String]) throws -> String {
        try check(arguments, count: 4)
        func recipients(_ text: String) -> [(address: String, name: String)] {
            FakePersonalData.lines(text).map { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                return (fields.first ?? "", fields.count > 1 ? fields[1] : "")
            }
        }
        let to = recipients(arguments[2])
        let cc = recipients(arguments[3])
        // Like Mail, the fake refuses what is not an address at all.
        let failed = (to + cc).map(\.address).filter { !$0.contains("@") }
        let id = state.withLock { state -> Int in
            let id = state.nextDraftID
            state.nextDraftID += 1
            func list(_ recipients: [(address: String, name: String)]) -> JSONValue {
                .array(recipients.filter { $0.address.contains("@") }.map {
                    .string($0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>")
                })
            }
            state.drafts.append([
                "id": .number(Double(id)), "subject": .string(arguments[0]), "text": .string(arguments[1]),
                "to": list(to), "cc": list(cc),
            ])
            return id
        }
        return try FakePersonalData.encode(CreatedMailDraft(id: id, failed: failed))
    }

    /// Mail's reply window, like Mail fills it in: to the Reply-To addresses
    /// or the sender (with `toAll` also to the other recipients, except the
    /// account's own addresses), "Re: <subject>".
    private func reply(_ arguments: [String]) throws -> String {
        try check(arguments, count: 4)
        guard let message = find(Int(arguments[0]) ?? 0, accountID: arguments[1],
                                 path: FakePersonalData.lines(arguments[2])) else {
            return try FakePersonalData.encode(["error": "notFound"])
        }
        let toAll = arguments[3] == "true"
        let own = Set((accountAddresses[message.accountID] ?? []).map { $0.lowercased() })
        let answered = (message.replyTo ?? "").split(separator: ",").map(String.init).filter { EmailAddress.parse($0) != nil }
        var to = (answered.isEmpty ? [message.from] : answered).map(Self.address)
        var cc: [MailMessage.Address] = []
        if toAll {
            var seen = Set(to.compactMap { $0.address?.lowercased() }).union(own)
            func others(_ list: [String]) -> [MailMessage.Address] {
                list.map(Self.address).filter { address in
                    guard let key = address.address?.lowercased() else { return false }
                    return seen.insert(key).inserted
                }
            }
            to += others(message.to)
            cc = others(message.cc)
        }
        let subject = MailText.replySubject(message.subject)
        let recorded = Reply(id: 0, message: message.number, subject: subject, to: to.map(\.display), cc: cc.map(\.display),
                             toAll: toAll)
        let id = state.withLock { state -> Int in
            var reply = recorded
            reply.id = state.nextDraftID
            state.nextDraftID += 1
            state.replies.append(reply)
            return reply.id
        }
        return try FakePersonalData.encode(OpenedMailReply(
            id: id, subject: subject, to: to, cc: cc, sender: message.from, replyTo: message.replyTo,
            originalSubject: message.subject, dateReceived: message.date))
    }

    private func showDraft(_ arguments: [String]) throws -> String {
        try check(arguments, count: 1)
        let id = Int(arguments[0]) ?? 0
        let shown = state.withLock { state -> Bool in
            guard state.drafts.contains(where: { $0["id"] == .number(Double(id)) }) || state.replies.contains(where: { $0.id == id })
            else { return false }
            state.shownDrafts.append(id)
            return true
        }
        return try FakePersonalData.encode(ShownMailDraft(shown: shown))
    }

    /// The message by its number: in the given account and mailbox, else in a
    /// mailbox of the same name (like the scripts' fallback); for the path
    /// "@inbox" ("@sent" …) first in that Mail-wide mailbox of every account.
    private func find(_ number: Int, accountID: String, path: [String]) -> Message? {
        if let kind = MailLocator.mailWideKind(of: path), let message = messages.first(where: { message in
            message.number == number
                && mailboxes.contains { $0.role == kind && $0.accountID == message.accountID && $0.path == message.mailbox }
        }) {
            return message
        }
        if let exact = messages.first(where: { $0.number == number && $0.accountID == accountID && $0.mailbox == path }) {
            return exact
        }
        guard let name = path.last else { return nil }
        return messages.first { message in
            message.number == number && message.mailbox.last == name && (accountID.isEmpty || message.accountID == accountID)
        }
    }

    private func check(_ arguments: [String], count: Int) throws {
        if automationDenied { throw AppleScriptError.notAuthorized(.mail) }
        guard arguments.count >= count else {
            throw AppleScriptError.failed(number: 1000, message: "The script expects \(count) arguments")
        }
    }

    private static func address(_ text: String) -> MailMessage.Address {
        guard let parsed = EmailAddress.parse(text) else { return MailMessage.Address(name: text, address: nil) }
        return MailMessage.Address(name: parsed.name, address: parsed.address)
    }

    /// A message:// link a mail card opened: recorded, never opened.
    func recordOpenedMessage(_ url: URL) {
        state.withLock { $0.openedMessages.append(url.absoluteString) }
    }

    /// Text Orbit would put on the clipboard: recorded (the user's clipboard is
    /// never touched); the first text after a reply window opened is that
    /// reply's text.
    func recordClipboard(_ text: String) {
        state.withLock { state in
            state.clipboard.append(text)
            if let last = state.replies.indices.last, state.replies[last].text == nil {
                state.replies[last].text = text
            }
        }
    }

    // MARK: State

    /// For `orbitctl state`: counts and what Orbit did.
    func stateSummary() -> [String: JSONValue] {
        let snapshot = state.withLock { $0 }
        return [
            "mails": .number(Double(messages.count)),
            "mailAutomation": .string(automationDenied ? "denied" : "granted"),
            "createdDrafts": .array(snapshot.drafts),
            "createdReplies": .array(snapshot.replies.map { reply in
                var entry: [String: JSONValue] = [
                    "id": .number(Double(reply.id)), "message": .number(Double(reply.message)),
                    "subject": .string(reply.subject), "to": .array(reply.to.map(JSONValue.string)),
                    "cc": .array(reply.cc.map(JSONValue.string)), "replyAll": .bool(reply.toAll),
                ]
                if let text = reply.text { entry["text"] = .string(text) }
                return .object(entry)
            }),
            "shownDrafts": .array(snapshot.shownDrafts.map { .number(Double($0)) }),
            "openedMessages": .array(snapshot.openedMessages.map(JSONValue.string)),
            "clipboard": .array(snapshot.clipboard.map(JSONValue.string)),
        ]
    }

    // MARK: File

    private struct MailsFile: Decodable {
        struct Account: Decodable {
            struct Box: Decodable {
                var path: String
                var role: String?
            }

            var id: String
            var name: String?
            var emails: [String]?
            var mailboxes: [Box]?
        }

        struct Entry: Decodable {
            var id: Int?
            var account: String?
            var mailbox: String?
            var messageID: String?
            var from: String?
            var to: [String]?
            var cc: [String]?
            var replyTo: String?
            var subject: String?
            var date: String?
            var read: Bool?
            var flagged: Bool?
            var body: String?
            var attachments: [MailMessage.Attachment]?
        }

        var automation: String?
        var accounts: [Account]?
        var messages: [Entry]?
    }

    private struct MailboxListFailure: Encodable {
        var error: String
        var mailboxes: [[String]]
    }

    private static func decode(_ url: URL, errors: inout [String]) -> MailsFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(MailsFile.self, from: Data(contentsOf: url))
        } catch {
            errors.append("\(url.lastPathComponent) could not be read: \(error)")
            return nil
        }
    }
}
#endif
