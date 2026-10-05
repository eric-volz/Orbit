import Foundation
import Testing
@testable import Orbit

/// Event and reminder cards: what a click or Return shows, what VoiceOver
/// hears, that the keyboard reaches them, and the note when an app does not
/// open (the keyboard paths themselves: `CalendarCardKeyboardTests`, gated).
@Suite("Event and reminder cards")
@MainActor
struct CalendarCardTests {
    private let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private let german = Locale(identifier: "de_DE")

    static let event = EventItem(id: "ev-1|1791190800", title: "Zahnarzt", start: CalendarTest.date("2026-10-05T08:30"),
                                 end: CalendarTest.date("2026-10-05T09:15"), isAllDay: false, location: "Praxis Dr. Beispiel",
                                 calendarName: "Privat", calendarColor: "#1BADF8", notes: nil, eventIdentifier: "ev-1")
    static let reminder = ReminderItem(id: "rem-1", title: "Milch kaufen", due: CalendarTest.date("2026-10-04T18:00"), dueHasTime: true,
                                       isCompleted: false, listName: "Einkauf", listColor: "#FF9500", notes: nil)

    @Test func aClickOrReturnShowsTheItemInItsApp() async {
        let opener = RecordingCalendarAppOpener()
        let actions = CalendarCardActions(opener: opener)
        await actions.showEvent(Self.event).value
        await actions.showReminder(Self.reminder).value
        var old = Self.event
        old.eventIdentifier = nil
        await actions.showEvent(old).value
        #expect(opener.shownEvents == ["ev-1", nil], "a card saved before opens Calendar itself")
        #expect(opener.shownReminders == ["rem-1"])
        #expect(actions.failure == nil)
    }

    @Test func anAppThatDoesNotOpenIsExplainedUnderTheInput() async {
        let opener = RecordingCalendarAppOpener()
        opener.failEverything()
        let actions = CalendarCardActions(opener: opener)
        await actions.showEvent(Self.event).value
        #expect(actions.failure == .init(reason: .calendarNotOpened, count: 1))
        #expect(InputHint(calendarFailure: actions.failure!) == .calendarNotOpened)
        #expect(InputHint.calendarNotOpened.text == "The Calendar app could not be opened.")
        await actions.showReminder(Self.reminder).value
        #expect(actions.failure == .init(reason: .remindersNotOpened, count: 2))
        #expect(InputHint(calendarFailure: actions.failure!).text == "The Reminders app could not be opened.")
    }

    @Test func theKeyboardReachesEventAndReminderCards() {
        #expect(FileCardCoordinator.takesKeyboard(.events([Self.event])))
        #expect(FileCardCoordinator.takesKeyboard(.reminders([Self.reminder])))
        #expect(!FileCardCoordinator.takesKeyboard(.events([])))
        #expect(!FileCardCoordinator.takesKeyboard(.reminders([])))
        #expect(!FileCardCoordinator.takesKeyboard(.contacts([])))
        let events = ChatItem(kind: .card(.events([Self.event])))
        let reminders = ChatItem(kind: .card(.reminders([Self.reminder])))
        let info = ChatItem(kind: .card(.info(InfoItem(title: "x", systemImage: "info.circle"))))
        #expect(FileCardCoordinator.keyboardCardIDs(in: [events, info, reminders]) == [events.id, reminders.id])
    }

