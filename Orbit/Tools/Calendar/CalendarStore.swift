import Foundation

/// What the user's calendars hold: events or reminders (EventKit's entity types).
enum CalendarEntity: String, Sendable, Hashable, CaseIterable {
    case events
    case reminders

    /// The macOS permission the entity needs.
    var permission: PermissionKind {
        switch self {
        case .events: .calendars
        case .reminders: .reminders
        }
    }

    /// What the names of its calendars (or lists) count as in the note on sent content.
    var namesDisclosure: ContentDisclosure.Kind {
        switch self {
        case .events: .calendarNames
        case .reminders: .reminderListNames
        }
    }
}

/// Whether Orbit may read and write the user's events or reminders.
enum CalendarAccess: Sendable, Hashable {
    case fullAccess
    /// Adding only, no reading (macOS 14 "Add Only"/"Add Only"): not
    /// enough for Orbit, whose tools read calendars to list and to choose one.
    case writeOnly
    /// The user has not decided yet.
    case notDetermined
    case denied
    /// A profile or Screen Time does not allow it.
    case restricted
    /// Not available in this session (a DEBUG session restricted with
    /// ORBIT_DEBUG_FILE_SCOPE but without fake personal data).
    case unavailable
}

/// A calendar (for events) or a list (for reminders) as the tools see it.
struct CalendarInfo: Sendable, Hashable {
    /// EventKit's calendarIdentifier.
    var identifier: String
    var title: String
    /// "#RRGGBB".
    var colorHex: String?
    /// The account it belongs to ("iCloud", "Google"), to tell calendars with
    /// the same title apart.
    var source: String?
    /// Events or reminders can be added (false for subscribed, holiday and
    /// birthday calendars).
    var allowsModifications: Bool

    init(identifier: String, title: String, colorHex: String? = nil, source: String? = nil, allowsModifications: Bool = true) {
        self.identifier = identifier
        self.title = title
        self.colorHex = colorHex
        self.source = source
        self.allowsModifications = allowsModifications
    }
}

/// One event (for a recurring event one occurrence) as the tools see it.
struct CalendarEvent: Sendable, Hashable {
    /// EventKit's eventIdentifier: the same for every occurrence of a
    /// recurring event (shows the event in Calendar).
    var identifier: String
    var title: String
    /// For all-day events the start of the first day (in the user's time zone).
    var start: Date
    /// For all-day events the start of the day after the last one, so
    /// `start..<end` covers exactly the event's days (see
    /// `CalendarDates.allDayRange`).
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var calendar: CalendarInfo
    /// An occurrence of a recurring event.
    var isRecurring: Bool = false
    /// The user declined the invitation (still listed, marked).
    var isDeclined: Bool = false
    /// The organizer canceled the event.
    var isCanceled: Bool = false
}

/// A new event, checked by `create_event`.
struct NewEvent: Sendable, Hashable {
    var title: String
    /// All-day: the start of the first day.
    var start: Date
    /// All-day: the start of the day after the last one (exclusive), like
    /// `CalendarEvent.end`.
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var calendarID: String
}

/// A reminder as the tools see it.
struct CalendarReminder: Sendable, Hashable {
    /// EventKit's calendarItemIdentifier (shows the reminder in Reminders).
    var identifier: String
    var title: String
    /// The due date; for a reminder without a time the start of its day.
    var due: Date?
    var dueHasTime: Bool
    var isCompleted: Bool
    var completionDate: Date?
    /// EventKit's priority: 0 none, 1 to 4 high, 5 medium, 6 to 9 low.
    var priority: Int = 0
    var notes: String?
    var list: CalendarInfo
}

/// When a new reminder is due.
struct ReminderDue: Sendable, Hashable {
    /// Without a time: the start of the day (in the context's time zone).
    var date: Date
    var hasTime: Bool
}

/// A new reminder, checked by `create_reminder`.
struct NewReminder: Sendable, Hashable {
    var title: String
    var due: ReminderDue?
    var listID: String
    /// The zone `due` was given in (the day of a reminder without a time).
    var timeZone: TimeZone
}

/// Why the calendar store could not do something.
enum CalendarStoreError: Error, Sendable, Hashable {
    /// Orbit has no full access (any more).
    case notAuthorized(CalendarEntity)
    /// No calendar or list with this identifier (deleted meanwhile).
    case calendarNotFound
    /// The calendar or list does not allow adding items.
    case readOnlyCalendar
    /// EventKit refused to save; `code` is its error code (no message: it may echo user content).
    case saveFailed(code: Int)
    /// Calendars cannot be used in this session (see `CalendarAccess.unavailable`).
    case unavailable
}

