import Foundation
import os
import Testing
@testable import Orbit

/// The search engine behind search_mail: which way it searches, and the
/// matching, ranking and de-duplication shared by both ways.
@Suite("Mail search engine")
struct MailSearchTests {
    static func request(terms: [String] = [], words: [String] = [], addresses: [String] = [],
                        mailboxes: MailboxSelection = .inbox, unreadOnly: Bool = false, limit: Int = 20) -> MailSearchRequest {
        MailSearchRequest(terms: terms, from: nil, fromWords: words, fromAddresses: addresses, contactAddressCount: 0,
                          mailboxes: mailboxes, since: MailTest.date("2026-09-03T12:00:00+02:00"), until: MailTest.now,
                          unreadOnly: unreadOnly, limit: limit)
    }

    static let inboxBatch = MailCandidates.Batch(
        accounts: [MailFixtures.privateAccount, MailFixtures.workAccount, nil],
        mailboxNames: ["INBOX", "INBOX", "INBOX"],
        ids: [101, 111, 999], dates: [1_790_856_130, 1_790_762_410, 1_790_000_000],
        subjects: ["Projekt Orbit \u{2013} nächste Schritte", "Quartalszahlen Q3", nil],
        senders: ["Lisa Beispiel <lisa.beispiel@example.com>", "Lisa Beispiel <lisa.beispiel@firma.example>", nil])

    // MARK: Which way

