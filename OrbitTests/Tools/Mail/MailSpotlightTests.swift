import Foundation
import Testing
@testable import Orbit

@Suite("Mail Spotlight (predicate, modes)")
struct MailSpotlightTests {
    static let query = MailSpotlightQuery(since: Date(timeIntervalSince1970: 1_790_000_000),
                                          until: Date(timeIntervalSince1970: 1_790_600_000), terms: ["rechnung", "2026"],
                                          fromWords: ["lisa", "beispiel"], fromAddresses: ["l@example.com", "x@example.com"])

    @Test func thePredicateCombinesEveryPartAsArguments() {
        let predicate = MailSpotlightPredicate.build(Self.query)
        let format = predicate.predicateFormat
        #expect(format.contains(#"kMDItemContentType == "com.apple.mail.emlx""#))
        #expect(format.contains("kMDItemContentCreationDate >= CAST(") && format.contains("kMDItemContentCreationDate <= CAST("))
        #expect(format.contains(#"kMDItemSubject CONTAINS[cd] "rechnung" OR kMDItemAuthors CONTAINS[cd] "rechnung" OR kMDItemAuthorEmailAddresses CONTAINS[cd] "rechnung" OR kMDItemTextContent BEGINSWITH[cdw] "rechnung""#),
                "each term: anywhere in subject or sender, or from the start of a word in the message text")
        #expect(format.contains(#"kMDItemTextContent BEGINSWITH[cdw] "2026""#))
        #expect(!format.contains(#"kMDItemTextContent BEGINSWITH[cdw] "lisa""#), "the sender filter stays on the sender")
        #expect(format.contains(#"((kMDItemAuthors BEGINSWITH[cdw] "lisa" AND kMDItemAuthors BEGINSWITH[cdw] "beispiel") OR kMDItemAuthorEmailAddresses ==[c] "l@example.com" OR kMDItemAuthorEmailAddresses ==[c] "x@example.com")"#),
                "every sender word starts a word of the name (of a sender without one, the importer records the address there), or a contact's address")
        #expect(!format.contains(#"kMDItemAuthorEmailAddresses BEGINSWITH[cdw]"#),
                "two words never match words of another person's address (\"Lisa Müller <lisa.mueller@beispiel.example>\")")
        #expect(!format.contains(#"kMDItemAuthors CONTAINS[cd] "lisa""#), "never inside a word of the sender")
        let one = MailSpotlightQuery(since: Date(), until: Date(), terms: [], fromWords: ["telekom"], fromAddresses: [])
        #expect(MailSpotlightPredicate.build(one).predicateFormat.hasSuffix(#"(kMDItemAuthors BEGINSWITH[cdw] "telekom" OR kMDItemAuthorEmailAddresses BEGINSWITH[cdw] "telekom")"#),
                "a single word also starts a word of the address: companies by their domain")
        #expect(format.contains(#"kMDItemAuthorEmailAddresses ==[c] "x@example.com""#))
        let compound = predicate as? NSCompoundPredicate
        #expect(compound?.compoundPredicateType == .and)
        #expect(compound?.subpredicates.count == 6, "type, two dates, two terms, the senders")
    }

    @Test func userTextStaysAValue() {
        let sneaky = MailSpotlightQuery(since: Date(), until: Date(), terms: [#"x" || kMDItemSubject == "*"#], fromWords: [],
                                        fromAddresses: [])
        let format = MailSpotlightPredicate.build(sneaky).predicateFormat
        #expect(format.contains(#"kMDItemSubject CONTAINS[cd] "x\" || kMDItemSubject == \"*""#))
        #expect(format.contains(#"kMDItemTextContent BEGINSWITH[cdw] "x\" || kMDItemSubject == \"*""#))
        let plain = MailSpotlightQuery(since: Date(), until: Date(), terms: [], fromWords: [], fromAddresses: [])
        #expect((MailSpotlightPredicate.build(plain) as? NSCompoundPredicate)?.subpredicates.count == 3)
    }

    @Test func modesFollowAvailability() async {
        #expect(MailSearchMode.spotlight.searchesMessageText)
        #expect(!MailSearchMode.appleScript.searchesMessageText)
        #expect(await UnavailableMailSpotlight().searchMode() == .appleScript)
        #expect(UnavailableMailSpotlight().lastKnownSearchMode == .appleScript)
        let available = MockMailSpotlight(available: true)
        #expect(available.lastKnownSearchMode == nil, "not checked yet")
        #expect(await available.searchMode() == .spotlight)
        #expect(available.lastKnownSearchMode == .spotlight)
    }

    @Test func theLiveSearchNeverRunsWithoutAFolder() async throws {
        // Constructed only with an invalid scope: nothing is queried.
        let spotlight = LiveMailSpotlight(scope: URL(string: "https://example.com/mail")!)
        #expect(spotlight.lastKnownAvailability == nil)
        let results = try await spotlight.search(Self.query, timeout: .seconds(1))
        #expect(results.items.isEmpty)
        #expect(await spotlight.isAvailable() == false)
        #expect(spotlight.lastKnownAvailability == false)
        #expect(LiveMailSpotlight.mailStore(home: "/Users/someone").path == "/Users/someone/Library/Mail")
    }

    @Test func aCancelledCheckIsNotRemembered() async {
        let spotlight = LiveMailSpotlight(scope: URL(string: "https://example.com/mail")!)
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await spotlight.isAvailable()
        }
        task.cancel()
        #expect(await task.value == false)
        #expect(spotlight.lastKnownAvailability == nil, "the next search checks again")
    }
}