    @Test func voiceOverHearsAnEventsTitleTimePlaceCalendarAndState() {
        GermanInterface.run {
            let text = EventCardFormat.announcement(for: Self.event, calendar: berlin, locale: german)
            #expect(text.hasPrefix("Zahnarzt, Mo"))
            #expect(text.contains("5. Okt."))
            #expect(text.hasSuffix(" · 8:30 bis 9:15, Praxis Dr. Beispiel, Privat")
                    || text.hasSuffix(" · 08:30 bis 09:15, Praxis Dr. Beispiel, Privat"))
            var declined = Self.event
            declined.isDeclined = true
            declined.isRecurring = true
            #expect(EventCardFormat.announcement(for: declined, calendar: berlin, locale: german)
                .hasSuffix(", Privat, Wiederholt sich, Abgelehnt"))
            var canceled = Self.event
            canceled.isCanceled = true
            canceled.isDeclined = true
            #expect(EventCardFormat.state(of: canceled) == "Abgesagt", "canceled wins")
            #expect(EventCardFormat.state(of: Self.event) == nil)
            var untitled = Self.event
            untitled.title = ""
            #expect(EventCardFormat.announcement(for: untitled, calendar: berlin, locale: german).hasPrefix("Neuer Termin, "))
        }
        // In English the key disambiguates ("Canceled (event)"); the text is "Canceled".
        var canceled = Self.event
        canceled.isCanceled = true
        #expect(EventCardFormat.state(of: canceled) == "Canceled")
        let english = EventCardFormat.announcement(for: Self.event, calendar: berlin, locale: Locale(identifier: "en_US"))
        #expect(CardFormattingTests.plain(english).hasSuffix(" · 8:30 AM to 9:15 AM, Praxis Dr. Beispiel, Privat"))
    }

    @Test func voiceOverHearsAReminderAndWhetherItIsOverdue() {
        let now = CalendarTest.date("2026-10-04T20:00")
        GermanInterface.run {
            let overdue = ReminderCardFormat.announcement(for: Self.reminder, now: now, calendar: berlin, locale: german)
            #expect(overdue.hasPrefix("Milch kaufen, So"))
            #expect(overdue.hasSuffix(", Einkauf, Überfällig"))
            var done = Self.reminder
            done.isCompleted = true
            #expect(ReminderCardFormat.announcement(for: done, now: now, calendar: berlin, locale: german).hasSuffix(", Einkauf, Erledigt"))
            var undated = Self.reminder
            undated.due = nil
            #expect(ReminderCardFormat.announcement(for: undated, now: now, calendar: berlin, locale: german) == "Milch kaufen, Einkauf, Offen")
        }
        var undated = Self.reminder
        undated.due = nil
        #expect(ReminderCardFormat.announcement(for: undated, now: now, calendar: berlin, locale: Locale(identifier: "en_US"))
                == "Milch kaufen, Einkauf, Not completed")
        var today = Self.reminder
        today.due = CalendarTest.date("2026-10-04")
        today.dueHasTime = false
        #expect(!ReminderCardFormat.isOverdue(today, now: now, calendar: berlin), "due today without a time")
    }

    /// Chats saved before the new fields still decode, and the new fields survive a round trip.
    @Test func cardsOfOldAndNewChatsDecode() throws {
        let old = """
            {"events":{"_0":[{"id":"e1","title":"Zahnarzt","start":800000000,"end":800003600,"isAllDay":false}]}}
            """
        let decoded = try JSONDecoder().decode(ResultCard.self, from: Data(old.utf8))
        guard case .events(let items) = decoded, let item = items.first else {
            Issue.record("events")
            return
        }
        #expect(item.eventIdentifier == nil && item.isDeclined == nil && item.wasCreated == nil && item.isRecurring == nil)
        let oldReminder = #"{"reminders":{"_0":[{"id":"r1","title":"Milch","dueHasTime":false,"isCompleted":false}]}}"#
        guard case .reminders(let reminders) = try JSONDecoder().decode(ResultCard.self, from: Data(oldReminder.utf8)) else {
            Issue.record("reminders")
            return
        }
        #expect(reminders.first?.completionDate == nil && reminders.first?.wasCreated == nil)

        var created = Self.event
        created.wasCreated = true
        created.isRecurring = true
        var completed = Self.reminder
        completed.completionDate = CalendarTest.date("2026-10-03T17:30")
        completed.wasCreated = true
        for card in [ResultCard.events([created]), .reminders([completed])] {
            #expect(try JSONDecoder().decode(ResultCard.self, from: JSONEncoder().encode(card)) == card)
        }
    }
}
