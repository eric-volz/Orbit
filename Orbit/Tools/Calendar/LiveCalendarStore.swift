import AppKit
import EventKit
import Foundation
import os

/// The user's calendars and reminders through EventKit, the only place
/// Orbit touches EventKit's data.
///
/// One shared `EKEventStore` serves events and reminders. It is created on
/// first use and only once Orbit has full access (so it never caches an
/// unauthorized state), and it is reset before the next use after EventKit
/// reported a change (`EKEventStoreChanged`: other apps, sync, a changed
/// permission), after Orbit asked for access and when full access is back
/// after it was missing. Every EventKit call runs on one
/// serial queue (never on the main thread), and EventKit's objects never
/// leave EventKit's threads: they become value types there. Asking for access
/// (the system prompt) happens only in `requestAccess`, i.e. for a request the
/// user made. Nothing about events or reminders is logged except counts and
/// durations.
final class LiveCalendarStore: CalendarStore, @unchecked Sendable {
    // @unchecked: `store` is only read and written on `queue` (a serial
    // queue); `isStale` and `withoutAccess` have their own locks, because
    // EventKit's change notification and the access reads arrive on any thread.
    private let queue = DispatchQueue(label: "io.github.eric-volz.Orbit.calendar-store", qos: .userInitiated)
    private var store: EKEventStore?
    private let isStale = OSAllocatedUnfairLock(initialState: false)
    /// Entities last read without full access: when it is back, the store is reset.
    private let withoutAccess = OSAllocatedUnfairLock(initialState: Set<CalendarEntity>())
    /// Notes longer than this are cut when they are read (the tools show far less).
    static let maxNotesCharacters = 2_000
    /// Titles and locations longer than this are cut when they are read.
    static let maxTextCharacters = 1_000

    init() {}

    // MARK: Access

    func access(to entity: CalendarEntity) -> CalendarAccess {
        let access = Self.access(EKEventStore.authorizationStatus(for: Self.entityType(entity)))
        let regained = withoutAccess.withLock { entities -> Bool in
            if access == .fullAccess { return entities.remove(entity) != nil }
            entities.insert(entity)
            return false
        }
        if regained {
            // A store made while it was missing may still answer as without access.
            isStale.withLock { $0 = true }
        }
        return access
    }

    func requestAccess(to entity: CalendarEntity) async -> CalendarAccess {
        guard access(to: entity) == .notDetermined else { return access(to: entity) }
        Log.permissions.info("Asking for full access to \(entity.rawValue, privacy: .public)")
        do {
            // A store of its own for asking: the shared one is created only once access is granted.
            let asking = EKEventStore()
            switch entity {
            case .events: _ = try await asking.requestFullAccessToEvents()
            case .reminders: _ = try await asking.requestFullAccessToReminders()
            }
        } catch {
            Log.permissions.error("Asking for \(entity.rawValue, privacy: .public) failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        // A store created before may still have the old state.
        isStale.withLock { $0 = true }
        return access(to: entity)
    }

    // MARK: Reading

    func calendars(for entity: CalendarEntity) async throws -> [CalendarInfo] {
        try await perform(entity) { store in
            store.calendars(for: Self.entityType(entity)).map(Self.info)
        }
    }

    func defaultCalendar(for entity: CalendarEntity) async throws -> CalendarInfo? {
        try await perform(entity) { store in
            let calendar = switch entity {
            case .events: store.defaultCalendarForNewEvents
            case .reminders: store.defaultCalendarForNewReminders()
            }
            return calendar.map(Self.info)
        }
    }

    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) async throws -> [CalendarEvent] {
        let begin = ContinuousClock.now
        let events = try await perform(.events) { store in
            let calendars = Self.calendars(calendarIDs, of: .event, in: store)
            if calendars?.isEmpty == true { return [CalendarEvent]() }
            // EventKit expands recurring events into their occurrences and
            // returns everything that overlaps the range (never an empty range).
            let predicate = store.predicateForEvents(withStart: start, end: max(end, start.addingTimeInterval(1)),
                                                     calendars: calendars)
            let dates = CalendarDates(timeZone: .autoupdatingCurrent)
            return store.events(matching: predicate).map { Self.event($0, dates: dates) }
        }
        Log.tools.info("Calendar: \(events.count) events read in \(Self.milliseconds(since: begin)) ms")
        return events
    }

    func reminders(listIDs: Set<String>?, completedSince: Date?) async throws -> [CalendarReminder] {
        let begin = ContinuousClock.now
        var reminders = try await fetchReminders(in: listIDs) { store, lists in
            store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists)
        }
        if let completedSince {
            let now = Date()
            reminders += try await fetchReminders(in: listIDs) { store, lists in
                store.predicateForCompletedReminders(withCompletionDateStarting: completedSince, ending: now, calendars: lists)
            }
        }
        Log.tools.info("Reminders: \(reminders.count) read in \(Self.milliseconds(since: begin)) ms")
        return reminders
    }

