import Foundation
import os
import Testing
@testable import Orbit

@Suite("Mail cards open messages, show drafts in Mail and copy the text of replies")
@MainActor
struct MailCardActionsTests {
    /// Opens nothing: records the URLs, or fails.
    final class Opener: MessageLinkOpening, Sendable {
        private let state: OSAllocatedUnfairLock<(urls: [URL], fails: Bool)>

        init(fails: Bool = false) {
            state = OSAllocatedUnfairLock(initialState: ([], fails))
        }

        var urls: [URL] { state.withLock { $0.urls } }

        func open(_ url: URL) async throws {
            struct NoApp: Error {}
            let fails = state.withLock { state in
                if !state.fails { state.urls.append(url) }
                return state.fails
            }
            if fails { throw NoApp() }
        }
    }

    static let item = MailItem(id: "mail:101:A:INBOX", messageID: "orbit-fake-101@example.com", sender: "Lisa",
                               subject: "Projekt Orbit")
    static let draft = MailDraftItem(to: ["lisa@example.com"], cc: [], subject: "Projekt", body: "Text",
                                     isOpenInMail: true, draftID: 7)
    static let reply = MailDraftItem(to: ["Lisa <lisa@example.com>"], cc: [], subject: "Re: Projekt", body: "Hallo Lisa,\n\npasst.",
                                     isOpenInMail: true, draftID: 8, reply: MailReplyInfo(toAll: false, isTextOnClipboard: true))

    @Test func aRowOpensTheMessageThroughItsLink() async {
        let opener = Opener()
        let runner = MockAppleScriptRunner()
        let actions = MailCardActions(mail: MailService(runner: runner), opener: opener)
        #expect(MailCardActions.canOpen(Self.item))
        await actions.open(Self.item).value
        #expect(opener.urls == [URL(string: "message://%3Corbit-fake-101@example.com%3E")!])
        #expect(runner.runs.isEmpty, "no script for opening a message")
        #expect(actions.failure == nil)
        var withoutID = Self.item
        withoutID.messageID = nil
        #expect(!MailCardActions.canOpen(withoutID))
        await actions.open(withoutID).value
        #expect(opener.urls.count == 1)
    }

    @Test func aMessageThatDoesNotOpenIsExplained() async {
        let actions = MailCardActions(mail: MailService(runner: MockAppleScriptRunner()), opener: Opener(fails: true))
        await actions.open(Self.item).value
        #expect(actions.failure == MailCardActions.Failure(subject: "Projekt Orbit", reason: .messageNotOpened, count: 1))
        #expect(InputHint(mailFailure: actions.failure!).text == "The email “Projekt Orbit” could not be opened in Mail.")
        var untitled = Self.item
        untitled.subject = ""
        await actions.open(untitled).value
        #expect(actions.failure?.count == 2)
        #expect(InputHint(mailFailure: actions.failure!) == .mailNotOpened(subject: "(No Subject)"))
    }

