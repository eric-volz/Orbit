import Foundation
import os
@testable import Orbit

/// Calendars, events and reminders in memory (never EventKit). Answers like
/// the live store (events that overlap the range, open reminders plus those
/// completed since a date, nothing without full access) and records every
/// query, request and created item. Asking for access turns `.notDetermined`
/// into `grantOnRequest ? .fullAccess : .denied`.
final class MockCalendarStore: CalendarStore, Sendable {
    struct EventQuery: Sendable, Hashable {
        var start: Date
        var end: Date
        var calendarIDs: Set<String>?
    }

    struct ReminderQuery: Sendable, Hashable {
        var listIDs: Set<String>?
        var completedSince: Date?
    }

    private struct State: Sendable {
        var calendars: [CalendarInfo]
        var lists: [CalendarInfo]
        var defaultCalendarID: String?
        var defaultListID: String?
        var events: [CalendarEvent]
        var reminders: [CalendarReminder]
        var access: [CalendarEntity: CalendarAccess]
        var grantOnRequest: Bool
        var accessRequests: [CalendarEntity] = []
        var eventQueries: [EventQuery] = []
        var reminderQueries: [ReminderQuery] = []
        var createdEvents: [NewEvent] = []
        var createdReminders: [NewReminder] = []
        var failure: CalendarStoreError?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(calendars: [CalendarInfo] = CalendarTest.calendars, lists: [CalendarInfo] = CalendarTest.lists,
         defaultCalendarID: String? = CalendarTest.privat.identifier, defaultListID: String? = CalendarTest.erinnerungen.identifier,
         events: [CalendarEvent] = [], reminders: [CalendarReminder] = [],
         access: CalendarAccess = .fullAccess, reminderAccess: CalendarAccess? = nil, grantOnRequest: Bool = true) {
        state = OSAllocatedUnfairLock(initialState: State(
            calendars: calendars, lists: lists, defaultCalendarID: defaultCalendarID, defaultListID: defaultListID,
            events: events, reminders: reminders, access: [.events: access, .reminders: reminderAccess ?? access],
            grantOnRequest: grantOnRequest))
    }

    var accessRequests: [CalendarEntity] { state.withLock { $0.accessRequests } }
    var eventQueries: [EventQuery] { state.withLock { $0.eventQueries } }
    var reminderQueries: [ReminderQuery] { state.withLock { $0.reminderQueries } }
    var createdEvents: [NewEvent] { state.withLock { $0.createdEvents } }
    var createdReminders: [NewReminder] { state.withLock { $0.createdReminders } }

    func setAccess(_ access: CalendarAccess, for entity: CalendarEntity) {
        state.withLock { $0.access[entity] = access }
    }

    /// Every following call fails with `error`.
    func fail(with error: CalendarStoreError?) {
        state.withLock { $0.failure = error }
    }

    func setDefaultCalendar(_ identifier: String?) {
        state.withLock { $0.defaultCalendarID = identifier }
    }

    /// Replaces the calendars (e.g. one was deleted while a card waited).
    func setCalendars(_ calendars: [CalendarInfo]) {
        state.withLock { $0.calendars = calendars }
    }

    // MARK: CalendarStore

    func access(to entity: CalendarEntity) -> CalendarAccess {
        state.withLock { $0.access[entity] ?? .fullAccess }
    }

    func requestAccess(to entity: CalendarEntity) async -> CalendarAccess {
        state.withLock { state in
            state.accessRequests.append(entity)
            if state.access[entity] == .notDetermined {
                state.access[entity] = state.grantOnRequest ? .fullAccess : .denied
            }
            return state.access[entity] ?? .fullAccess
        }
    }

    func calendars(for entity: CalendarEntity) async throws -> [CalendarInfo] {
        try check(entity)
        return state.withLock { entity == .events ? $0.calendars : $0.lists }
    }

    func defaultCalendar(for entity: CalendarEntity) async throws -> CalendarInfo? {
        try check(entity)
        return state.withLock { state in
            let id = entity == .events ? state.defaultCalendarID : state.defaultListID
            return (entity == .events ? state.calendars : state.lists).first { $0.identifier == id }
        }
    }

    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) async throws -> [CalendarEvent] {
        try check(.events)
        return state.withLock { state in
            state.eventQueries.append(EventQuery(start: start, end: end, calendarIDs: calendarIDs))
            // Like EventKit: everything that overlaps (never an empty range).
            let rangeEnd = max(end, start.addingTimeInterval(1))
            return state.events.filter { event in
                (calendarIDs?.contains(event.calendar.identifier) ?? true)
                    && CalendarDates.overlaps(start: event.start, end: event.end, rangeStart: start, rangeEnd: rangeEnd)
            }
        }
    }

    func createEvent(_ event: NewEvent) async throws -> CalendarEvent {
        try check(.events)
        return try state.withLock { state in
            guard let calendar = state.calendars.first(where: { $0.identifier == event.calendarID }) else {
                throw CalendarStoreError.calendarNotFound
            }
            guard calendar.allowsModifications else { throw CalendarStoreError.readOnlyCalendar }
            state.createdEvents.append(event)
            let created = CalendarEvent(identifier: "created-\(state.createdEvents.count)", title: event.title,
                                        start: event.start, end: event.end, isAllDay: event.isAllDay,
                                        location: event.location, notes: event.notes, calendar: calendar)
            state.events.append(created)
            return created
        }
    }

