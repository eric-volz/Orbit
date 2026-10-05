#if DEBUG
import Foundation
import os

/// DEBUG only: invented events and reminders for the fake-data mode
/// (`FakePersonalData`, ORBIT_DEBUG_FAKE_PERSONAL_DATA). `FakeCalendarStore`
/// answers the calendar and reminder tools from `events.json` and
/// `reminders.json` like EventKit would (recurring events expanded,
/// overlapping events found, nothing without access); EventKit is never
/// touched. Created events and reminders are added (a later list finds them)
/// and recorded, and what cards would show in Calendar or Reminders is only
/// recorded (`FakeCalendarAppOpener`); `orbitctl state` reports both.
///
/// Dates are relative to the launch day, so "tomorrow" always has events:
/// `day` (0 = today, 1 = tomorrow, -1 = yesterday) and local times "HH:mm"
/// in the current time zone, or an ISO 8601 date-time in `start`/`end`.
///
/// `events.json` (every key optional):
/// `{"access": "fullAccess" | "writeOnly" | "denied" | "notDetermined" | "restricted",
///   "defaultCalendar": "Privat",
///   "calendars": [{"id": "…", "title": "Privat", "color": "#1BADF8", "account": "iCloud", "readOnly": false}],
///   "events": [{"id": "…", "title": "Zahnarzt", "calendar": "Privat", "day": 1, "start": "08:30", "end": "09:15",
///     "endDay": 1, "allDay": false, "days": 1, "location": "…", "notes": "…", "declined": false, "canceled": false,
///     "repeat": "daily" | "weekly" | "monthly" | "yearly", "repeatCount": 10, "repeatUntilDay": 30}]}`
/// An all-day event has `"allDay": true` and lasts `days` days; a timed one
/// ends on `endDay` (default `day`). Unknown calendar titles become calendars.
/// `calendar` and `defaultCalendar` (`list` and `defaultList` likewise) name a
/// calendar by its `id` or its title: by the id for calendars that share a
/// title (a calendar shared with the user can have the title of their own).
///
/// `reminders.json` (every key optional):
/// `{"access": "fullAccess" | …, "defaultList": "Erinnerungen",
///   "lists": [{"id": "…", "title": "Einkauf", "color": "#FF9500", "account": "iCloud", "readOnly": false}],
///   "reminders": [{"id": "…", "title": "Milch kaufen", "list": "Einkauf", "dueDay": 0, "dueTime": "18:00",
///     "priority": 1, "notes": "…", "completed": false, "completedDay": -1, "completedTime": "17:30"}]}`
/// Without `dueTime` a reminder is due on its day without a time.
final class FakeCalendarData: Sendable {
    static let eventsFile = "events.json"
    static let remindersFile = "reminders.json"
    /// Occurrences of one recurring event looked at per query at most.
    static let maxOccurrences = 5_000

    /// A stored event; a recurring one stands for all its occurrences.
    struct Event: Sendable, Hashable {
        var identifier: String
        var title: String
        var start: Date
        /// All-day: the start of the day after the last one.
        var end: Date
        var isAllDay: Bool
        var location: String?
        var notes: String?
        var calendarID: String
        var isDeclined = false
        var isCanceled = false
        var recurrence: Recurrence?
    }

    struct Recurrence: Sendable, Hashable {
        var unit: Calendar.Component
        /// Occurrences in all, the first included; nil = no end.
        var count: Int?
        /// The last day an occurrence may start on.
        var until: Date?
    }

    private struct State: Sendable {
        var events: [Event]
        var reminders: [CalendarReminder]
        var eventAccess: CalendarAccess
        var reminderAccess: CalendarAccess
        var accessRequests: [String] = []
        var createdEvents: [String] = []
        var createdReminders: [String] = []
        var shownEvents: [String] = []
        var shownReminders: [String] = []
        var nextNumber = 1
    }