extension SpotlightIntegrationTests {
    /// Live Spotlight on the invented mail fixtures (OrbitTests/Fixtures/Mail),
    /// scoped to that folder only, never Mail's real store. Needs a
    /// Spotlight-indexed checkout (the repository).
    ///
    ///     ORBIT_SPOTLIGHT_TESTS=1 Scripts/swiftpm.sh test --filter MailSpotlightIntegration
    @Suite("MailSpotlightIntegration (fixtures)")
    struct MailSpotlightIntegrationTests {
        let spotlight = LiveMailSpotlight(scope: URL(fileURLWithPath: MailFixtures.root, isDirectory: true))
        /// The fixtures' dates: September 2026 (601 is from July).
        let since = MailTest.date("2026-08-01T00:00:00Z")
        let until = MailTest.date("2026-10-31T00:00:00Z")

        func numbers(_ query: MailSpotlightQuery) async throws -> [Int] {
            try await spotlight.search(query, timeout: .seconds(10)).items
                .compactMap { MailStorePath.locator(forFile: $0.path)?.messageNumber }
        }

        /// Imports the fixture folder and waits until Spotlight shows every message.
        func prepare() async throws {
            let importer = Process()
            importer.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
            importer.arguments = [MailFixtures.root]
            importer.standardOutput = FileHandle.nullDevice
            importer.standardError = FileHandle.nullDevice
            try importer.run()
            importer.waitUntilExit()
            let all = MailSpotlightQuery(since: MailTest.date("2026-01-01T00:00:00Z"), until: until, terms: [], fromWords: [],
                                         fromAddresses: [])
            let indexed = await SpotlightFixtures.waitUntil(timeout: .seconds(60)) {
                try await numbers(all).count == 18
            }
            try #require(indexed, "Spotlight must index the fixtures (a checkout under /tmp is not indexed)")
        }

        @Test func probeAndSearchesOnTheFixtures() async throws {
            try await prepare()
            #expect(await spotlight.isAvailable())
            #expect(spotlight.lastKnownSearchMode == .spotlight)

            let base = MailSpotlightQuery(since: since, until: until, terms: [], fromWords: [], fromAddresses: [])
            let results = try await spotlight.search(base, timeout: .seconds(10))
            #expect(results.isComplete)
            let everything = results.items.compactMap { MailStorePath.locator(forFile: $0.path)?.messageNumber }
            #expect(Set(everything) == [102, 501, 101, 301, 111, 112, 104, 401, 106, 113, 114, 103, 105, 201], "601 is from July")
            let dates = results.items.compactMap(\.date)
            #expect(dates.count == 14)
            #expect(dates == dates.sorted(by: >), "newest first")
            let telekom = try #require(results.items.first)
            #expect(MailStorePath.locator(forFile: telekom.path)?.messageNumber == 102)
            #expect(telekom.subject == "Ihre Rechnung September 2026")
            #expect(telekom.authors == ["Telekom Deutschland"])
            #expect(telekom.authorAddresses == ["rechnung@telekom.example"])
            #expect(telekom.messageID == "<orbit-fake-102@telekom.example>")
            #expect(telekom.date == MailTest.date("2026-10-01T07:15:00Z"))
            #expect(!telekom.isLikelyJunk)

            var lisa = base
            lisa.fromWords = ["lisa"]
            #expect(Set(try await numbers(lisa)) == [101, 105, 111, 112, 113, 301], "names starting with it, ignoring case, not Annalisa (114)")
            var lisaBeispiel = base
            lisaBeispiel.fromWords = ["Beispiel", "LISA"]
            #expect(Set(try await numbers(lisaBeispiel)) == [101, 111, 112, 113, 301])
            var byAddress = base
            byAddress.fromWords = ["mama"]
            byAddress.fromAddresses = ["RECHNUNG@telekom.example"]
            #expect(try await numbers(byAddress) == [102], "a whole address, ignoring case")

            var subject = base
            subject.terms = ["nachste"]
            #expect(Set(try await numbers(subject)) == [101, 501], "inside words, accents ignored")
            var twoTerms = base
            twoTerms.terms = ["rechnung", "vodafone"]
            #expect(try await numbers(twoTerms) == [201], "each term in the subject or the sender")
            var nowhere = base
            nowhere.terms = ["Zitronenfalter"]
            #expect(try await numbers(nowhere) == [])

            var september = base
            september.since = MailTest.date("2026-09-28T00:00:00Z")
            september.until = MailTest.date("2026-09-30T23:59:59Z")
            #expect(Set(try await numbers(september)) == [101, 104, 111, 112, 301, 501])
        }