    @Test func showingADraftRunsTheShowScript() async {
        let runner = MockAppleScriptRunner(output: #"{"shown":true}"#)
        let actions = MailCardActions(mail: MailService(runner: runner), opener: Opener())
        #expect(MailCardActions.canShow(Self.draft))
        await actions.showDraft(Self.draft).value
        #expect(runner.runs == [.init(script: "mail-show-draft", arguments: ["7"])])
        #expect(actions.failure == nil)
    }

    @Test func draftsThatCannotBeShownAreExplained() async {
        let runner = MockAppleScriptRunner(output: #"{"shown":false}"#)
        let actions = MailCardActions(mail: MailService(runner: runner), opener: Opener())
        await actions.showDraft(Self.draft).value
        #expect(actions.failure?.reason == .draftClosed)
        #expect(InputHint(mailFailure: actions.failure!).text.contains("“Drafts”"))

        runner.respond { _, _ in throw AppleScriptError.notAuthorized(.mail) }
        await actions.showDraft(Self.draft).value
        #expect(InputHint(mailFailure: actions.failure!) == .mailNotPermitted)
        #expect(InputHint.mailNotPermitted.text.contains("Permissions"))

        runner.respond { _, _ in throw AppleScriptError.appUnavailable(.mail) }
        await actions.showDraft(Self.draft).value
        #expect(InputHint(mailFailure: actions.failure!) == .mailDraftNotShown)
        #expect(actions.failure?.count == 3)
    }

    @Test func aReplysTextIsCopiedAgain() async {
        let runner = MockAppleScriptRunner()
        let pasteboard = RecordingPasteboard()
        let actions = MailCardActions(mail: MailService(runner: runner), opener: Opener(), pasteboard: pasteboard)
        #expect(MailCardActions.canCopyText(Self.reply))
        #expect(await actions.copyText(Self.reply).value)
        #expect(pasteboard.texts == ["Hallo Lisa,\n\npasst."])
        #expect(runner.runs.isEmpty, "copying needs no script")
        #expect(actions.failure == nil)
        // A new message has its text in Mail's window; a reply without text has nothing to copy.
        #expect(!MailCardActions.canCopyText(Self.draft))
        var empty = Self.reply
        empty.body = ""
        #expect(!MailCardActions.canCopyText(empty))
        #expect(await actions.copyText(empty).value == false)
        #expect(pasteboard.texts.count == 1)
        // "Show in Mail" brings the reply window to the front like a draft's.
        #expect(MailCardActions.canShow(Self.reply))
    }

    @Test func aClipboardThatRefusesIsExplained() async {
        let actions = MailCardActions(mail: MailService(runner: MockAppleScriptRunner()), opener: Opener(),
                                      pasteboard: RecordingPasteboard(fails: true))
        #expect(await actions.copyText(Self.reply).value == false)
        #expect(actions.failure == MailCardActions.Failure(subject: "", reason: .textNotCopied, count: 1))
        #expect(InputHint(mailFailure: actions.failure!) == .mailTextNotCopied)
        #expect(InputHint.mailTextNotCopied.text == "The text could not be copied to the clipboard.")
        // Without a clipboard (cards in tests and restricted sessions) nothing is written.
        let disabled = MailCardActions(mail: MailService(runner: MockAppleScriptRunner()), opener: Opener())
        #expect(await disabled.copyText(Self.reply).value == false)
    }

    @Test func theReplyCardSaysWhereTheTextIs() {
        #expect(MailDraftCardView.replyStatus(MailReplyInfo(toAll: false, isTextOnClipboard: true), hasText: true)
            == "Reply opened in Mail: paste the text from the clipboard with ⌘V")
        #expect(MailDraftCardView.replyStatus(MailReplyInfo(toAll: true, isTextOnClipboard: false), hasText: true)
            == "Reply opened in Mail: copy the text with “Copy Text” and paste it with ⌘V")
        #expect(MailDraftCardView.replyStatus(MailReplyInfo(toAll: false, isTextOnClipboard: false), hasText: false)
            == "Reply opened in Mail: write it there")
    }

    @Test func oldDraftCardsHaveNoButton() async throws {
        var old = Self.draft
        old.draftID = nil
        #expect(!MailCardActions.canShow(old))
        var closed = Self.draft
        closed.isOpenInMail = false
        #expect(!MailCardActions.canShow(closed))
        // Chats saved before the draft id existed still load.
        let saved = #"{"to":["a@example.com"],"cc":[],"subject":"S","body":"B","isOpenInMail":true}"#
        let decoded = try JSONDecoder().decode(MailDraftItem.self, from: Data(saved.utf8))
        #expect(decoded.draftID == nil)
        #expect(decoded.reply == nil, "a draft card saved before replies opened Mail's window")
        #expect(!MailCardActions.canCopyText(decoded))
        // The reply-as-new-message cards of the first version: a draft id, no reply info.
        let older = #"{"to":["lisa@example.com"],"cc":[],"subject":"Re: S","body":"B\n\n> zitiert","isOpenInMail":true,"draftID":4}"#
        let olderReply = try JSONDecoder().decode(MailDraftItem.self, from: Data(older.utf8))
        #expect(olderReply.reply == nil)
        #expect(MailCardActions.canShow(olderReply))
        #expect(try JSONDecoder().decode(MailDraftItem.self, from: JSONEncoder().encode(Self.draft)) == Self.draft)
        #expect(try JSONDecoder().decode(MailDraftItem.self, from: JSONEncoder().encode(Self.reply)) == Self.reply)
        // In a saved chat the card is inside a result card.
        let card = ResultCard.mailDraft(Self.reply)
        #expect(try JSONDecoder().decode(ResultCard.self, from: JSONEncoder().encode(card)) == card)
    }
}
