import Foundation
import Testing
@testable import Orbit

/// A11Y-1: what the keyboard selects on mail, note and draft cards, and what
/// VoiceOver hears then (the keyboard paths themselves: `CardKeyboardTests`,
/// gated).
@Suite("Card keyboard: rows, buttons and what VoiceOver hears")
struct CardKeyboardLogicTests {
    private let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private let german = Locale(identifier: "de_DE")
    private let now = FlexibleDate.parse("2026-10-04T12:00:00+02:00")!.date

    @Test func voiceOverHearsSenderSubjectDateAndWhetherAMessageIsUnread() {
        let unread = MailItem(id: "mail:1::INBOX", messageID: "a@example.com", sender: "Lisa Beispiel",
                              subject: "Projekt Orbit \u{2013} nächste Schritte",
                              date: FlexibleDate.parse("2026-10-03T16:40:00+02:00")!.date, isRead: false)
        #expect(MailCardFormat.announcement(for: unread, now: now, calendar: berlin, locale: Locale(identifier: "en_US"))
                == "Lisa Beispiel, Projekt Orbit \u{2013} nächste Schritte, Yesterday, Unread")
        let read = MailItem(id: "mail:2::INBOX", sender: "Telekom", subject: "", isRead: true)
        #expect(MailCardFormat.announcement(for: read, now: now, calendar: berlin, locale: german) == "Telekom, (No Subject)")
    }

    @Test func voiceOverHearsANotesTitleFolderAndDate() {
        let note = NoteItem(id: "x-coredata://n1", title: "Umzug", excerpt: "Kartons bestellen", folder: "Privat",
                            modified: FlexibleDate.parse("2026-10-04T09:15:00+02:00")!.date)
        #expect(NoteCardFormat.announcement(for: note, now: now, calendar: berlin, locale: german) == "Umzug, Privat, 9:15")
        #expect(NoteCardFormat.announcement(for: NoteItem(id: "x-coredata://n2", title: ""), now: now, calendar: berlin,
                                            locale: german) == "New Note")
    }

    /// The keyboard selects a draft card's buttons in the order shown:
    /// "Copy Text" before "Show in Mail".
    @Test func aDraftCardsButtonsInTheOrderShown() {
        let reply = MailDraftItem(to: ["Lisa"], cc: [], subject: "Re: Projekt", body: "Passt.", isOpenInMail: true, draftID: 8,
                                  reply: MailReplyInfo(toAll: false, isTextOnClipboard: true))
        #expect(MailDraftButton.available(for: reply) == [.copyText, .show])
        #expect(MailDraftButton.available(for: reply).map(\.title) == ["Copy Text", "Show in Mail"])
        var unnamed = reply
        unnamed.draftID = nil
        #expect(MailDraftButton.available(for: unnamed) == [.copyText], "Mail did not name the window")
        var empty = reply
        empty.body = ""
        #expect(MailDraftButton.available(for: empty) == [.show], "nothing to copy")
        let draft = MailDraftItem(to: ["Lisa"], cc: [], subject: "Projekt", body: "Hallo", isOpenInMail: true, draftID: 7)
        #expect(MailDraftButton.available(for: draft) == [.show])
        var closed = draft
        closed.isOpenInMail = false
        #expect(MailDraftButton.available(for: closed).isEmpty)
    }
}

/// UX-2: a hint under the input is also read out (the keyboard stays where it
/// was, so VoiceOver would not notice it) and goes away again.
@Suite("Input hints")
@MainActor
struct InputHintPresenterTests {
    @Test func aHintIsShownReadOutAndHiddenAgain() async {
        let announcer = RecordingAnnouncer()
        let hints = InputHintPresenter(announcer: announcer, duration: .milliseconds(80))
        hints.show(.mailNotPermitted)
        #expect(hints.hint == .mailNotPermitted)
        #expect(announcer.announcements == [InputHint.mailNotPermitted.text])
        #expect(announcer.priorities == [.high])
        #expect(await AgentHarness.eventually { hints.hint == nil })

        hints.show(.notesNotPermitted)
        hints.hide()
        #expect(hints.hint == nil)
        #expect(announcer.announcements.last == "Orbit is not allowed to control Notes. You can allow it in Orbit’s settings under “Permissions”.")
    }

    @Test func aNewHintReplacesTheOldOneAndRestartsItsTime() async throws {
        let hints = InputHintPresenter(announcer: RecordingAnnouncer(), duration: .milliseconds(600))
        hints.show(.stillRunning)
        try await Task.sleep(for: .milliseconds(400))
        hints.show(.confirmFirst)
        try await Task.sleep(for: .milliseconds(300))
        #expect(hints.hint == .confirmFirst, "the first hint's time does not end the second one")
        #expect(await AgentHarness.eventually { hints.hint == nil })
    }
}