    /// Reminders arrive asynchronously, on EventKit's queue; they become value
    /// types there. Cancelling the tool call cancels the fetch and ends the
    /// wait at once (`ReminderFetch` resumes exactly once).
    private func fetchReminders(in listIDs: Set<String>?,
                                predicate: @escaping @Sendable (EKEventStore, [EKCalendar]?) -> NSPredicate) async throws -> [CalendarReminder] {
        try Task.checkCancellation()
        guard access(to: .reminders) == .fullAccess else { throw CalendarStoreError.notAuthorized(.reminders) }
        let dates = CalendarDates(timeZone: .autoupdatingCurrent)
        let fetch = ReminderFetch()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CalendarReminder], any Error>) in
                fetch.install(continuation)
                queue.async {
                    guard !fetch.isFinished else { return }
                    let store = self.sharedStore()
                    let lists = Self.calendars(listIDs, of: .reminder, in: store)
                    if lists?.isEmpty == true {
                        fetch.finish(.success([]))
                        return
                    }
                    let request = store.fetchReminders(matching: predicate(store, lists)) { reminders in
                        fetch.finish(.success((reminders ?? []).map { Self.reminder($0, dates: dates) }))
                    }
                    fetch.started(request, in: store)
                }
            }
        } onCancel: {
            fetch.cancel()
        }
    }

    // MARK: Writing

    func createEvent(_ event: NewEvent) async throws -> CalendarEvent {
        try await perform(.events) { store in
            guard let calendar = store.calendar(withIdentifier: event.calendarID) else {
                throw CalendarStoreError.calendarNotFound
            }
            guard calendar.allowsContentModifications else { throw CalendarStoreError.readOnlyCalendar }
            let new = EKEvent(eventStore: store)
            new.title = event.title
            new.isAllDay = event.isAllDay
            new.startDate = event.start
            // All-day: the end of the last day, as EventKit itself reports it
            // (midnight after the last day could add a day).
            new.endDate = event.isAllDay ? max(event.start, event.end.addingTimeInterval(-1)) : event.end
            new.location = event.location
            new.notes = event.notes
            new.calendar = calendar
            do {
                try store.save(new, span: .thisEvent, commit: true)
            } catch {
                throw CalendarStoreError.saveFailed(code: (error as NSError).code)
            }
            Log.tools.info("Calendar: an event was created")
            return Self.event(new, dates: CalendarDates(timeZone: .autoupdatingCurrent))
        }
    }

    func createReminder(_ reminder: NewReminder) async throws -> CalendarReminder {
        try await perform(.reminders) { store in
            guard let list = store.calendar(withIdentifier: reminder.listID) else {
                throw CalendarStoreError.calendarNotFound
            }
            guard list.allowsContentModifications else { throw CalendarStoreError.readOnlyCalendar }
            let new = EKReminder(eventStore: store)
            new.title = reminder.title
            new.calendar = list
            if let due = reminder.due {
                new.dueDateComponents = CalendarDates(timeZone: reminder.timeZone).dueComponents(due)
                if due.hasTime {
                    // Like Reminders itself: a reminder with a time alerts then.
                    new.addAlarm(EKAlarm(absoluteDate: due.date))
                }
            }
            do {
                try store.save(new, commit: true)
            } catch {
                throw CalendarStoreError.saveFailed(code: (error as NSError).code)
            }
            Log.tools.info("Reminders: a reminder was created")
            return Self.reminder(new, dates: CalendarDates(timeZone: reminder.timeZone))
        }
    }

    // MARK: The shared store

    /// Runs `work` on the queue with the shared store, after checking that
    /// Orbit has full access to `entity`.
    private func perform<T: Sendable>(_ entity: CalendarEntity,
                                      _ work: @escaping @Sendable (EKEventStore) throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard access(to: entity) == .fullAccess else { throw CalendarStoreError.notAuthorized(entity) }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try work(self.sharedStore()) })
            }
        }
    }

    /// The shared store (on `queue` only): created on first use, reset after a change.
    private func sharedStore() -> EKEventStore {
        if let store {
            if isStale.withLock({ stale in
                defer { stale = false }
                return stale
            }) {
                store.reset()
            }
            return store
        }
        let created = EKEventStore()
        _ = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: created, queue: nil) { [weak self] _ in
            self?.isStale.withLock { $0 = true }
        }
        isStale.withLock { $0 = false }
        store = created
        Log.tools.info("Calendar: the event store was created")
        return created
    }

    // MARK: Conversion (on EventKit's threads)

    private static func calendars(_ identifiers: Set<String>?, of type: EKEntityType, in store: EKEventStore) -> [EKCalendar]? {
        guard let identifiers else { return nil }
        return store.calendars(for: type).filter { identifiers.contains($0.calendarIdentifier) }
    }

    private static func info(_ calendar: EKCalendar) -> CalendarInfo {
        let account = calendar.source?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarInfo(identifier: calendar.calendarIdentifier, title: calendar.title,
                            colorHex: CalendarColor.hex(calendar.color), source: account?.isEmpty == false ? account : nil,
                            allowsModifications: calendar.allowsContentModifications)
    }

    private static func event(_ event: EKEvent, dates: CalendarDates) -> CalendarEvent {
        let start: Date = event.startDate ?? Date.distantPast
        let end: Date = event.endDate ?? start
        let range = event.isAllDay ? dates.allDayRange(start: start, end: end) : (start: start, end: max(start, end))
        let me = event.attendees?.first { $0.isCurrentUser }
        return CalendarEvent(
            identifier: event.eventIdentifier ?? event.calendarItemIdentifier, title: text(event.title) ?? "",
            start: range.start, end: range.end, isAllDay: event.isAllDay, location: text(event.location),
            notes: notes(event.notes), calendar: event.calendar.map(info) ?? CalendarInfo(identifier: "", title: ""),
            isRecurring: event.hasRecurrenceRules || event.isDetached, isDeclined: me?.participantStatus == .declined,
            isCanceled: event.status == .canceled
        )
    }

    private static func reminder(_ reminder: EKReminder, dates: CalendarDates) -> CalendarReminder {
        let due = reminder.dueDateComponents.flatMap(dates.dueDate(from:))
        return CalendarReminder(
            identifier: reminder.calendarItemIdentifier, title: text(reminder.title) ?? "", due: due?.date,
            dueHasTime: due?.hasTime ?? false, isCompleted: reminder.isCompleted, completionDate: reminder.completionDate,
            priority: reminder.priority, notes: notes(reminder.notes),
            list: reminder.calendar.map(info) ?? CalendarInfo(identifier: "", title: "")
        )
    }

    private static func text(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return Truncation.prefix(value, maxCharacters: maxTextCharacters)
    }

    private static func notes(_ value: String?) -> String? {
        guard let value, value.contains(where: { !$0.isWhitespace }) else { return nil }
        return Truncation.prefix(value, maxCharacters: maxNotesCharacters)
    }

    private static func entityType(_ entity: CalendarEntity) -> EKEntityType {
        switch entity {
        case .events: .event
        case .reminders: .reminder
        }
    }

    /// EventKit's authorization as Orbit sees it (pure).
    static func access(_ status: EKAuthorizationStatus) -> CalendarAccess {
        switch status {
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }
}