    func reminders(listIDs: Set<String>?, completedSince: Date?) async throws -> [CalendarReminder] {
        try check(.reminders)
        return state.withLock { state in
            state.reminderQueries.append(ReminderQuery(listIDs: listIDs, completedSince: completedSince))
            return state.reminders.filter { reminder in
                guard listIDs?.contains(reminder.list.identifier) ?? true else { return false }
                guard reminder.isCompleted else { return true }
                guard let completedSince, let done = reminder.completionDate else { return false }
                return done >= completedSince
            }
        }
    }

    func createReminder(_ reminder: NewReminder) async throws -> CalendarReminder {
        try check(.reminders)
        return try state.withLock { state in
            guard let list = state.lists.first(where: { $0.identifier == reminder.listID }) else {
                throw CalendarStoreError.calendarNotFound
            }
            guard list.allowsModifications else { throw CalendarStoreError.readOnlyCalendar }
            state.createdReminders.append(reminder)
            let created = CalendarReminder(identifier: "created-reminder-\(state.createdReminders.count)", title: reminder.title,
                                           due: reminder.due?.date, dueHasTime: reminder.due?.hasTime ?? false,
                                           isCompleted: false, completionDate: nil, list: list)
            state.reminders.append(created)
            return created
        }
    }

    private func check(_ entity: CalendarEntity) throws {
        try state.withLock { state in
            if let failure = state.failure { throw failure }
            guard state.access[entity] ?? .fullAccess == .fullAccess else { throw CalendarStoreError.notAuthorized(entity) }
        }
    }
}

/// Records what event and reminder cards would show in Calendar or
/// Reminders; nothing opens. `failing` makes every call throw.
final class RecordingCalendarAppOpener: CalendarAppOpening, Sendable {
    struct Failure: Error {}

    private let state = OSAllocatedUnfairLock(initialState: (events: [String?](), reminders: [String?](), failing: false))

    var shownEvents: [String?] { state.withLock { $0.events } }
    var shownReminders: [String?] { state.withLock { $0.reminders } }

    func failEverything() {
        state.withLock { $0.failing = true }
    }

    func showEvent(identifier: String?) async throws {
        let failing = state.withLock { state in
            if !state.failing { state.events.append(identifier) }
            return state.failing
        }
        if failing { throw Failure() }
    }

    func showReminder(identifier: String?) async throws {
        let failing = state.withLock { state in
            if !state.failing { state.reminders.append(identifier) }
            return state.failing
        }
        if failing { throw Failure() }
    }
}

/// Invented calendars, lists, events and reminders for tests, in Berlin.
enum CalendarTest {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!
    static let dates = CalendarDates(timeZone: berlin)
    /// Sunday, 2026-10-04 20:00 in Berlin (CEST).
    static let now = FlexibleDate.parse("2026-10-04T20:00:00+02:00")!.date

    static let privat = CalendarInfo(identifier: "cal-privat", title: "Privat", colorHex: "#1BADF8", source: "iCloud")
    static let arbeit = CalendarInfo(identifier: "cal-arbeit", title: "Arbeit", colorHex: "#FF9500", source: "iCloud")
    static let arbeitGoogle = CalendarInfo(identifier: "cal-arbeit-google", title: "Arbeit", colorHex: "#0B8043", source: "Google")
    static let archiv = CalendarInfo(identifier: "cal-archiv", title: "Archiv", source: "iCloud")
    static let feiertage = CalendarInfo(identifier: "cal-feiertage", title: "Feiertage", colorHex: "#8E8E93",
                                        source: "Abonnements", allowsModifications: false)
    static let calendars = [privat, arbeit, feiertage]

    static let erinnerungen = CalendarInfo(identifier: "list-erinnerungen", title: "Erinnerungen", colorHex: "#1BADF8", source: "iCloud")
    static let einkauf = CalendarInfo(identifier: "list-einkauf", title: "Einkauf", colorHex: "#FF9500", source: "iCloud")
    static let geteilt = CalendarInfo(identifier: "list-geteilt", title: "Geteilt", source: "iCloud", allowsModifications: false)
    static let lists = [erinnerungen, einkauf, geteilt]

    /// A date in Berlin ("2026-10-05T10:00" or "2026-10-05").
    static func date(_ text: String) -> Date {
        FlexibleDate.parse(text, timeZone: berlin)!.date
    }

    static func event(_ id: String, _ title: String, _ start: String, _ end: String, allDay: Bool = false,
                      calendar: CalendarInfo = privat, location: String? = nil, notes: String? = nil,
                      recurring: Bool = false, declined: Bool = false, canceled: Bool = false) -> CalendarEvent {
        CalendarEvent(identifier: id, title: title, start: date(start), end: date(end), isAllDay: allDay, location: location,
                      notes: notes, calendar: calendar, isRecurring: recurring, isDeclined: declined, isCanceled: canceled)
    }

    static func reminder(_ id: String, _ title: String, due: String? = nil, list: CalendarInfo = erinnerungen,
                         completed: String? = nil, priority: Int = 0, notes: String? = nil) -> CalendarReminder {
        let parsed = due.flatMap { FlexibleDate.parse($0, timeZone: berlin) }
        return CalendarReminder(identifier: id, title: title, due: parsed?.date, dueHasTime: parsed.map { !$0.isDateOnly } ?? false,
                                isCompleted: completed != nil, completionDate: completed.map(date), priority: priority,
                                notes: notes, list: list)
    }

    static func context(_ store: MockCalendarStore, now: Date = now) -> CalendarToolContext {
        CalendarToolContext(store: store, now: { now }, timeZone: berlin)
    }

    static func tool<T: Tool>(_ type: T.Type, _ store: MockCalendarStore, now: Date = now) -> T {
        let tools = CalendarTools.all(context: context(store, now: now)) + ReminderTools.all(context: context(store, now: now))
        return tools.compactMap { $0 as? T }.first!
    }
}
