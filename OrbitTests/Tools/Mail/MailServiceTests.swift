import Foundation
import Testing
@testable import Orbit

@Suite("Mail service (scripts and their JSON)")
struct MailServiceTests {
    @Test func searchPassesItsArgumentsAsTheScriptExpects() async throws {
        let runner = MockAppleScriptRunner(output: #"{"batches":[],"accounts":[],"complete":true,"skipped":[]}"#)
        let service = MailService(runner: runner)
        let since = Date(timeIntervalSince1970: 1_790_000_000.9)
        let until = Date(timeIntervalSince1970: 1_790_600_000)
        _ = try await service.candidates(in: .named("Archiv/Rechnungen"), since: since, until: until, unreadOnly: true,
                                         excludedNames: ["Trash", "Junk"], budgetSeconds: 12)
        _ = try await service.candidates(in: .inbox, since: since, until: until, unreadOnly: false, excludedNames: [])
        #expect(runner.runs == [
            .init(script: "mail-search", arguments: ["named", "Archiv/Rechnungen", "1790000000", "1790600000", "true",
                                                     "Trash\nJunk", "12"]),
            .init(script: "mail-search", arguments: ["inbox", "", "1790000000", "1790600000", "false", "",
                                                     String(MailService.searchBudgetSeconds)]),
        ])
    }

    @Test func decodesWhatTheSearchScriptPrints() async throws {
        // The shape NSJSONSerialization produces in mail-search, with nulls where Mail cannot tell.
        let output = #"{"skipped":[["Archiv"]],"accounts":[{"id":"A1","name":"Privat"},{"id":null,"name":null}],"complete":false,"batches":[{"ids":[101,102],"dates":[1790856120,1790838900.5],"subjects":["Projekt",null],"senders":["Lisa <l@example.com>","x@example.com"],"accounts":["A1",null],"mailboxNames":["INBOX",null]},{"account":"A1","mailbox":["Archiv","Rechnungen"],"ids":[201],"dates":[1786507200],"subjects":["Rechnung"],"senders":["Vodafone <r@example.com>"]}]}"#
        let found = try await MailService(runner: MockAppleScriptRunner(output: output))
            .candidates(in: .inbox, since: Date(), until: Date(), unreadOnly: false, excludedNames: [])
        #expect(found.complete == false)
        #expect(found.skipped == [["Archiv"]])
        #expect(found.accounts == [.init(id: "A1", name: "Privat"), .init(id: "", name: "")])
        #expect(found.batches.count == 2)
        #expect(found.batches[0].ids == [101, 102])
        #expect(found.batches[0].subjects == ["Projekt", nil])
        #expect(found.batches[0].accounts == ["A1", nil])
        #expect(found.batches[0].account == nil)
        #expect(found.batches[1].mailbox == ["Archiv", "Rechnungen"])
        #expect(found.batches[1].dates == [1_786_507_200])
    }

    @Test func decodesTheMailboxesMailCouldNotSearch() async throws {
        let output = #"{"batches":[],"accounts":[],"complete":false,"skipped":[],"failed":[{"mailbox":["inbox"],"error":-1728},{"mailbox":["Archiv","2025"],"error":null}]}"#
        let found = try await MailService(runner: MockAppleScriptRunner(output: output))
            .candidates(in: .inbox, since: Date(), until: Date(), unreadOnly: false, excludedNames: [])
        #expect(found.failed == [.init(mailbox: ["inbox"], error: -1728), .init(mailbox: ["Archiv", "2025"], error: nil)])
        #expect(found.searchedNothing)
        // Answers without the key (older scripts) still decode: nothing failed.
        let old = try await MailService(runner: MockAppleScriptRunner(output: #"{"batches":[],"accounts":[],"complete":true,"skipped":[]}"#))
            .candidates(in: .inbox, since: Date(), until: Date(), unreadOnly: false, excludedNames: [])
        #expect(old.failed.isEmpty)
        #expect(!old.searchedNothing, "no batch, but nothing failed: an empty result")
        #expect(MailCandidates(batches: [], skipped: [["Archiv"]]).searchedNothing)
        #expect(!MailCandidates(batches: [MailTest.batch([])], failed: [.init(mailbox: ["Archiv"], error: 1)]).searchedNothing)
    }

    @Test func summariesSendOneLinePerMessage() async throws {
        let runner = MockAppleScriptRunner(output: #"{"rows":[{"number":101,"found":true,"account":"A1","mailbox":["INBOX"],"subject":"S","sender":"Lisa","messageID":"m@x","read":false,"date":1790856120,"preview":"Hallo"},{"number":7,"found":false}],"complete":true}"#)
        let summaries = try await MailService(runner: runner).summaries(of: [
            MailLocator(messageNumber: 101, accountID: "A1", mailboxPath: ["INBOX"]),
            MailLocator(messageNumber: 7, accountID: "", mailboxPath: ["Archiv", "Tab\tName"]),
        ], previewCharacters: 300)
        #expect(runner.runs.first?.arguments == ["101\tA1\tINBOX\n7\t\tArchiv\tTab Name", "300",
                                                 String(MailService.summariesBudgetSeconds)])
        #expect(summaries.rows.map(\.found) == [true, false])
        #expect(summaries.rows[0].read == false)
        #expect(summaries.rows[0].preview == "Hallo")
    }

    @Test func readDecodesTheMessage() async throws {
        let output = #"{"number":101,"account":"A1","accountName":"Privat","accountAddresses":["erika@example.org"],"mailbox":["INBOX"],"messageID":"m@x","subject":"Projekt","sender":"Lisa <l@example.com>","replyTo":null,"to":[{"name":"Erika","address":"erika@example.org"},{"name":null,"address":"max@example.com"}],"cc":[],"dateReceived":1790856120,"dateSent":null,"read":true,"flagged":false,"attachments":[{"name":"a.pdf","size":2048},{"name":"b.png","size":null}],"body":"Hallo","bodyLength":9000}"#
        let runner = MockAppleScriptRunner(output: output)
        let message = try await MailService(runner: runner)
            .read(MailLocator(messageNumber: 101, accountID: "A1", mailboxPath: ["Archiv", "Rechnungen"]), maxBodyCharacters: 500)
        #expect(runner.runs.first?.arguments == ["101", "A1", "Archiv\nRechnungen", "500"])
        #expect(message.subject == "Projekt")
        #expect(message.to.map(\.display) == ["Erika <erika@example.org>", "max@example.com"])
        #expect(message.dateReceived == Date(timeIntervalSince1970: 1_790_856_120))
        #expect(message.dateSent == nil)
        #expect(message.isRead == true)
        #expect(message.attachments == [.init(name: "a.pdf", size: 2048), .init(name: "b.png", size: nil)])
        #expect(message.bodyLength == 9000)
        #expect(message.locator == MailLocator(messageNumber: 101, accountID: "A1", mailboxPath: ["INBOX"]))
        // Round trip through Codable (the fake encodes the same type).
        #expect(try JSONDecoder().decode(MailMessage.self, from: try JSONEncoder().encode(message)) == message)
    }

    @Test func draftsPassRecipientsAsLinesAndNeverOtherwise() async throws {
        let runner = MockAppleScriptRunner(output: #"{"id":42,"failed":["kaputt"]}"#)
        let created = try await MailService(runner: runner).createDraft(MailDraftContent(
            subject: "Projekt", content: "Hallo\n\nText",
            to: [MailRecipient(address: "lisa@example.com", name: "Lisa Beispiel"), MailRecipient(address: "max@example.com")],
            cc: [MailRecipient(address: "x@example.com", name: "Name\twith tab")]))
        #expect(created == CreatedMailDraft(id: 42, failed: ["kaputt"]))
        #expect(runner.runs == [.init(script: "mail-draft", arguments: [
            "Projekt", "Hallo\n\nText", "lisa@example.com\tLisa Beispiel\nmax@example.com\t",
            "x@example.com\tName with tab",
        ])], "Mail writes from the account it chooses")
        let shown = MockAppleScriptRunner(output: #"{"shown":false}"#)
        #expect(try await MailService(runner: shown).showDraft(id: 42) == false)
        #expect(shown.runs == [.init(script: "mail-show-draft", arguments: ["42"])])
    }

    @Test func repliesPassTheMessageAndDecodeWhatMailFilledIn() async throws {
        // The shape NSJSONSerialization produces in mail-reply, with nulls where Mail does not tell.
        let output = #"{"id":31,"subject":"Re: Projekt","to":[{"name":"Lisa Beispiel","address":"lisa@example.com"}],"cc":[],"sender":"Lisa Beispiel <lisa@example.com>","replyTo":null,"originalSubject":"Projekt","dateReceived":1790856120}"#
        let runner = MockAppleScriptRunner(output: output)
        let locator = MailLocator(messageNumber: 101, accountID: "A1", mailboxPath: ["Archiv", "Rechnungen"])
        let reply = try await MailService(runner: runner).reply(to: locator, toAll: false)
        _ = try await MailService(runner: runner).reply(to: locator, toAll: true)
        #expect(runner.runs == [
            .init(script: "mail-reply", arguments: ["101", "A1", "Archiv\nRechnungen", "false"]),
            .init(script: "mail-reply", arguments: ["101", "A1", "Archiv\nRechnungen", "true"]),
        ])
        #expect(reply == OpenedMailReply(id: 31, subject: "Re: Projekt", to: [.init(name: "Lisa Beispiel", address: "lisa@example.com")],
                                         sender: "Lisa Beispiel <lisa@example.com>", originalSubject: "Projekt",
                                         dateReceived: Date(timeIntervalSince1970: 1_790_856_120)))
        // Mail may not tell the window's id, subject or recipients; the rest stays usable.
        let sparse = MockAppleScriptRunner(output: #"{"id":null,"subject":null,"to":null,"cc":null,"sender":"x@example.com","replyTo":"","originalSubject":"","dateReceived":null}"#)
        let unknown = try await MailService(runner: sparse).reply(to: locator, toAll: false)
        #expect(unknown == OpenedMailReply(id: nil, sender: "x@example.com", replyTo: "", originalSubject: ""))
        // Round trip through Codable (the fake encodes the same type).
        #expect(try JSONDecoder().decode(OpenedMailReply.self, from: try JSONEncoder().encode(reply)) == reply)
        let gone = MailService(runner: MockAppleScriptRunner(output: #"{"error":"notFound"}"#))
        await #expect(throws: MailFailure.messageNotFound) { try await gone.reply(to: locator, toAll: false) }
    }

    @Test func scriptAnswersBecomeTypedFailures() async throws {
        let notFound = MailService(runner: MockAppleScriptRunner(output: #"{"error":"notFound"}"#))
        await #expect(throws: MailFailure.messageNotFound) {
            try await notFound.read(MailLocator(messageNumber: 1, accountID: "", mailboxPath: []), maxBodyCharacters: 1)
        }
        let noMailbox = MailService(runner: MockAppleScriptRunner(output: #"{"error":"mailboxNotFound","mailboxes":[["INBOX"],["Archiv","Rechnungen"]]}"#))
        await #expect(throws: MailFailure.mailboxNotFound(existing: [["INBOX"], ["Archiv", "Rechnungen"]])) {
            try await noMailbox.candidates(in: .named("Rechnungn"), since: Date(), until: Date(), unreadOnly: false, excludedNames: [])
        }
        for output in [#"{"error":"somethingElse"}"#, "kein JSON", #"{"id":"x"}"#] {
            let odd = MailService(runner: MockAppleScriptRunner(output: output))
            await #expect(throws: AppleScriptError.invalidOutput) {
                _ = try await odd.createDraft(MailDraftContent(subject: "", content: "", to: [], cc: []))
            }
        }
    }

    @Test func scriptsAreDeclaredWithTheirApp() {
        #expect(MailService.scripts.map(\.name) == ["mail-search", "mail-summaries", "mail-read", "mail-draft", "mail-reply",
                                                    "mail-show-draft"])
        #expect(MailService.scripts.allSatisfy { $0.app == .mail })
        #expect(AppleScript.bundled.map(\.name)
            == NotesService.scripts.map(\.name) + MailService.scripts.map(\.name) + PhotosService.scripts.map(\.name)
            + FinderService.scripts.map(\.name) + SystemEventsService.scripts.map(\.name))
        // The in-script budgets end well before osascript is stopped.
        #expect(Duration.seconds(MailService.searchBudgetSeconds + 15) < MailService.searchScript.timeout)
        #expect(Duration.seconds(MailService.summariesBudgetSeconds + 10) < MailService.summariesScript.timeout)
    }

    @Test func mailboxSelections() {
        #expect(MailboxSelection.inbox.scriptKind == "inbox")
        #expect(MailboxSelection.named("Archiv").scriptKind == "named")
        #expect(MailboxSelection.named("Archiv").scriptName == "Archiv")
        #expect(MailboxSelection.all.scriptName == "")
        let special: [MailboxSelection] = [.sent, .drafts, .junk, .trash]
        let plain: [MailboxSelection] = [.inbox, .all, .named("x")]
        #expect(special.map(\.needsMail) == [true, true, true, true])
        #expect(plain.map(\.needsMail) == [false, false, false])
    }
}