/// The user's calendars and reminders (EventKit) for the tools: one service
/// for both, because one EventKit store serves both. Live:
/// `LiveCalendarStore`; tests and the DEBUG fake-data mode use calendars in
/// memory. Reading the authorization never asks; `requestAccess` is only for
/// requests the user made (a tool call).
protocol CalendarStore: Sendable {
    /// The current authorization. Cheap; never asks the user.
    func access(to entity: CalendarEntity) -> CalendarAccess
    /// Asks macOS for full access when the user has not decided yet (the
    /// system prompt appears) and returns the access afterwards.
    func requestAccess(to entity: CalendarEntity) async -> CalendarAccess
    /// The calendars for events, or the lists for reminders.
    func calendars(for entity: CalendarEntity) async throws -> [CalendarInfo]
    /// Where new events or reminders go by default; nil when there is none.
    func defaultCalendar(for entity: CalendarEntity) async throws -> CalendarInfo?
    /// The events (every occurrence of recurring ones) that overlap
    /// `start..<end`, at least those; the tools filter precisely, in all
    /// calendars or only in `calendarIDs`.
    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) async throws -> [CalendarEvent]
    /// Saves a new event and returns it as stored.
    func createEvent(_ event: NewEvent) async throws -> CalendarEvent
    /// The open reminders of all lists or of `listIDs`, plus those completed
    /// since `completedSince` when it is given.
    func reminders(listIDs: Set<String>?, completedSince: Date?) async throws -> [CalendarReminder]
    /// Saves a new reminder and returns it as stored.
    func createReminder(_ reminder: NewReminder) async throws -> CalendarReminder
}

/// No calendars (a DEBUG session restricted with ORBIT_DEBUG_FILE_SCOPE but
/// without fake personal data must not reach the user's calendars; also the
/// default of `AppServices`).
struct UnavailableCalendarStore: CalendarStore {
    func access(to entity: CalendarEntity) -> CalendarAccess { .unavailable }
    func requestAccess(to entity: CalendarEntity) async -> CalendarAccess { .unavailable }
    func calendars(for entity: CalendarEntity) async throws -> [CalendarInfo] { throw CalendarStoreError.unavailable }
    func defaultCalendar(for entity: CalendarEntity) async throws -> CalendarInfo? { throw CalendarStoreError.unavailable }

    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) async throws -> [CalendarEvent] {
        throw CalendarStoreError.unavailable
    }

    func createEvent(_ event: NewEvent) async throws -> CalendarEvent { throw CalendarStoreError.unavailable }

    func reminders(listIDs: Set<String>?, completedSince: Date?) async throws -> [CalendarReminder] {
        throw CalendarStoreError.unavailable
    }

    func createReminder(_ reminder: NewReminder) async throws -> CalendarReminder { throw CalendarStoreError.unavailable }
}

// MARK: - Dates (pure)

/// Date arithmetic for events and reminders in one time zone, shared by the
/// live store, the fakes and the tools, so they agree on days (also on the
/// 23- and 25-hour days of daylight saving time).
struct CalendarDates: Sendable {
    let calendar: Calendar

    init(timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        self.calendar = calendar
    }

    var timeZone: TimeZone { calendar.timeZone }

    func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    /// The start of the day `days` days after the day of `date`.
    func day(_ days: Int, after date: Date) -> Date {
        let start = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86_400)
    }

    /// Whole days from the day of `from` to the day of `to` (0 on the same day).
    func days(from: Date, to: Date) -> Int {
        calendar.dateComponents([.day], from: startOfDay(from), to: startOfDay(to)).day ?? 0
    }

    /// The days an all-day event covers as `first day ..< day after the last`.
    /// EventKit reports an all-day event's end as the end of its last day
    /// (23:59:59), other sources as midnight after it, and an event saved
    /// with the end equal to the start has that day only; every form gives
    /// the same days here.
    func allDayRange(start: Date, end: Date) -> (start: Date, end: Date) {
        let first = startOfDay(start)
        let lastInstant = end > start ? end.addingTimeInterval(-1) : start
        let last = max(first, startOfDay(lastInstant))
        return (first, day(1, after: last))
    }

    /// Whether an event (`start..<end`, all-day events as `allDayRange`)
    /// lies in `rangeStart..<rangeEnd`, even partly. An event without a
    /// duration counts at its start. With `rangeEnd == rangeStart` (an
    /// instant), the events going on at that instant.
    static func overlaps(start: Date, end: Date, rangeStart: Date, rangeEnd: Date) -> Bool {
        if rangeEnd <= rangeStart {
            return start <= rangeStart && (end > rangeStart || start == rangeStart)
        }
        if end <= start {
            return start >= rangeStart && start < rangeEnd
        }
        return start < rangeEnd && end > rangeStart
    }

    /// Year, month and day of a reminder due without a time; year to minute
    /// (with this time zone) of one with a time: what Reminders stores.
    func dueComponents(_ due: ReminderDue) -> DateComponents {
        if due.hasTime {
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due.date)
            components.timeZone = calendar.timeZone
            return components
        }
        return calendar.dateComponents([.year, .month, .day], from: due.date)
    }

    /// The due date of stored components: a reminder without an hour is due
    /// at the start of its day in this time zone (floating), one with a time
    /// at that instant (in the components' own time zone when they have one).
    func dueDate(from components: DateComponents) -> (date: Date, hasTime: Bool)? {
        guard let year = components.year, let month = components.month, let day = components.day else { return nil }
        let hasTime = components.hour != nil
        var resolved = DateComponents(year: year, month: month, day: day,
                                      hour: hasTime ? components.hour : 0, minute: hasTime ? (components.minute ?? 0) : 0)
        resolved.second = 0
        var calendar = calendar
        if hasTime, let zone = components.timeZone {
            calendar.timeZone = zone
        }
        guard let date = calendar.date(from: resolved) else { return nil }
        return (date, hasTime)
    }
}