    @Test func spotlightIsUsedWhenAvailableAndNeitherUnreadNorSpecialMailboxesAreAsked() async throws {
        let spotlight = MockMailSpotlight(available: true)
        let runner = MailTest.runner(candidates: MailCandidates(batches: []))
        let engine = MailSearchEngine(context: MailTest.context(runner, spotlight: spotlight))
        #expect(try await engine.run(Self.request()).mode == .spotlight)
        #expect(try await engine.run(Self.request(mailboxes: .all)).mode == .spotlight)
        #expect(runner.runs.isEmpty, "Mail is not asked")
        #expect(try await engine.run(Self.request(unreadOnly: true)).mode == .appleScript, "Spotlight knows no read status")
        #expect(try await engine.run(Self.request(mailboxes: .sent)).mode == .appleScript, "only Mail knows its special mailboxes")
        #expect(try await MailSearchEngine(context: MailTest.context(runner, spotlight: MockMailSpotlight(available: false)))
            .run(Self.request()).mode == .appleScript)
        #expect(spotlight.queries.count == 2)
    }

    @Test func aFailingSpotlightFallsBackToMail() async throws {
        struct Broken: Error {}
        let spotlight = MockMailSpotlight(available: true) { _ in throw Broken() }
        let runner = MailTest.runner(candidates: MailCandidates(batches: [Self.inboxBatch], accounts: MailTest.accounts))
        let outcome = try await MailSearchEngine(context: MailTest.context(runner, spotlight: spotlight)).run(Self.request())
        #expect(outcome.mode == .appleScript)
        #expect(outcome.rows.map(\.locator.messageNumber) == [101, 111, 999])
    }

    @Test func aNamedMailboxSpotlightDoesNotKnowIsAskedOfMail() async throws {
        let spotlight = MockMailSpotlight(items: [
            MailSpotlightItem(path: MailFixtures.inbox("101.emlx"), subject: "x", date: Date()),
        ])
        let runner = MockAppleScriptRunner(output: #"{"error":"mailboxNotFound","mailboxes":[["INBOX"],["Archiv"]]}"#)
        let engine = MailSearchEngine(context: MailTest.context(runner, spotlight: spotlight))
        await #expect(throws: MailFailure.mailboxNotFound(existing: [["INBOX"], ["Archiv"]])) {
            try await engine.run(Self.request(mailboxes: .named("Archivv")))
        }
    }

    // MARK: Spotlight

    @Test func spotlightQueriesCarryTheRequest() async throws {
        let spotlight = MockMailSpotlight(available: true)
        let request = Self.request(terms: ["projekt"], words: ["lisa"], addresses: ["lisa@example.org"])
        _ = try await MailSearchEngine(context: MailTest.context(spotlight: spotlight)).run(request)
        let query = try #require(spotlight.queries.first)
        #expect(query.terms == ["projekt"])
        #expect(query.fromWords == ["lisa"])
        #expect(query.fromAddresses == ["lisa@example.org"])
        #expect(query.since == request.since)
        #expect(query.until == request.until)
        #expect(query.maxResults == MailSearchEngine.spotlightMaxResults)
    }

    static let spotlightItems = [
        MailSpotlightItem(path: MailFixtures.inbox("102.emlx"), subject: "Ihre Rechnung September 2026",
                          authors: ["Telekom Deutschland"], authorAddresses: ["rechnung@telekom.example"],
                          date: MailTest.date("2026-10-01T07:15:00Z"), messageID: "<orbit-fake-102@telekom.example>"),
        MailSpotlightItem(path: MailFixtures.inbox("101.emlx"), subject: "Projekt Orbit \u{2013} nächste Schritte",
                          authors: ["Lisa Beispiel"], authorAddresses: ["lisa.beispiel@example.com"],
                          date: MailTest.date("2026-09-30T12:02:00Z"), messageID: "<orbit-fake-101@example.com>"),
        MailSpotlightItem(path: MailFixtures.path(account: MailFixtures.privateAccount, mailbox: ["Deleted Messages"], file: "301.emlx"),
                          subject: "Alte Notiz", authors: ["Lisa Beispiel"], date: MailTest.date("2026-09-29T09:00:00Z"),
                          messageID: "<orbit-fake-301@example.com>"),
        // A Gmail-style copy first, then the inbox copy of the same message.
        MailSpotlightItem(path: MailFixtures.path(account: MailFixtures.workAccount, mailbox: ["[Gmail]", "All Mail"], file: "112.emlx"),
                          subject: "Quartalszahlen Q3", authors: ["Lisa Beispiel"], date: MailTest.date("2026-09-29T08:00:00Z"),
                          messageID: "<orbit-fake-111@firma.example>"),
        MailSpotlightItem(path: MailFixtures.inbox("111.emlx", account: MailFixtures.workAccount), subject: "Quartalszahlen Q3",
                          authors: ["Lisa Beispiel"], date: MailTest.date("2026-09-29T08:00:00Z"),
                          messageID: "<ORBIT-FAKE-111@firma.example>"),
        MailSpotlightItem(path: MailFixtures.path(account: MailFixtures.privateAccount, mailbox: ["Junk"], file: "401.emlx"),
                          subject: "Gewinn", date: MailTest.date("2026-09-27T08:00:00Z"), isLikelyJunk: true),
        MailSpotlightItem(path: MailFixtures.path(account: MailFixtures.privateAccount, mailbox: ["Archiv", "Rechnungen"], file: "201.emlx"),
                          subject: "Ihre Rechnung August 2026", date: MailTest.date("2026-08-12T04:00:00Z"),
                          messageID: "<orbit-fake-201@vodafone.example>"),
        MailSpotlightItem(path: "/Users/someone/Documents/not-a-store/7.emlx", subject: "Fremd", date: Date()),
    ]

    @Test func spotlightCandidatesFollowTheMailboxSelection() {
        func numbers(_ selection: MailboxSelection) -> [Int] {
            MailSearchEngine.spotlightCandidates(Self.spotlightItems, mailboxes: selection, excluded: MailboxNames.excludedFromAll)
                .map(\.locator.messageNumber)
        }
        #expect(numbers(.inbox) == [102, 101, 111])
        #expect(numbers(.all) == [102, 101, 111, 201], "no trash, no junk, one copy of a message (the inbox's)")
        #expect(numbers(.named("rechnungen")) == [201])
        #expect(numbers(.named("Archiv/Rechnungen")) == [201])
        #expect(numbers(.named("Archiv")) == [])
        #expect(numbers(.sent) == [], "special mailboxes are never answered from paths")
    }

    @Test func spotlightCandidatesAreSortedWhateverOrderTheyCameIn() {
        let shuffled = [Self.spotlightItems[6], Self.spotlightItems[1], Self.spotlightItems[4], Self.spotlightItems[0]]
        let numbers = MailSearchEngine.spotlightCandidates(shuffled, mailboxes: .all, excluded: MailboxNames.excludedFromAll)
            .map(\.locator.messageNumber)
        #expect(numbers == [102, 101, 111, 201])
        let undated = MailSpotlightItem(path: MailFixtures.inbox("103.emlx"), subject: "No Date")
        let withUndated = MailSearchEngine.spotlightCandidates([undated] + shuffled, mailboxes: .inbox, excluded: [])
        #expect(withUndated.map(\.locator.messageNumber) == [102, 101, 111, 103], "undated last")
    }

    @Test func spotlightRowsReadTheirFilesForSubjectAndPreview() async throws {
        let spotlight = MockMailSpotlight(items: Self.spotlightItems)
        let context = MailTest.context(spotlight: spotlight, readFile: { try? MailFixtures.data($0) })
        let outcome = try await MailSearchEngine(context: context).run(Self.request(limit: 2))
        #expect(outcome.mode == .spotlight)
        #expect(outcome.total == 3)
        #expect(!outcome.totalIsLowerBound)
        #expect(outcome.rows.count == 2)
        let telekom = outcome.rows[0]
        #expect(telekom.locator == MailLocator(messageNumber: 102, accountID: MailFixtures.privateAccount, mailboxPath: ["INBOX"]))
        #expect(telekom.sender == "Telekom Deutschland <rechnung@telekom.example>")
        #expect(telekom.messageID == "orbit-fake-102@telekom.example")
        #expect(telekom.preview == "Guten Tag Erika Mustermann, Ihre Rechnung für September 2026 ist da. Betrag: 39,95 €. Ihre Telekom")
        #expect(telekom.isRead == nil, "Spotlight does not know it")
        #expect(telekom.accountName == nil)
        #expect(outcome.rows[1].preview?.hasPrefix("Hallo Erika, können wir uns am Donnerstag") == true)
    }

    @Test func spotlightRowsWithoutReadableFilesKeepTheMetadata() async throws {
        let item = MailSpotlightItem(path: MailFixtures.inbox("105.emlx"), subject: "Grillfest am Samstag\r", authors: [" "],
                                     authorAddresses: ["lisa.muster@example.net\r\n"], date: Date(), messageID: nil)
        let outcome = try await MailSearchEngine(context: MailTest.context(spotlight: MockMailSpotlight(items: [item])))
            .run(Self.request())
        #expect(outcome.rows.first?.subject == "Grillfest am Samstag")
        #expect(outcome.rows.first?.sender == "lisa.muster@example.net")
        #expect(outcome.rows.first?.preview == nil)
        // With the file, the subject keeps the "Re:" the importer drops.
        let withFile = try await MailSearchEngine(context: MailTest.context(spotlight: MockMailSpotlight(items: [item]),
                                                                             readFile: { try? MailFixtures.data($0) }))
            .run(Self.request())
        #expect(withFile.rows.first?.subject == "Re: Grillfest am Samstag 🔥")
        #expect(withFile.rows.first?.messageID == "orbit-fake-105@example.net")
    }

    /// Each row reads and parses a message file. A search cancelled meanwhile
    /// (the agent loop cancels a tool past its deadline) stops at the next row
    /// instead of reading the rest in the background.
    @Test func aCancelledSpotlightSearchStopsReadingMessageFiles() async throws {
        let items = (1...20).map { index in
            MailSpotlightItem(path: MailFixtures.inbox("101.emlx"), subject: "Nachricht \(index)",
                              date: MailTest.now.addingTimeInterval(-Double(index) * 60), messageID: "<m-\(index)@example.com>")
        }
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let context = MailTest.context(spotlight: MockMailSpotlight(items: items), readFile: { path in
            reads.withLock { $0 += 1 }
            // The deadline passes while the first file is read.
            withUnsafeCurrentTask { $0?.cancel() }
            return try? MailFixtures.data(path)
        })
        let search = Task { try await MailSearchEngine(context: context).run(Self.request()) }
        let result = await search.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(reads.withLock { $0 } == 1, "no file is read after the cancellation")
    }

    @Test func anIncompleteSpotlightAnswerIsALowerBound() async throws {
        let spotlight = MockMailSpotlight(available: true) { _ in
            MailSpotlightResults(items: Array(Self.spotlightItems.prefix(2)), totalCount: 900, isComplete: true)
        }
        let outcome = try await MailSearchEngine(context: MailTest.context(spotlight: spotlight)).run(Self.request())
        #expect(outcome.total == 2)
        #expect(outcome.totalIsLowerBound)
    }

    // MARK: Mail

    @Test func mailCandidatesAreMatchedRankedAndLocated() {
        let found = MailCandidates(batches: [
            Self.inboxBatch,
            MailTest.batch(mailbox: ["Archiv", "Rechnungen"], [(201, "2026-09-30T10:00:00+02:00", "Rechnung Projekt", "Vodafone <r@vodafone.example>")]),
        ], accounts: MailTest.accounts)
        let all = MailSearchEngine.matchingCandidates(found, request: Self.request())
        #expect(all.map(\.locator.messageNumber) == [101, 111, 201, 999], "newest first")
        #expect(all[0].locator == MailLocator(messageNumber: 101, accountID: MailFixtures.privateAccount, mailboxPath: ["INBOX"]))
        #expect(all[0].accountName == "Privat")
        #expect(all[3].locator == MailLocator(messageNumber: 999, accountID: "", mailboxPath: ["INBOX"]), "unknown account")
        #expect(all[3].subject == "")
        let projekt = MailSearchEngine.matchingCandidates(found, request: Self.request(terms: ["projekt"]))
        #expect(projekt.map(\.locator.messageNumber) == [101, 201])
        let fromLisa = MailSearchEngine.matchingCandidates(found, request: Self.request(words: ["lisa"]))
        #expect(fromLisa.map(\.locator.messageNumber) == [101, 111])
        let byAddress = MailSearchEngine.matchingCandidates(found, request: Self.request(words: ["mama"],
                                                                                        addresses: ["r@vodafone.example"]))
        #expect(byAddress.map(\.locator.messageNumber) == [201])
    }

    @Test func candidatesOutsideTheRangeOrWithBrokenListsAreLeftOut() {
        let found = MailCandidates(batches: [
            MailTest.batch([(1, "2026-08-01T10:00:00+02:00", "Zu alt", "a"), (2, "2026-10-02T10:00:00+02:00", "Gut", "b")]),
            MailCandidates.Batch(account: "A", mailbox: ["X"], ids: [3, 4], dates: [1_790_000_000], subjects: ["a", "b"], senders: ["a", "b"]),
            MailCandidates.Batch(account: "A", mailbox: ["Y"], ids: [nil, 6], dates: [1_790_000_000, nil], subjects: [nil, nil],
                                 senders: [nil, nil]),
        ])
        #expect(MailSearchEngine.matchingCandidates(found, request: Self.request()).map(\.locator.messageNumber) == [2])
    }

    @Test func copiesInSeveralMailboxesAreListedOnceWhenSearchingAll() {
        let message = (id: 111, date: "2026-09-29T10:00:00+02:00", subject: "Quartalszahlen Q3", sender: "Lisa <l@firma.example>")
        let copy = (id: 112, date: message.date, subject: message.subject, sender: message.sender)
        let found = MailCandidates(batches: [
            MailTest.batch(account: "W", mailbox: ["INBOX"], [message]),
            MailTest.batch(account: "W", mailbox: ["[Gmail]", "All Mail"], [copy]),
            MailTest.batch(account: "", mailbox: ["Lokal"], [(id: 113, date: message.date, subject: message.subject,
                                                              sender: message.sender)]),
        ])
        #expect(MailSearchEngine.matchingCandidates(found, request: Self.request(mailboxes: .all)).count == 1)
        #expect(MailSearchEngine.matchingCandidates(found, request: Self.request(mailboxes: .named("x"))).count == 1)
        #expect(MailSearchEngine.matchingCandidates(found, request: Self.request()).count == 3,
                "the inboxes hold no copies of each other")
    }

    @Test func detailsComeFromTheSecondScriptForTheShownRowsOnly() async throws {
        let runner = MailTest.runner(candidates: MailCandidates(batches: [Self.inboxBatch], accounts: MailTest.accounts)) { lines in
            MailSummaries(rows: lines.map { line in
                let number = Int(line.split(separator: "\t").first!)!
                return number == 111
                    ? MailSummaries.Row(number: 111, found: false)
                    : MailSummaries.Row(number: number, found: true, account: "MOVED", mailbox: ["Archiv"], subject: "S",
                                        sender: "X", messageID: "<m-\(number)@example.com>", read: number == 999,
                                        date: 1, preview: "Hallo Erika,\n\n> zitiert\nText")
            })
        }
        let outcome = try await MailSearchEngine(context: MailTest.context(runner)).run(Self.request(limit: 2))
        #expect(outcome.mode == .appleScript)
        #expect(outcome.total == 3)
        #expect(outcome.rows.count == 2)
        #expect(runner.runs.map(\.script) == ["mail-search", "mail-summaries"])
        #expect(runner.runs[1].arguments[0] == "101\t\(MailFixtures.privateAccount)\tINBOX\n111\t\(MailFixtures.workAccount)\tINBOX")
        let first = outcome.rows[0]
        #expect(first.locator == MailLocator(messageNumber: 101, accountID: "MOVED", mailboxPath: ["Archiv"]),
                "where Mail found it")
        #expect(first.messageID == "m-101@example.com")
        #expect(first.isRead == false)
        #expect(first.preview == "Hallo Erika, Text")
        #expect(first.subject == "Projekt Orbit \u{2013} nächste Schritte", "phase one's values stay")
        #expect(outcome.rows[1].messageID == nil, "not found: the row stays without details")
        #expect(outcome.rows[1].accountName == "Arbeit")
    }

    @Test func failingDetailsKeepTheRows() async throws {
        let runner = MockAppleScriptRunner { script, _ in
            if script.name == MailService.searchScript.name {
                return MailTest.json(MailCandidates(batches: [Self.inboxBatch]))
            }
            throw AppleScriptError.timedOut
        }
        let outcome = try await MailSearchEngine(context: MailTest.context(runner)).run(Self.request())
        #expect(outcome.rows.count == 3)
        #expect(outcome.rows.allSatisfy { $0.preview == nil })
    }

    @Test func nothingFoundAsksNoDetails() async throws {
        let runner = MailTest.runner(candidates: MailCandidates(batches: [Self.inboxBatch]))
        let outcome = try await MailSearchEngine(context: MailTest.context(runner)).run(Self.request(terms: ["nirgends"]))
        #expect(outcome.rows.isEmpty)
        #expect(runner.runs.map(\.script) == ["mail-search"])
    }

    @Test func skippedMailboxesAreReported() async throws {
        let runner = MailTest.runner(candidates: MailCandidates(batches: [], complete: false, skipped: [["Archiv"], ["inbox"]]))
        let outcome = try await MailSearchEngine(context: MailTest.context(runner)).run(Self.request(mailboxes: .all))
        #expect(outcome.skippedMailboxes == [["Archiv"], ["inbox"]])
    }

    @Test func deniedAutomationBecomesAPermissionError() async {
        let runner = MockAppleScriptRunner { _, _ in throw AppleScriptError.notAuthorized(.mail) }
        await #expect(throws: ToolError.permissionDenied(.automationMail)) {
            try await MailSearchEngine(context: MailTest.context(runner)).run(Self.request())
        }
    }
}
