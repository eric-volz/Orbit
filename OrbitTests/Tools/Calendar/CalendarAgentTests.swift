import Foundation
import Testing
@testable import Orbit

/// The calendar tools in the agent loop (mock provider, calendars in memory):
/// Phase 4's acceptance: tomorrow's events are listed, and a new event is
/// only created after its card was confirmed.
@Suite("Calendar tools in the agent loop")
@MainActor
struct CalendarAgentTests {
    typealias T = CalendarTest

    private func harness(_ store: MockCalendarStore, calls: [ToolCall],
                         answer: String = "Erledigt.") -> AgentHarness {
        let context = CalendarToolContext(store: store, now: { T.now }, timeZone: T.berlin)
        return AgentHarness(tools: CalendarTools.all(context: context) + ReminderTools.all(context: context),
                            scripts: [MockScript.toolCalls(calls), MockScript.answer(answer)])
    }

    @Test func tomorrowsEventsReachTheModelAndTheCard() async throws {
        let store = MockCalendarStore(events: ListEventsToolTests.week)
        let harness = harness(store, calls: [MockScript.call("c1", "list_events", ["from": "2026-10-05", "to": "2026-10-05"])],
                              answer: "Morgen hast du 7 Termine.")
        await harness.send("Was habe ich morgen?")
        let result = try #require(harness.result(for: "c1"))
        #expect(!result.isError)
        #expect(result.content.contains("7 events, sorted by start."))
        guard case .events(let items)? = harness.cards.first else {
            Issue.record("an event card")
            return
        }
        #expect(items.count == 7)
        #expect(harness.statuses.map(\.text) == ["Found 7 events"])
        #expect(harness.disclosures == [[ContentDisclosure(kind: .events, count: 7)]])
        harness.expectValidHistory()
    }

