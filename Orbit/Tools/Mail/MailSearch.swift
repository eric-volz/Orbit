import Foundation
import os

/// A validated `search_mail` request.
struct MailSearchRequest: Sendable, Hashable {
    /// Each must occur in the subject or the sender, through Spotlight also
    /// in the message text (see `MailSearchMode.searchesMessageText`).
    var terms: [String]
    /// `from` as written (for the answer).
    var from: String?
    /// Words that must each start a word of the sender's name: a single word,
    /// or any for a sender without a name, also a word of its address
    /// (`MailText.isFrom`) …
    var fromWords: [String]
    /// … or the sender has one of these addresses (written in `from`, or of contacts matching it).
    var fromAddresses: [String]
    /// How many of `fromAddresses` came from Contacts.
    var contactAddressCount: Int
    var mailboxes: MailboxSelection
    var since: Date
    var until: Date
    var unreadOnly: Bool
    var limit: Int
}

/// A message found.
struct MailSearchRow: Sendable, Hashable {
    var locator: MailLocator
    /// The RFC 5322 Message-ID (opens the message from the card).
    var messageID: String?
    var subject: String
    /// As Mail shows it: "Lisa Beispiel <lisa@example.com>".
    var sender: String
    var date: Date?
    var accountName: String?
    /// nil when unknown (Spotlight does not know it).
    var isRead: Bool?
    var preview: String?
}

/// What a search found.
struct MailSearchOutcome: Sendable, Hashable {
    /// Newest first, at most the request's limit.
    var rows: [MailSearchRow]
    /// All matches (at least this many when `totalIsLowerBound`).
    var total: Int
    var totalIsLowerBound: Bool
    /// Mailboxes not searched because Mail took too long.
    var skippedMailboxes: [[String]]
    var mode: MailSearchMode
    /// Mailboxes Mail could not search.
    var failedMailboxes: [MailCandidates.Failure] = []
    /// Mail searched no mailbox at all: the search failed (it found nothing because
    /// it looked nowhere).
    var searchedNothing = false
}

/// Runs a search: through Spotlight when it shows Mail's messages and the
/// request needs nothing only Mail knows (unread status, the special
/// mailboxes), otherwise (and when Spotlight fails) by asking Mail. Spotlight
/// matches the words itself, in subjects, senders and message texts; Mail's
/// candidates are matched here in Swift by subject and sender. Ranking and
/// de-duplication happen here, the same for both ways.
struct MailSearchEngine: Sendable {
    /// Characters of each preview for the model and the card.
    static let previewCharacters = 160
    /// Characters of each message's text `mail-summaries` returns (the preview is cut from them).
    static let scriptPreviewCharacters = 600
    /// Spotlight results read at most (≈ 8 ms on the main actor for 2,000):
    /// matches in other mailboxes come along, so this is generous.
    static let spotlightMaxResults = 2_000
    /// After a search that took this long, the details are left out (the
    /// agent loop gives a tool 90 seconds).
    static let detailsCutoff: Duration = .seconds(45)

    let context: MailToolContext

    func run(_ request: MailSearchRequest) async throws -> MailSearchOutcome {
        if !request.unreadOnly, !request.mailboxes.needsMail, await context.spotlight.isAvailable() {
            do {
                if let outcome = try await spotlightSearch(request) { return outcome }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.tools.error("Spotlight mail search failed (\(String(describing: type(of: error)), privacy: .public)); asking Mail")
            }
        }
        return try await mailSearch(request)
    }

    // MARK: Spotlight

    /// nil when Mail should answer instead (a named mailbox without matches,
    /// which may not exist; Mail can tell and list the mailboxes there are).
    private func spotlightSearch(_ request: MailSearchRequest) async throws -> MailSearchOutcome? {
        let query = MailSpotlightQuery(since: request.since, until: request.until, terms: request.terms,
                                       fromWords: request.fromWords, fromAddresses: request.fromAddresses,
                                       maxResults: Self.spotlightMaxResults)
        let results = try await context.spotlight.search(query, timeout: context.spotlightTimeout)
        let candidates = Self.spotlightCandidates(results.items, mailboxes: request.mailboxes,
                                                  excluded: context.excludedMailboxNames)
        if candidates.isEmpty, case .named = request.mailboxes { return nil }
        var rows: [MailSearchRow] = []
        for candidate in candidates.prefix(request.limit) {
            // Each row reads and parses a message file: a cancelled search (e.g.
            // past the tool's deadline) stops here instead of going on in the background.
            try Task.checkCancellation()
            rows.append(row(for: candidate.item, locator: candidate.locator))
        }
        return MailSearchOutcome(rows: rows, total: candidates.count,
                                 totalIsLowerBound: results.totalCount > results.items.count || !results.isComplete,
                                 skippedMailboxes: [], mode: .spotlight)
    }