/// A running reminder fetch: resumes its caller exactly once, with the
/// reminders, or with `CancellationError` when the tool call was cancelled
/// (EventKit's request is cancelled too and may never answer).
/// @unchecked: its state is behind the lock; the store is only used to
/// cancel the request, which EventKit allows from any thread.
private final class ReminderFetch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[CalendarReminder], any Error>?
    private var request: Any?
    private var store: EKEventStore?
    private var finished = false

    var isFinished: Bool { lock.withLock { finished } }

    func install(_ continuation: CheckedContinuation<[CalendarReminder], any Error>) {
        let cancelled = lock.withLock { () -> Bool in
            self.continuation = continuation
            return finished
        }
        // Cancelled before the continuation existed.
        if cancelled { continuation.resume(throwing: CancellationError()) }
    }

    func started(_ request: Any, in store: EKEventStore) {
        let cancelNow = lock.withLock { () -> Bool in
            self.request = request
            self.store = store
            return finished
        }
        if cancelNow { store.cancelFetchRequest(request) }
    }

    /// The first result wins; later ones are dropped.
    func finish(_ result: Result<[CalendarReminder], any Error>) {
        let waiting = lock.withLock { () -> CheckedContinuation<[CalendarReminder], any Error>? in
            guard !finished else { return nil }
            finished = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    func cancel() {
        let pending = lock.withLock { () -> (request: Any, store: EKEventStore)? in
            guard let request, let store else { return nil }
            return (request, store)
        }
        if let pending { pending.store.cancelFetchRequest(pending.request) }
        finish(.failure(CancellationError()))
    }
}

/// Calendar colors as "#RRGGBB".
enum CalendarColor {
    static func hex(_ color: NSColor?) -> String? {
        guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
        return hex(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent)
    }

    /// "#RRGGBB" for components between 0 and 1 (clamped).
    static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}