    @Test func aNewEventIsOnlyCreatedAfterTheCardWasConfirmed() async throws {
        let store = MockCalendarStore()
        let call = MockScript.call("c1", "create_event", ["title": "Friseur", "start": "2026-10-06T15:00", "end": "2026-10-06T15:45"])
        let harness = harness(store, calls: [call])
        harness.agent.send("Trag mir übermorgen um 15 Uhr Friseur ein")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        let request = try #require(harness.agent.pendingConfirmation)
        #expect(request.title == "Create event")
        #expect(request.fields.map(\.value) == ["Friseur", "2026-10-06T15:00:00+02:00", "2026-10-06T15:45:00+02:00", "", "", "Privat"])
        #expect(store.createdEvents.isEmpty, "nothing is created while the card waits")
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.createdEvents.isEmpty)

        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: [:]))
        await harness.agent.waitUntilIdle()
        #expect(store.createdEvents.count == 1)
        #expect(store.createdEvents.first?.start == T.date("2026-10-06T15:00"))
        #expect(harness.confirmations.map(\.status) == [.approved])
        #expect(harness.statuses.map(\.text) == ["Created event “Friseur”"])
        guard case .events(let items)? = harness.cards.first else {
            Issue.record("the created event as a card")
            return
        }
        #expect(items.first?.wasCreated == true)
        // The result names the calendar the event went to (the default one, which the model did not name).
        #expect(harness.disclosures == [[ContentDisclosure(kind: .calendarNames, count: 1)]])
        harness.expectValidHistory()
    }

    @Test func aDeclinedCardCreatesNothing() async throws {
        let store = MockCalendarStore()
        let call = MockScript.call("c1", "create_event", ["title": "Friseur", "start": "2026-10-06T15:00", "end": "2026-10-06T15:45"])
        let harness = harness(store, calls: [call])
        harness.agent.send("Trag Friseur ein")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        harness.agent.resolveConfirmation(try #require(harness.agent.pendingConfirmation).id, decision: .cancelled)
        await harness.agent.waitUntilIdle()
        #expect(store.createdEvents.isEmpty)
        #expect(harness.result(for: "c1")?.content == "The user declined this action. Nothing was changed.")
    }

    @Test func editsOnTheCardAreCheckedAgainBeforeAnythingIsCreated() async throws {
        let store = MockCalendarStore()
        let call = MockScript.call("c1", "create_event", ["title": "Friseur", "start": "2026-10-06T15:00", "end": "2026-10-06T15:45"])
        let harness = harness(store, calls: [call])
        harness.agent.send("Trag Friseur ein")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        let request = try #require(harness.agent.pendingConfirmation)
        // The user moves the end before the start.
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: ["end": "2026-10-06T14:00:00+02:00"]))
        await harness.agent.waitUntilIdle()
        #expect(store.createdEvents.isEmpty)
        #expect(harness.confirmations.map(\.status) == [.notRun])
        #expect(harness.result(for: "c1")?.content
            == "Not run: the user edited the values before confirming, but they are invalid: 'end' (Tue 2026-10-06 14:00) must be after 'start' (Tue 2026-10-06 15:00). Nothing was changed.")
    }

    @Test func validEditsAreCreatedAsEdited() async throws {
        let store = MockCalendarStore()
        let call = MockScript.call("c1", "create_event", ["title": "Friseur", "start": "2026-10-06T15:00", "end": "2026-10-06T15:45"])
        let harness = harness(store, calls: [call])
        harness.agent.send("Trag Friseur ein")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        let request = try #require(harness.agent.pendingConfirmation)
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: [
            "title": "Friseur Beispiel", "start": "2026-10-06T16:00:00+02:00", "end": "2026-10-06T17:00:00+02:00",
            "location": "Hauptstraße 5",
        ]))
        await harness.agent.waitUntilIdle()
        #expect(store.createdEvents == [NewEvent(title: "Friseur Beispiel", start: T.date("2026-10-06T16:00"),
                                                 end: T.date("2026-10-06T17:00"), isAllDay: false, location: "Hauptstraße 5",
                                                 notes: nil, calendarID: "cal-privat")])
    }

    @Test func anUnknownCalendarIsAskedAboutWithoutACard() async throws {
        let store = MockCalendarStore()
        let call = MockScript.call("c1", "create_event", ["title": "Friseur", "start": "2026-10-06T15:00",
                                                          "end": "2026-10-06T15:45", "calendar": "Urlaub"])
        let harness = harness(store, calls: [call], answer: "Welchen Kalender meinst du?")
        await harness.send("Trag Friseur in Urlaub ein")
        #expect(harness.confirmations.isEmpty, "the user never confirms a call that cannot work")
        #expect(store.createdEvents.isEmpty)
        let result = try #require(harness.result(for: "c1"))
        #expect(result.isError && result.content.hasPrefix("Not found: There is no calendar named \"Urlaub\"."))
        #expect(harness.statuses.map(\.text) == ["Not found"])
    }

    @Test func addOnlyAccessShowsThePermissionNotice() async throws {
        let store = MockCalendarStore(access: .writeOnly)
        let call = MockScript.call("c1", "create_event", ["title": "Friseur", "start": "2026-10-06T15:00", "end": "2026-10-06T15:45"])
        let harness = harness(store, calls: [call])
        await harness.send("Trag Friseur ein")
        #expect(harness.confirmations.isEmpty)
        #expect(harness.notices.map(\.message) == ["Orbit does not have full access to your calendars."])
        #expect(harness.notices.first?.action == .openPermissionSettings)
    }

    @Test func aReminderIsOnlyCreatedAfterItsCardWasConfirmed() async throws {
        let store = MockCalendarStore()
        let call = MockScript.call("r1", "create_reminder", ["title": "Lisa anrufen", "due": "2026-10-05T09:00"])
        let harness = harness(store, calls: [call])
        harness.agent.send("Erinnere mich morgen um 9, Lisa anzurufen")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        let request = try #require(harness.agent.pendingConfirmation)
        #expect(request.fields.map(\.value) == ["Lisa anrufen", "2026-10-05T09:00:00+02:00", "Erinnerungen"])
        #expect(store.createdReminders.isEmpty)
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: ["due": "2026-10-05"]))
        await harness.agent.waitUntilIdle()
        #expect(store.createdReminders.map(\.due) == [ReminderDue(date: T.date("2026-10-05"), hasTime: false)],
                "a day without a time, as edited")
        #expect(harness.statuses.map(\.text) == ["Created reminder “Lisa anrufen”"])
    }

    /// UX-4: the card's "Due" can be removed ("No Date"), and the reminder is created without a due date, or get a
    /// time ("With time").
    @Test func theCardsDueDateCanBeRemovedOrGetATime() async throws {
        let store = MockCalendarStore()
        let removing = harness(store, calls: [MockScript.call("r1", "create_reminder", ["title": "Müll rausbringen", "due": "2026-10-05"])])
        removing.agent.send("Erinnere mich morgen an den Müll")
        #expect(await AgentHarness.eventually { removing.agent.pendingConfirmation != nil })
        let request = try #require(removing.agent.pendingConfirmation)
        let due = try #require(request.fields.first { $0.id == "due" })
        #expect(due.isOptionalDate == true && due.value == "2026-10-05")
        #expect(request.fields.filter { $0.id != "due" }.allSatisfy { $0.isOptionalDate == nil })
        removing.agent.resolveConfirmation(request.id, decision: .approved(edits: ConfirmationEdits.changes(
            fields: request.fields, values: ["due": ""], timeZone: T.berlin)))
        await removing.agent.waitUntilIdle()
        #expect(removing.confirmations.map(\.status) == [.approved], "not \"Nicht ausgeführt\"")
        #expect(store.createdReminders.map(\.due) == [nil], "no due date")
        #expect(removing.confirmations.first?.request.fields.first { $0.id == "due" }?.value == "",
                "the decided card reads \"Ohne Datum\"")
        let result = try #require(removing.result(for: "r1"))
        #expect(result.content.contains("\"Müll rausbringen\", without a due date"))

        let timed = MockCalendarStore()
        let withTime = harness(timed, calls: [MockScript.call("r1", "create_reminder", ["title": "Müll rausbringen", "due": "2026-10-05"])])
        withTime.agent.send("Erinnere mich morgen an den Müll")
        #expect(await AgentHarness.eventually { withTime.agent.pendingConfirmation != nil })
        let card = try #require(withTime.agent.pendingConfirmation)
        let switched = try #require(ConfirmationDateValue.switching("2026-10-05", toTime: true, timeZone: T.berlin))
        withTime.agent.resolveConfirmation(card.id, decision: .approved(edits: ["due": switched]))
        await withTime.agent.waitUntilIdle()
        #expect(timed.createdReminders.map(\.due) == [ReminderDue(date: T.date("2026-10-05T09:00"), hasTime: true)],
                "\"With time\" gives 9:00, an alert the user can still move on the card")
    }
}