    /// Spotlight's items in the requested mailboxes, newest first (sorted
    /// here, stable, never trusting the order they came in), without likely
    /// junk and without copies of a message (same Message-ID: Gmail's "All
    /// Mail" holds every message again): the copy in an inbox wins.
    static func spotlightCandidates(_ items: [MailSpotlightItem], mailboxes: MailboxSelection,
                                    excluded: [String]) -> [(item: MailSpotlightItem, locator: MailLocator)] {
        let newestFirst = items.enumerated().sorted { lhs, rhs in
            let left = lhs.element.date ?? .distantPast
            let right = rhs.element.date ?? .distantPast
            return left != right ? left > right : lhs.offset < rhs.offset
        }.map(\.element)
        var candidates: [(item: MailSpotlightItem, locator: MailLocator)] = []
        var positionByMessageID: [String: Int] = [:]
        for item in newestFirst {
            guard let locator = MailStorePath.locator(forFile: item.path), !item.isLikelyJunk,
                  isIn(locator.mailboxPath, mailboxes, excluded: excluded) else { continue }
            let messageID = item.messageID.map { MailText.bareMessageID($0).lowercased() } ?? ""
            if !messageID.isEmpty, let position = positionByMessageID[messageID] {
                if isInbox(locator.mailboxPath), !isInbox(candidates[position].locator.mailboxPath) {
                    candidates[position] = (item, locator)
                }
                continue
            }
            if !messageID.isEmpty { positionByMessageID[messageID] = candidates.count }
            candidates.append((item, locator))
        }
        return candidates
    }

    /// Whether a message in the mailbox at `path` belongs to the selection
    /// (Spotlight sees only paths; the special mailboxes need Mail).
    static func isIn(_ path: [String], _ selection: MailboxSelection, excluded: [String]) -> Bool {
        switch selection {
        case .inbox: isInbox(path)
        case .all: !path.contains { MailboxNames.contains(excluded, $0) }
        case .named(let name): MailboxNames.path(path, isNamed: name)
        case .sent, .drafts, .junk, .trash: false
        }
    }

    static func isInbox(_ path: [String]) -> Bool {
        path.count == 1 && MailboxNames.contains(MailboxNames.inboxNames, path[0])
    }

    /// A row for a Spotlight item; its file gives the preview and the subject
    /// with "Re:" (the importer drops it).
    private func row(for item: MailSpotlightItem, locator: MailLocator) -> MailSearchRow {
        let file = context.readMessageFile(item.path).flatMap {
            MailMessageFile.parse(emlx: $0, maxTextCharacters: Self.scriptPreviewCharacters * 4)
        }
        // Spotlight's values may carry stray whitespace (a CR from the header line).
        let subject = file?.subject ?? item.subject.map(MIMEText.singleLine) ?? ""
        let sender = Self.sender(name: item.authors.first.map(MIMEText.singleLine),
                                 address: item.authorAddresses.first.map(MIMEText.singleLine))
        return MailSearchRow(
            locator: locator,
            messageID: item.messageID.map(MailText.bareMessageID) ?? file?.messageID,
            subject: subject,
            sender: sender ?? file?.from ?? "",
            date: item.date,
            accountName: nil,
            isRead: nil,
            preview: file.flatMap { MailText.preview(from: $0.text, maxCharacters: Self.previewCharacters) }
        )
    }

    /// "Name <address>", or whichever part there is.
    static func sender(name: String?, address: String?) -> String? {
        MailMessage.Address(name: name, address: address).display.nilIfEmpty
    }

    // MARK: Mail

    private func mailSearch(_ request: MailSearchRequest) async throws -> MailSearchOutcome {
        let start = ContinuousClock.now
        let found = try await context.perform(MailService.searchScript) {
            try await context.mail.candidates(in: request.mailboxes, since: request.since, until: request.until,
                                              unreadOnly: request.unreadOnly, excludedNames: context.excludedMailboxNames)
        }
        let matches = Self.matchingCandidates(found, request: request)
        let shown = Array(matches.prefix(request.limit))
        var rows = shown.map { candidate in
            MailSearchRow(locator: candidate.locator, messageID: nil, subject: candidate.subject, sender: candidate.sender,
                          date: candidate.date, accountName: candidate.accountName, isRead: nil, preview: nil)
        }
        let searched = ContinuousClock.now - start
        if !rows.isEmpty, searched < Self.detailsCutoff {
            let budget = max(3, min(MailService.summariesBudgetSeconds, 55 - Int(searched / .seconds(1))))
            rows = try await addingDetails(to: rows, accountNames: Self.accountNames(found), budgetSeconds: budget)
        }
        let milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
        Log.tools.info("search_mail (Mail): \(matches.count) matches, \(rows.count) returned, \(found.skipped.count) mailboxes skipped, \(found.failed.count) failed, \(milliseconds) ms")
        return MailSearchOutcome(rows: rows, total: matches.count, totalIsLowerBound: false,
                                 skippedMailboxes: found.skipped, mode: .appleScript, failedMailboxes: found.failed,
                                 searchedNothing: found.searchedNothing)
    }