    let calendars: [CalendarInfo]
    let lists: [CalendarInfo]
    let defaultCalendarID: String?
    let defaultListID: String?
    let dates: CalendarDates
    /// Events and reminders in the files (created ones not counted).
    let eventCount: Int
    let reminderCount: Int
    private let state: OSAllocatedUnfairLock<State>

    init(folder: URL?, now launch: Date, timeZone: TimeZone = .current, errors: inout [String]) {
        let dates = CalendarDates(timeZone: timeZone)
        self.dates = dates
        let today = dates.startOfDay(launch)
        let eventsFile = folder.flatMap { Self.decode(EventsFile.self, $0.appendingPathComponent(Self.eventsFile), errors: &errors) }
            ?? EventsFile()
        let remindersFile = folder.flatMap { Self.decode(RemindersFile.self, $0.appendingPathComponent(Self.remindersFile), errors: &errors) }
            ?? RemindersFile()

        var calendars = (eventsFile.calendars ?? []).enumerated().map { index, entry in
            Self.info(entry, fallbackID: "orbit-fake-calendar-\(index + 1)")
        }
        var events: [Event] = []
        for (index, entry) in (eventsFile.events ?? []).enumerated() {
            let calendarName = entry.calendar ?? eventsFile.defaultCalendar ?? calendars.first?.title ?? "Kalender"
            let calendarID = Self.calendarID(named: calendarName, in: &calendars, prefix: "orbit-fake-calendar")
            if let event = Self.event(entry, number: index + 1, calendarID: calendarID, today: today, dates: dates,
                                      errors: &errors) {
                events.append(event)
            }
        }
        if calendars.isEmpty {
            calendars.append(CalendarInfo(identifier: "orbit-fake-calendar-1", title: eventsFile.defaultCalendar ?? "Kalender"))
        }
        defaultCalendarID = eventsFile.defaultCalendar.flatMap { Self.existingID(named: $0, in: calendars) }
            ?? calendars.first { $0.allowsModifications }?.identifier

        var lists = (remindersFile.lists ?? []).enumerated().map { index, entry in
            Self.info(entry, fallbackID: "orbit-fake-list-\(index + 1)")
        }
        var reminders: [CalendarReminder] = []
        for (index, entry) in (remindersFile.reminders ?? []).enumerated() {
            let listName = entry.list ?? remindersFile.defaultList ?? lists.first?.title ?? "Erinnerungen"
            let listID = Self.calendarID(named: listName, in: &lists, prefix: "orbit-fake-list")
            guard let list = lists.first(where: { $0.identifier == listID }) else { continue }
            reminders.append(Self.reminder(entry, number: index + 1, list: list, today: today, dates: dates, errors: &errors))
        }
        if lists.isEmpty {
            lists.append(CalendarInfo(identifier: "orbit-fake-list-1", title: remindersFile.defaultList ?? "Erinnerungen"))
        }
        defaultListID = remindersFile.defaultList.flatMap { Self.existingID(named: $0, in: lists) }
            ?? lists.first { $0.allowsModifications }?.identifier

        self.calendars = calendars
        self.lists = lists
        eventCount = events.count
        reminderCount = reminders.count
        state = OSAllocatedUnfairLock(initialState: State(
            events: events, reminders: reminders,
            eventAccess: Self.access(eventsFile.access, errors: &errors),
            reminderAccess: Self.access(remindersFile.access, errors: &errors)
        ))
    }

    // MARK: Access

    func access(to entity: CalendarEntity) -> CalendarAccess {
        state.withLock { entity == .events ? $0.eventAccess : $0.reminderAccess }
    }

    /// Asking for access: recorded; the fake user agrees when undecided (like a click on Allow).
    func requestAccess(to entity: CalendarEntity) -> CalendarAccess {
        state.withLock { state in
            state.accessRequests.append(entity.rawValue)
            switch entity {
            case .events:
                if state.eventAccess == .notDetermined { state.eventAccess = .fullAccess }
                return state.eventAccess
            case .reminders:
                if state.reminderAccess == .notDetermined { state.reminderAccess = .fullAccess }
                return state.reminderAccess
            }
        }
    }