        /// Words that occur only in a message's text (verified with mdfind and
        /// NSMetadataQuery, see `MailSpotlightPredicate`).
        @Test func wordsAlsoMatchTheMessageText() async throws {
            try await prepare()
            let base = MailSpotlightQuery(since: since, until: until, terms: [], fromWords: [], fromAddresses: [])
            func found(_ terms: [String]) async throws -> Set<Int> {
                var query = base
                query.terms = terms
                return Set(try await numbers(query))
            }
            #expect(try await found(["quokka"]) == [101], "quoted-printable UTF-8")
            #expect(try await found(["QUOK"]) == [101], "from the start of a word, ignoring case")
            #expect(try await found(["entwurfe"]) == [101], "accents ignored; a hyphen splits words")
            #expect(try await found(["okka"]) == [], "never inside a word of the text")
            #expect(try await found(["manteln"]) == [103], "HTML in ISO-8859-1")
            #expect(try await found(["betrag"]) == [102], "base64, multipart/alternative")
            #expect(try await found(["salat"]) == [105])
            #expect(try await found(["teamordner"]) == [111, 112], "the same message in two mailboxes")
            #expect(try await found(["grusse"]) == [101], "ß = ss")
            #expect(try await found(["Projekt Orb"]) == [101, 501], "a phrase: its words in a row, in the text (101) or the subject (501)")
            #expect(try await found(["Orbit Projekt"]) == [], "not in another order")
            #expect(try await found(["donnerstag", "lisa"]) == [101], "each term in any field: text and sender")
            #expect(try await found(["quokka*"]) == [], "wildcards match literally")
            #expect(try await found(["anbei"]) == [], "a message file with CRLF line endings has no indexed text")
            #expect(try await found(["vodafone"]) == [201], "the sender (not in the text) still matches")
        }