    /// A message from `mail-search` that matches the request.
    struct Candidate: Sendable, Hashable {
        var locator: MailLocator
        var date: Date
        var subject: String
        var sender: String
        var accountName: String?
    }

    /// The candidates that match, newest first. Messages that appear in
    /// several of the searched mailboxes (Gmail's "All Mail", or a message that
    /// reached two accounts) are listed once: same second, subject and sender.
    static func matchingCandidates(_ found: MailCandidates, request: MailSearchRequest) -> [Candidate] {
        let names = accountNames(found)
        var candidates: [Candidate] = []
        for batch in found.batches {
            let count = batch.ids.count
            guard batch.dates.count == count, batch.subjects.count == count, batch.senders.count == count else {
                Log.tools.error("mail-search returned a batch whose lists differ in length; it is skipped")
                continue
            }
            let accounts = batch.accounts?.count == count ? batch.accounts : nil
            let mailboxNames = batch.mailboxNames?.count == count ? batch.mailboxNames : nil
            for index in 0..<count {
                guard let number = batch.ids[index], number > 0, let seconds = batch.dates[index] else { continue }
                let date = Date(timeIntervalSince1970: seconds)
                guard date >= request.since, date <= request.until else { continue }
                let subject = batch.subjects[index] ?? ""
                let sender = batch.senders[index] ?? ""
                guard MailText.matches(subject: subject, sender: sender, terms: request.terms,
                                       fromWords: request.fromWords, fromAddresses: request.fromAddresses) else { continue }
                let account = batch.account ?? accounts?[index] ?? ""
                // When Mail cannot name a message's own mailbox, the Mail-wide one it is in
                // ("@inbox") still finds it.
                let path: [String] = batch.mailbox ?? (mailboxNames?[index] ?? nil).map { [$0] }
                    ?? request.mailboxes.mailWideKind.map(MailLocator.mailWidePath) ?? []
                candidates.append(Candidate(
                    locator: MailLocator(messageNumber: number, accountID: account, mailboxPath: path),
                    date: date, subject: subject, sender: sender, accountName: names[account]))
            }
        }
        candidates.sort { lhs, rhs in
            lhs.date != rhs.date ? lhs.date > rhs.date : lhs.locator.messageNumber > rhs.locator.messageNumber
        }
        switch request.mailboxes {
        case .all, .named:
            var seen = Set<String>()
            return candidates.filter { candidate in
                let key = "\(Int(candidate.date.timeIntervalSince1970))|\(candidate.subject.lowercased())|"
                    + candidate.sender.lowercased()
                return seen.insert(key).inserted
            }
        default:
            return candidates
        }
    }

    static func accountNames(_ found: MailCandidates) -> [String: String] {
        var names: [String: String] = [:]
        for account in found.accounts where names[account.id] == nil {
            names[account.id] = account.name
        }
        return names
    }

    /// Read status, Message-ID and preview from `mail-summaries`. The rows stay
    /// as they are when Mail cannot add them (they are extras).
    private func addingDetails(to rows: [MailSearchRow], accountNames: [String: String],
                               budgetSeconds: Int) async throws -> [MailSearchRow] {
        let summaries: MailSummaries
        do {
            summaries = try await context.mail.summaries(of: rows.map(\.locator),
                                                         previewCharacters: Self.scriptPreviewCharacters,
                                                         budgetSeconds: budgetSeconds)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.tools.error("mail-summaries failed (\(String(describing: type(of: error)), privacy: .public)); rows without previews")
            return rows
        }
        var result = rows
        for (index, summary) in summaries.rows.enumerated() where index < result.count {
            guard summary.found, summary.number == result[index].locator.messageNumber else { continue }
            var row = result[index]
            if let account = summary.account { row.locator.accountID = account }
            if let mailbox = summary.mailbox, !mailbox.isEmpty { row.locator.mailboxPath = mailbox }
            if let subject = summary.subject, row.subject.isEmpty { row.subject = subject }
            if let sender = summary.sender, row.sender.isEmpty { row.sender = sender }
            row.messageID = summary.messageID.map(MailText.bareMessageID).flatMap(\.nilIfEmpty)
            row.isRead = summary.read
            row.preview = summary.preview.flatMap { MailText.preview(from: $0, maxCharacters: Self.previewCharacters) }
            if row.accountName == nil { row.accountName = accountNames[row.locator.accountID] }
            result[index] = row
        }
        return result
    }
}

extension String {
    /// nil for an empty string.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