    private func checkAccess(_ entity: CalendarEntity) throws {
        guard access(to: entity) == .fullAccess else { throw CalendarStoreError.notAuthorized(entity) }
    }

    // MARK: Events

    func calendars(for entity: CalendarEntity) throws -> [CalendarInfo] {
        try checkAccess(entity)
        return entity == .events ? calendars : lists
    }

    func defaultCalendar(for entity: CalendarEntity) throws -> CalendarInfo? {
        try checkAccess(entity)
        let id = entity == .events ? defaultCalendarID : defaultListID
        return (entity == .events ? calendars : lists).first { $0.identifier == id }
    }

    /// Like EventKit: every occurrence that overlaps the range.
    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) throws -> [CalendarEvent] {
        try checkAccess(.events)
        let stored = state.withLock { $0.events }
        let rangeEnd = max(end, start.addingTimeInterval(1))
        return stored.filter { calendarIDs?.contains($0.calendarID) ?? true }.flatMap { event in
            occurrences(of: event, from: start, to: rangeEnd)
        }
    }

    func createEvent(_ new: NewEvent) throws -> CalendarEvent {
        try checkAccess(.events)
        guard let calendar = calendars.first(where: { $0.identifier == new.calendarID }) else {
            throw CalendarStoreError.calendarNotFound
        }
        guard calendar.allowsModifications else { throw CalendarStoreError.readOnlyCalendar }
        let event = state.withLock { state -> Event in
            let event = Event(identifier: "orbit-fake-event-c\(state.nextNumber)", title: new.title, start: new.start,
                              end: new.end, isAllDay: new.isAllDay, location: new.location, notes: new.notes,
                              calendarID: calendar.identifier)
            state.nextNumber += 1
            state.events.append(event)
            state.createdEvents.append(event.identifier)
            return event
        }
        return occurrence(of: event, start: event.start, end: event.end)
    }

    private func occurrences(of event: Event, from start: Date, to end: Date) -> [CalendarEvent] {
        guard let recurrence = event.recurrence else {
            return CalendarDates.overlaps(start: event.start, end: event.end, rangeStart: start, rangeEnd: end)
                ? [occurrence(of: event, start: event.start, end: event.end)] : []
        }
        var found: [CalendarEvent] = []
        for index in 0..<min(recurrence.count ?? Self.maxOccurrences, Self.maxOccurrences) {
            // Wall-clock times stay the same across daylight saving time, like in Calendar.
            guard let first = dates.calendar.date(byAdding: recurrence.unit, value: index, to: event.start),
                  let last = dates.calendar.date(byAdding: recurrence.unit, value: index, to: event.end) else { break }
            if first >= end { break }
            if let until = recurrence.until, first >= dates.day(1, after: until) { break }
            if CalendarDates.overlaps(start: first, end: last, rangeStart: start, rangeEnd: end) {
                found.append(occurrence(of: event, start: first, end: last))
            }
        }
        return found
    }

    private func occurrence(of event: Event, start: Date, end: Date) -> CalendarEvent {
        CalendarEvent(identifier: event.identifier, title: event.title, start: start, end: end, isAllDay: event.isAllDay,
                      location: event.location, notes: event.notes,
                      calendar: calendars.first { $0.identifier == event.calendarID } ?? CalendarInfo(identifier: event.calendarID, title: ""),
                      isRecurring: event.recurrence != nil, isDeclined: event.isDeclined, isCanceled: event.isCanceled)
    }

    // MARK: Reminders

    func reminders(listIDs: Set<String>?, completedSince: Date?) throws -> [CalendarReminder] {
        try checkAccess(.reminders)
        return state.withLock { $0.reminders }.filter { reminder in
            guard listIDs?.contains(reminder.list.identifier) ?? true else { return false }
            guard reminder.isCompleted else { return true }
            guard let completedSince, let done = reminder.completionDate else { return false }
            return done >= completedSince
        }
    }

    func createReminder(_ new: NewReminder) throws -> CalendarReminder {
        try checkAccess(.reminders)
        guard let list = lists.first(where: { $0.identifier == new.listID }) else { throw CalendarStoreError.calendarNotFound }
        guard list.allowsModifications else { throw CalendarStoreError.readOnlyCalendar }
        return state.withLock { state -> CalendarReminder in
            let reminder = CalendarReminder(identifier: "orbit-fake-reminder-c\(state.nextNumber)", title: new.title,
                                            due: new.due?.date, dueHasTime: new.due?.hasTime ?? false, isCompleted: false,
                                            completionDate: nil, list: list)
            state.nextNumber += 1
            state.reminders.append(reminder)
            state.createdReminders.append(reminder.identifier)
            return reminder
        }
    }

    // MARK: Cards

    func recordShownEvent(_ identifier: String?) {
        state.withLock { $0.shownEvents.append(identifier ?? "") }
    }

    func recordShownReminder(_ identifier: String?) {
        state.withLock { $0.shownReminders.append(identifier ?? "") }
    }

    // MARK: State

    /// For `orbitctl state`: counts, access and what Orbit did.
    func stateSummary() -> [String: JSONValue] {
        let snapshot = state.withLock { $0 }
        let created = snapshot.createdEvents.compactMap { id in snapshot.events.first { $0.identifier == id } }
        let createdReminders = snapshot.createdReminders.compactMap { id in snapshot.reminders.first { $0.identifier == id } }
        return [
            "events": .number(Double(eventCount)),
            "reminders": .number(Double(reminderCount)),
            "calendarAccess": .string(Self.name(of: snapshot.eventAccess)),
            "remindersAccess": .string(Self.name(of: snapshot.reminderAccess)),
            "calendarAccessRequests": .array(snapshot.accessRequests.map(JSONValue.string)),
            "createdEvents": .array(created.map { event in
                var entry: [String: JSONValue] = [
                    "id": .string(event.identifier), "title": .string(event.title),
                    "start": .string(CalendarText.argument(event.start, dateOnly: event.isAllDay, dates)),
                    "end": .string(CalendarText.argument(event.isAllDay ? dates.day(-1, after: event.end) : event.end,
                                                         dateOnly: event.isAllDay, dates)),
                    "allDay": .bool(event.isAllDay),
                    // As the tools name it ("Sport (iCloud 2)" for one of two calendars with a title).
                    "calendar": .string(calendars.first { $0.identifier == event.calendarID }
                        .map { CalendarMatching.displayName(of: $0, among: calendars) } ?? ""),
                ]
                if let location = event.location { entry["location"] = .string(location) }
                if let notes = event.notes { entry["notes"] = .string(notes) }
                return .object(entry)
            }),
            "createdReminders": .array(createdReminders.map { reminder in
                var entry: [String: JSONValue] = [
                    "id": .string(reminder.identifier), "title": .string(reminder.title),
                    "dueHasTime": .bool(reminder.dueHasTime),
                    "list": .string(CalendarMatching.displayName(of: reminder.list, among: lists)),
                ]
                if let due = reminder.due {
                    entry["due"] = .string(CalendarText.argument(due, dateOnly: !reminder.dueHasTime, dates))
                }
                return .object(entry)
            }),
            "shownEvents": .array(snapshot.shownEvents.map(JSONValue.string)),
            "shownReminders": .array(snapshot.shownReminders.map(JSONValue.string)),
        ]
    }

    static func name(of access: CalendarAccess) -> String {
        switch access {
        case .fullAccess: "fullAccess"
        case .writeOnly: "writeOnly"
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .unavailable: "unavailable"
        }
    }

    // MARK: Files

    private struct CalendarEntry: Decodable {
        var id: String?
        var title: String
        var color: String?
        var account: String?
        var readOnly: Bool?
    }

    private struct EventsFile: Decodable {
        struct Entry: Decodable {
            var id: String?
            var title: String?
            var calendar: String?
            var day: Int?
            var start: String?
            var end: String?
            var endDay: Int?
            var allDay: Bool?
            var days: Int?
            var location: String?
            var notes: String?
            var declined: Bool?
            var canceled: Bool?
            var `repeat`: String?
            var repeatCount: Int?
            var repeatUntilDay: Int?
        }

        var access: String?
        var defaultCalendar: String?
        var calendars: [CalendarEntry]?
        var events: [Entry]?
    }

    private struct RemindersFile: Decodable {
        struct Entry: Decodable {
            var id: String?
            var title: String?
            var list: String?
            var dueDay: Int?
            var dueTime: String?
            var priority: Int?
            var notes: String?
            var completed: Bool?
            var completedDay: Int?
            var completedTime: String?
        }

        var access: String?
        var defaultList: String?
        var lists: [CalendarEntry]?
        var reminders: [Entry]?
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, _ url: URL, errors: inout [String]) -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        } catch {
            errors.append("\(url.lastPathComponent) could not be read: \(error)")
            return nil
        }
    }

    private static func info(_ entry: CalendarEntry, fallbackID: String) -> CalendarInfo {
        CalendarInfo(identifier: entry.id ?? fallbackID, title: entry.title, colorHex: entry.color, source: entry.account,
                     allowsModifications: !(entry.readOnly ?? false))
    }

    /// The calendar with this id or title; a new (writable) one with this
    /// title when there is none.
    private static func calendarID(named name: String, in calendars: inout [CalendarInfo], prefix: String) -> String {
        if let existing = existingID(named: name, in: calendars) { return existing }
        let created = CalendarInfo(identifier: "\(prefix)-\(calendars.count + 1)", title: name)
        calendars.append(created)
        return created.identifier
    }

    /// The calendar with this id, else the first one with this title.
    private static func existingID(named name: String, in calendars: [CalendarInfo]) -> String? {
        (calendars.first { $0.identifier == name } ?? calendars.first { $0.title == name })?.identifier
    }

    private static func event(_ entry: EventsFile.Entry, number: Int, calendarID: String, today: Date,
                              dates: CalendarDates, errors: inout [String]) -> Event? {
        let day = dates.day(entry.day ?? 0, after: today)
        let start: Date
        let end: Date
        let isAllDay = entry.allDay ?? false
        if isAllDay {
            start = day
            end = dates.day(max(1, entry.days ?? 1), after: day)
        } else {
            guard let first = time(entry.start, on: day, dates: dates, errors: &errors) else { return nil }
            let endDay = dates.day(entry.endDay ?? entry.day ?? 0, after: today)
            start = first
            // Without an end: one hour.
            end = entry.end == nil ? first.addingTimeInterval(3_600)
                : time(entry.end, on: endDay, dates: dates, errors: &errors) ?? first.addingTimeInterval(3_600)
        }
        var recurrence: Recurrence?
        if let rule = entry.repeat?.lowercased() {
            let units: [String: Calendar.Component] = ["daily": .day, "weekly": .weekOfYear, "monthly": .month, "yearly": .year]
            if let unit = units[rule] {
                recurrence = Recurrence(unit: unit, count: entry.repeatCount,
                                        until: entry.repeatUntilDay.map { dates.day($0, after: today) })
            } else {
                errors.append("'\(rule)' is no repeat rule (daily, weekly, monthly or yearly).")
            }
        }
        return Event(identifier: entry.id ?? "orbit-fake-event-\(number)", title: entry.title ?? "", start: start,
                     end: max(start, end), isAllDay: isAllDay, location: entry.location, notes: entry.notes,
                     calendarID: calendarID, isDeclined: entry.declined ?? false, isCanceled: entry.canceled ?? false,
                     recurrence: recurrence)
    }

    private static func reminder(_ entry: RemindersFile.Entry, number: Int, list: CalendarInfo, today: Date,
                                 dates: CalendarDates, errors: inout [String]) -> CalendarReminder {
        var due: Date?
        if let dueDay = entry.dueDay {
            let day = dates.day(dueDay, after: today)
            due = entry.dueTime == nil ? day : time(entry.dueTime, on: day, dates: dates, errors: &errors)
        }
        let isCompleted = entry.completed ?? false
        var completion: Date?
        if isCompleted {
            let day = dates.day(entry.completedDay ?? 0, after: today)
            completion = time(entry.completedTime ?? "12:00", on: day, dates: dates, errors: &errors)
        }
        return CalendarReminder(identifier: entry.id ?? "orbit-fake-reminder-\(number)", title: entry.title ?? "",
                                due: due, dueHasTime: due != nil && entry.dueTime != nil, isCompleted: isCompleted,
                                completionDate: completion, priority: entry.priority ?? 0, notes: entry.notes, list: list)
    }

    /// "HH:mm" on `day` (wall-clock, in the zone), or an ISO 8601 date-time.
    private static func time(_ text: String?, on day: Date, dates: CalendarDates, errors: inout [String]) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else {
            errors.append("An event or reminder needs a time (\"HH:mm\" or ISO 8601).")
            return nil
        }
        if text.count >= 10, let parsed = FlexibleDate.parse(text, timeZone: dates.timeZone) {
            return parsed.date
        }
        let parts = text.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour),
              (0...59).contains(minute),
              let date = dates.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else {
            errors.append("'\(text)' is not a time (\"HH:mm\" or ISO 8601).")
            return nil
        }
        return date
    }

    private static func access(_ text: String?, errors: inout [String]) -> CalendarAccess {
        switch text?.lowercased() {
        case nil, "fullaccess", "granted", "authorized": return .fullAccess
        case "writeonly": return .writeOnly
        case "denied": return .denied
        case "notdetermined": return .notDetermined
        case "restricted": return .restricted
        case let other?:
            errors.append("'\(other)' is no access (fullAccess, writeOnly, denied, notDetermined or restricted).")
            return .fullAccess
        }
    }
}

