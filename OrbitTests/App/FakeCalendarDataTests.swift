#if DEBUG
import Foundation
import Testing
@testable import Orbit

/// The DEBUG fake-data mode's events and reminders (events.json,
/// reminders.json in OrbitTests/Fixtures/PersonalData): relative dates,
/// recurring events, created items and what Orbit did, as `orbitctl state`
/// shows it. EventKit is never touched.
@Suite("Fake calendar data (DEBUG)")
struct FakeCalendarDataTests {
    typealias T = CalendarTest

    /// Launched on Sunday 2026-10-04 at 20:00 in Berlin.
    static func data(folder: URL = FakePersonalDataTests.fixtures, now: Date = T.now) -> (FakeCalendarData, [String]) {
        var errors: [String] = []
        let data = FakeCalendarData(folder: folder, now: now, timeZone: T.berlin, errors: &errors)
        return (data, errors)
    }

    static func context(_ data: FakeCalendarData) -> CalendarToolContext {
        CalendarToolContext(store: FakeCalendarStore(data: data), now: { T.now }, timeZone: T.berlin)
    }

    @Test func loadsTheInventedCalendarsEventsAndReminders() throws {
        let (data, errors) = Self.data()
        #expect(errors.isEmpty)
        #expect(data.calendars.map(\.title) == ["Privat", "Arbeit", "Familie", "Feiertage", "Sport", "Sport"])
        #expect(data.calendars.map(\.allowsModifications) == [true, true, true, false, true, false],
                "the second \"Sport\" is Lisa's, shared to view only")
        #expect(data.lists.map(\.title) == ["Erinnerungen", "Einkauf", "Haushalt"])
        #expect(data.defaultCalendarID == "orbit-fake-cal-privat" && data.defaultListID == "orbit-fake-list-erinnerungen")
        #expect(data.eventCount == 15 && data.reminderCount == 8)
        #expect(data.access(to: .events) == .fullAccess && data.access(to: .reminders) == .fullAccess)
        let state = data.stateSummary()
        #expect(state["events"] == 15 && state["reminders"] == 8)
        #expect(state["createdEvents"] == .array([]) && state["shownEvents"] == .array([]))
    }

    /// "Was habe ich morgen?" on the fixtures: the acceptance flow of the end-to-end run.
    @Test func tomorrowHasTheEventsTheFixturesPromise() async throws {
        let (data, _) = Self.data()
        let result = try await ListEventsTool(context: Self.context(data))
            .run(arguments: ToolArguments(["from": "2026-10-05", "to": "2026-10-05"]))
        guard case .events(let items) = result.card else {
            Issue.record("an event card")
            return
        }
        #expect(items.map(\.title) == ["Herbstferien", "Geburtstag Lisa", "Zahnarzt", "Team-Meeting", "Mittagessen mit Max",
                                       "Kundentermin Beispiel GmbH", "Nachtzug nach Wien"])
        #expect(result.text.contains("1. Sun 2026-10-04 to Thu 2026-10-08, all day (5 days) | \"Herbstferien\" | calendar \"Familie\""))
        #expect(result.text.contains("4. Mon 2026-10-05 10:00 to 10:45 | \"Team-Meeting\" | location \"Raum 3.14\" | calendar \"Arbeit\" | repeats"))
        #expect(result.text.contains("| \"Mittagessen mit Max\" | location \"Kantine\" | calendar \"Arbeit\" | declined by the user"))
        #expect(result.text.contains("| \"Kundentermin Beispiel GmbH\" | calendar \"Arbeit\" | canceled"))
        #expect(result.text.contains("7. Mon 2026-10-05 22:40 to Tue 2026-10-06 06:50 | \"Nachtzug nach Wien\""))
        #expect(!result.text.contains("Spätschicht"), "it ends when tomorrow starts")
    }

    @Test func recurringEventsKeepTheirTimeOverTheClockChange() throws {
        let (data, _) = Self.data()
        let occurrences = try data.events(from: T.date("2026-09-01"), to: T.date("2026-12-31"), calendarIDs: ["orbit-fake-cal-arbeit"])
            .filter { $0.identifier == "orbit-fake-event-team" }
        #expect(occurrences.count == 8, "repeatCount")
        #expect(occurrences.first?.start == T.date("2026-09-28T10:00"))
        #expect(occurrences.contains { $0.start == T.date("2026-10-26T10:00") && $0.end == T.date("2026-10-26T10:45") },
                "10:00 in winter time too")
        #expect(occurrences.allSatisfy { $0.isRecurring })
        let tomorrow = try data.events(from: T.date("2026-10-05"), to: T.date("2026-10-06"), calendarIDs: nil)
        #expect(tomorrow.filter { $0.identifier == "orbit-fake-event-team" }.count == 1)
    }

    @Test func createdEventsAreRecordedAndFoundAfterwards() async throws {
        let (data, _) = Self.data()
        let tools = CalendarTools.all(context: Self.context(data))
        let create = try #require(tools.first { $0.name == "create_event" })
        let prepared = try await create.prepareForConfirmation(ToolArguments(["title": "Friseur", "start": "2026-10-06T15:00",
                                                                              "end": "2026-10-06T15:45", "location": "Hauptstraße 5"]))
        #expect(prepared["calendar"] == "Privat", "the default calendar")
        #expect(data.stateSummary()["createdEvents"] == .array([]), "checking creates nothing")
        _ = try await create.run(arguments: prepared)
        _ = try await create.run(arguments: ToolArguments(["title": "Urlaub", "start": "2026-10-12", "end": "2026-10-16",
                                                           "calendar": "Familie"]))
        #expect(data.stateSummary()["createdEvents"] == .array([
            ["id": "orbit-fake-event-c1", "title": "Friseur", "start": "2026-10-06T15:00:00+02:00",
             "end": "2026-10-06T15:45:00+02:00", "allDay": false, "calendar": "Privat", "location": "Hauptstraße 5"],
            ["id": "orbit-fake-event-c2", "title": "Urlaub", "start": "2026-10-12", "end": "2026-10-16", "allDay": true,
             "calendar": "Familie"],
        ]))
        let list = try await tools[0].run(arguments: ToolArguments(["from": "2026-10-06", "to": "2026-10-06"]))
        #expect(list.text.contains("| \"Friseur\" | location \"Hauptstraße 5\" | calendar \"Privat\""))
        await #expect(throws: ToolError.self) {
            try await create.prepareForConfirmation(ToolArguments(["title": "X", "start": "2026-10-06", "end": "2026-10-06",
                                                                   "calendar": "Feiertage"]))
        }
    }

    @Test func remindersOpenFirstAndCompletedOnlyFromTheLastMonth() async throws {
        let (data, _) = Self.data()
        let tools = ReminderTools.all(context: Self.context(data))
        let open = try await tools[0].run(arguments: ToolArguments())
        guard case .reminders(let items) = open.card else {
            Issue.record("a reminder card")
            return
        }
        #expect(items.map(\.title) == ["Rechnung Telekom bezahlen", "Milch kaufen", "Lisa anrufen", "Steuererklärung abgeben",
                                       "Fenster putzen", "Brot"])
        #expect(open.text.contains("1. \"Rechnung Telekom bezahlen\" | due Fri 2026-10-02 (no time) | overdue | list \"Erinnerungen\" | priority high"))
        #expect(open.text.contains("2. \"Milch kaufen\" | due Sun 2026-10-04 18:00 | overdue | list \"Einkauf\""))
        let all = try await tools[0].run(arguments: ToolArguments(["include_completed": true]))
        #expect(all.text.contains("\"Paket abholen\" | completed Sat 2026-10-03 17:30"))
        #expect(!all.text.contains("Altglas"), "completed 40 days ago")

        let created = try await tools[1].run(arguments: ToolArguments(["title": "Blumen gießen", "due": "2026-10-05T08:00",
                                                                       "list": "Haushalt"]))
        #expect(created.summary == "Created reminder “Blumen gießen”")
        #expect(data.stateSummary()["createdReminders"] == .array([
            ["id": "orbit-fake-reminder-c1", "title": "Blumen gießen", "dueHasTime": true, "list": "Haushalt",
             "due": "2026-10-05T08:00:00+02:00"],
        ]))
    }

    @Test func showingFromCardsIsOnlyRecorded() async throws {
        let (data, _) = Self.data()
        let opener = FakeCalendarAppOpener(data: data)
        try await opener.showEvent(identifier: "orbit-fake-event-zahnarzt")
        try await opener.showReminder(identifier: "orbit-fake-reminder-milch")
        try await opener.showEvent(identifier: nil)
        #expect(data.stateSummary()["shownEvents"] == ["orbit-fake-event-zahnarzt", ""])
        #expect(data.stateSummary()["shownReminders"] == ["orbit-fake-reminder-milch"])
    }

    @Test func accessComesFromTheFiles() async throws {
        let folder = try TemporaryFolder("fake-calendar")
        defer { folder.remove() }
        try folder.write("events.json", #"{"access": "writeOnly", "events": [{"title": "X", "start": "10:00", "end": "11:00"}]}"#)
        try folder.write("reminders.json", #"{"access": "notDetermined", "reminders": [{"title": "Y"}]}"#)
        let personal = FakePersonalData(directory: folder.path)
        #expect(personal.errors.isEmpty)
        let permissions = FakePermissionAccess(data: personal)
        #expect(permissions.status(of: .calendars) == .writeOnly)
        #expect(permissions.status(of: .reminders) == .notDetermined)
        let context = CalendarToolContext(store: FakeCalendarStore(data: personal.calendar), now: { T.now }, timeZone: T.berlin)
        await #expect(throws: ToolError.permissionDenied(.calendars)) {
            try await ListEventsTool(context: context).run(arguments: ToolArguments(["from": "2026-10-05", "to": "2026-10-05"]))
        }
        // The fake user agrees when asked, from a tool or from "Allow…".
        _ = try await ListRemindersTool(context: context).run(arguments: ToolArguments())
        #expect(await permissions.request(.calendars) == .writeOnly, "add only stays: only System Settings changes it")
        let state = personal.stateSummary()
        #expect(state["remindersAccess"] == "fullAccess" && state["calendarAccess"] == "writeOnly")
        #expect(state["calendarAccessRequests"] == ["reminders", "events"])
        #expect(state["permissionRequests"] == ["calendars"])
    }

    @Test func mistakesInTheFilesAreReported() throws {
        let folder = try TemporaryFolder("fake-calendar")
        defer { folder.remove() }
        try folder.write("events.json", #"{"access": "sometimes", "events": [{"title": "A", "start": "25:00"}, {"title": "B", "start": "10:00", "repeat": "hourly"}]}"#)
        try folder.write("reminders.json", "{ kaputt")
        let (data, errors) = Self.data(folder: folder.url)
        #expect(errors.count == 4)
        #expect(errors.contains("'sometimes' is no access (fullAccess, writeOnly, denied, notDetermined or restricted)."))
        #expect(errors.contains("'25:00' is not a time (\"HH:mm\" or ISO 8601)."))
        #expect(errors.contains("'hourly' is no repeat rule (daily, weekly, monthly or yearly)."))
        #expect(errors.contains { $0.hasPrefix("reminders.json could not be read") })
        #expect(data.eventCount == 1, "the event without a time is left out")
        #expect(data.lists.map(\.title) == ["Erinnerungen"], "an empty list to add to")
    }

    @Test func theToolsUseTheFakeDataEndToEnd() async throws {
        let services = AppServices.live(environment: [FakePersonalData.variable: FakePersonalDataTests.fixtures.path],
                                        orbitDataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("orbit-fake-data"))
        #expect(services.calendarStore is FakeCalendarStore)
        #expect(services.calendarApps is FakeCalendarAppOpener)
        let tools = AppEnvironment.makeTools(services: services)
        let list = try #require(tools.first { $0.name == "list_reminders" })
        #expect(try await list.run(arguments: ToolArguments(["list": "Einkauf"])).summary == "Found 2 reminders")
        let restricted = AppServices.live(environment: ["ORBIT_DEBUG_FILE_SCOPE": NSTemporaryDirectory()],
                                          orbitDataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("orbit-fake-data"))
        #expect(restricted.calendarStore is UnavailableCalendarStore, "a restricted session never reaches the calendars")
        #expect(restricted.calendarApps is DisabledCalendarAppOpener)
    }
}
#endif