        @Test func theEngineOnTheFixtures() async throws {
            try await prepare()
            let context = MailToolContext(mail: MailService(runner: MockAppleScriptRunner()), spotlight: spotlight,
                                          now: { MailTest.date("2026-10-03T12:00:00+02:00") }, timeZone: MailTest.berlin,
                                          locale: MailTest.german)
            let tool = SearchMailTool(context: context)
            let result = try await tool.run(arguments: ToolArguments(["from": "lisa", "mailbox": "all"]))
            guard case .mails(let items) = result.card else { Issue.record("no mail card"); return }
            #expect(items.map(\.subject) == ["Projekt Orbit \u{2013} nächste Schritte", "Quartalszahlen Q3", "Vertragsentwurf",
                                             "Re: Grillfest am Samstag 🔥"],
                    "the trash and the All Mail copy are left out; subjects keep their Re:")
            #expect(items[0].preview?.hasPrefix("Hallo Erika, können wir uns am Donnerstag") == true)
            #expect(items[0].messageID == "orbit-fake-101@example.com")
            #expect(items[1].mailbox == "INBOX")
            let inbox = try await tool.run(arguments: ToolArguments(["query": "rechnung"]))
            guard case .mails(let invoices) = inbox.card else { Issue.record("no mail card"); return }
            #expect(invoices.map(\.subject) == ["Ihre Rechnung September 2026"], "the August invoice is archived")
            #expect(inbox.text.contains("The words were looked for in subjects, senders and message texts."))
            let body = try await tool.run(arguments: ToolArguments(["query": "quokka", "mailbox": "all"]))
            guard case .mails(let quokkas) = body.card else { Issue.record("no mail card"); return }
            #expect(quokkas.map(\.subject) == ["Projekt Orbit \u{2013} nächste Schritte"], "a word only in the text")
            #expect(body.text.hasPrefix("Found 1 message (query \"quokka\"; all mailboxes except trash, junk, drafts and outbox;"))
        }

        /// A sender's name finds the person at every address (also one on no
        /// contact card (111, 113) and with the name written last name first
        /// (113, "Beispiel, Lisa")), but only senders whose names have words
        /// starting with each word asked for: not "Annalisa Beispielmann" (114).
        /// The same rule as in Mail mode (`MailText.isFrom`).
        @Test func aSendersNameFindsThePersonAtEveryAddress() async throws {
            try await prepare()
            let context = MailToolContext(mail: MailService(runner: MockAppleScriptRunner()), spotlight: spotlight,
                                          contacts: MockContactBook(SampleContacts.all),
                                          now: { MailTest.date("2026-10-03T12:00:00+02:00") }, timeZone: MailTest.berlin,
                                          locale: MailTest.german)
            let tool = SearchMailTool(context: context)
            let byName = try await tool.run(arguments: ToolArguments(["from": "Lisa Beispiel"]))
            guard case .mails(let items) = byName.card else { Issue.record("no mail card"); return }
            #expect(items.map(\.subject) == ["Projekt Orbit \u{2013} nächste Schritte", "Quartalszahlen Q3", "Vertragsentwurf"])
            #expect(items.map(\.senderAddress) == ["lisa.beispiel@example.com", "lisa.beispiel@firma.example", "lb@kanzlei.example"])
            #expect(items.last?.sender == "Beispiel, Lisa", "kMDItemAuthors holds the display name as written")
            #expect(byName.text.contains("from \"Lisa Beispiel\" (or 2 addresses of matching contacts)"))

            let byAddress = try await tool.run(arguments: ToolArguments(["from": "lisa.beispiel@example.com"]))
            guard case .mails(let addressed) = byAddress.card else { Issue.record("no mail card"); return }
            #expect(addressed.map(\.subject) == ["Projekt Orbit \u{2013} nächste Schritte"], "an address finds only that address")

            let base = MailSpotlightQuery(since: since, until: until, terms: [], fromWords: [], fromAddresses: [])
            var beispiel = base
            beispiel.fromWords = ["Beispiel"]
            #expect(Set(try await numbers(beispiel)) == [101, 103, 111, 112, 113, 114, 301], "also Beispiel Shop and Beispielmann")
            var company = base
            company.fromWords = ["telekom"]
            #expect(try await numbers(company) == [102])
            var domain = base
            domain.fromWords = ["kanzlei.example"]
            #expect(try await numbers(domain) == [113], "a word of the address")
            var inside = base
            inside.fromWords = ["isa"]
            #expect(try await numbers(inside) == [], "never inside a word")
        }

        /// Two or more words match the sender's display name only, never words
        /// of another person's address: "Lisa Beispiel" is not Lisa Müller at
        /// beispiel.example (115), "Max Weber" not Max Schmidt at
        /// weber-gmbh.example (117). A sender without a display name is matched
        /// by its address, which Mail's importer records as its name (116); a
        /// single word matches words of the address too. The same rule as in
        /// Mail mode (`MailText.isFrom`).
        @Test func twoWordsMatchTheNameAndOnlyANamelessSendersAddress() async throws {
            try await prepare()
            let july = MailSpotlightQuery(since: MailTest.date("2026-07-02T00:00:00Z"), until: MailTest.date("2026-07-31T00:00:00Z"),
                                          terms: [], fromWords: [], fromAddresses: [])
            func found(_ words: [String], addresses: [String] = []) async throws -> Set<Int> {
                var query = july
                query.fromWords = words
                query.fromAddresses = addresses
                return Set(try await numbers(query))
            }
            #expect(try await found(["Lisa", "Beispiel"]) == [], "not Lisa Müller <lisa.mueller@beispiel.example>")
            #expect(try await found(["Max", "Weber"]) == [116], "not Max Schmidt <max.schmidt@weber-gmbh.example>")
            #expect(try await found(["weber", "MAX"]) == [116])
            #expect(try await found(["Max", "Schmidt"]) == [117])
            #expect(try await found(["Lisa"]) == [115])
            #expect(try await found(["Beispiel"]) == [115], "a single word: also the address")
            #expect(try await found(["weber"]) == [116, 117])
            #expect(try await found(["Lisa", "Beispiel"], addresses: ["LISA.MUELLER@beispiel.example"]) == [115],
                    "a contact's address still counts")

            let context = MailToolContext(mail: MailService(runner: MockAppleScriptRunner()), spotlight: spotlight,
                                          contacts: MockContactBook(SampleContacts.all),
                                          now: { MailTest.date("2026-10-03T12:00:00+02:00") }, timeZone: MailTest.berlin,
                                          locale: MailTest.german)
            let tool = SearchMailTool(context: context)
            let maxWeber = try await tool.run(arguments: ToolArguments(["from": "Max Weber", "since": "2026-07-02",
                                                                        "until": "2026-07-31"]))
            guard case .mails(let items) = maxWeber.card else { Issue.record("no mail card"); return }
            #expect(items.map(\.subject) == ["Angebot Fenster"])
            #expect(items.map(\.senderAddress) == ["max.weber@weber-gmbh.example"])
        }
    }
}