/// The invented events and reminders as the calendar store (DEBUG fake-data mode).
struct FakeCalendarStore: CalendarStore {
    let data: FakeCalendarData

    func access(to entity: CalendarEntity) -> CalendarAccess { data.access(to: entity) }
    func requestAccess(to entity: CalendarEntity) async -> CalendarAccess { data.requestAccess(to: entity) }
    func calendars(for entity: CalendarEntity) async throws -> [CalendarInfo] { try data.calendars(for: entity) }
    func defaultCalendar(for entity: CalendarEntity) async throws -> CalendarInfo? { try data.defaultCalendar(for: entity) }

    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) async throws -> [CalendarEvent] {
        try Task.checkCancellation()
        return try data.events(from: start, to: end, calendarIDs: calendarIDs)
    }

    func createEvent(_ event: NewEvent) async throws -> CalendarEvent { try data.createEvent(event) }

    func reminders(listIDs: Set<String>?, completedSince: Date?) async throws -> [CalendarReminder] {
        try Task.checkCancellation()
        return try data.reminders(listIDs: listIDs, completedSince: completedSince)
    }

    func createReminder(_ reminder: NewReminder) async throws -> CalendarReminder { try data.createReminder(reminder) }
}

/// Showing events and reminders from cards in the DEBUG fake-data mode:
/// recorded, Calendar and Reminders never open.
struct FakeCalendarAppOpener: CalendarAppOpening {
    let data: FakeCalendarData

    func showEvent(identifier: String?) async throws {
        data.recordShownEvent(identifier)
    }

    func showReminder(identifier: String?) async throws {
        data.recordShownReminder(identifier)
    }
}
#endif
