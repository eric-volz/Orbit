import Foundation

/// `create_event`: creates an event in the user's calendar, only after the
/// user confirmed it on a card where title, start, end, location and notes
/// can still be edited. Before the card appears (and again after edits) the
/// event is checked and its calendar resolved, so the card shows exactly what
/// will be created and a call that cannot work never asks the user.
struct CreateEventTool: Tool {
    /// The longest event Orbit creates.
    static let maxDays = 14
    static let maxTitleCharacters = 500
    static let maxLocationCharacters = 500
    static let maxNotesCharacters = 10_000

    let context: CalendarToolContext

    let name = "create_event"
    var displayName: String { String(localized: "Create event") }
    var description: String {
        """
        Creates a new event in the user's calendar (Apple Calendar). The user first sees a confirmation card \
        where they can still change title, start, end, location and notes; the event is only created after \
        they confirm, so never say it exists unless the result confirms it. Use it when the user asks to add, \
        schedule, enter or block time for an appointment, meeting, trip or other event. Give start and end in \
        ISO 8601 in the user's time zone ("2026-10-06T10:00"); if the user names no end, choose a sensible \
        duration (e.g. one hour for an appointment). For an all-day event set all_day to true and give dates \
        only: start is the first day and end the last day (the same date for a one-day event). An event may \
        last at most \(Self.maxDays) days. Without 'calendar' it goes to the default calendar for new events; \
        name a calendar only when the user does. Not for reminders or to-dos without a duration (use \
        create_reminder), and it cannot change or delete existing events. The user can show the new event in \
        Calendar from the card.
        """
    }
    var inputSchema: JSONSchema {
        .object(properties: [
            "title": .string(description: "The event's title, e.g. \"Zahnarzt\"."),
            "start": .string(description: "Start: a date and time (\"2026-10-06T10:00\", the user's time zone unless it has an offset); for an all-day event the first day (\"2026-10-06\").",
                             format: .dateTime),
            "end": .string(description: "End: a date and time after the start; for an all-day event the last day (\"2026-10-06\" for a one-day event).",
                           format: .dateTime),
            "all_day": .boolean(description: "True for an all-day event (start and end are then days). Leave it out to decide by whether start and end have a time."),
            "location": .string(description: "Where it takes place, e.g. an address or a room. Optional."),
            "notes": .string(description: "Notes for the event, plain text. Optional."),
            "calendar": .string(description: "Name of the calendar (as Calendar shows it, e.g. \"Arbeit\"). Leave it out for the default calendar."),
        ], required: ["title", "start", "end"])
    }
    let riskLevel: ToolRiskLevel = .write
    let category: ToolCategory = .calendar
    var requiredPermissions: [PermissionKind] { [.calendars] }

    func statusText(for arguments: ToolArguments) -> String {
        String(localized: "Creating event…")
    }

    // MARK: Confirmation

    func prepareForConfirmation(_ arguments: ToolArguments) async throws -> ToolArguments {
        let dates = context.dates
        let draft = try Draft(arguments: arguments, dates: dates)
        try await context.ensureAccess(.events)
        let target = try await context.target(named: draft.calendarName, identifier: draft.calendarID, for: .events)
        return draft.arguments(calendarName: target.shownName, calendarID: target.calendar.identifier, dates: dates)
    }

    func confirmationRequest(for arguments: ToolArguments) -> ConfirmationRequest {
        let isAllDay = arguments["all_day"]?.boolValue == true
        return ConfirmationRequest(
            toolName: name,
            riskLevel: riskLevel,
            title: String(localized: "Create event"),
            message: isAllDay ? String(localized: "Orbit creates this all-day event in your calendar.")
                : String(localized: "Orbit creates this event in your calendar."),
            fields: [
                ConfirmationField(id: "title", label: String(localized: "Title"),
                                  value: CalendarText.singleLine(arguments["title"]?.stringValue ?? ""), kind: .text),
                ConfirmationField(id: "start", label: String(localized: "Start"),
                                  value: arguments.optionalString("start") ?? "", kind: .dateTime),
                ConfirmationField(id: "end", label: isAllDay ? String(localized: "Last day") : String(localized: "End"),
                                  value: arguments.optionalString("end") ?? "", kind: .dateTime),
                ConfirmationField(id: "location", label: String(localized: "Location"),
                                  value: arguments.optionalString("location") ?? "", kind: .text),
                ConfirmationField(id: "notes", label: String(localized: "Notes"),
                                  value: arguments["notes"]?.stringValue ?? "", kind: .multilineText),
                ConfirmationField(id: "calendar", label: String(localized: "Calendar"),
                                  value: arguments.optionalString("calendar") ?? String(localized: "Default calendar"),
                                  kind: .readOnly),
            ],
            confirmLabel: String(localized: "Create")
        )
    }

    // MARK: Run

    func run(arguments: ToolArguments) async throws -> ToolResult {
        let dates = context.dates
        // Checked again: the card may have been edited, and a run without a card checks too. The
        // calendar is the one the card named (its identifier), not a name resolved anew.
        let draft = try Draft(arguments: arguments, dates: dates)
        try await context.ensureAccess(.events)
        let target = try await context.target(named: draft.calendarName, identifier: draft.calendarID, for: .events)
        let event = NewEvent(title: draft.title, start: draft.start, end: draft.end, isAllDay: draft.isAllDay,
                             location: draft.location, notes: draft.notes, calendarID: target.calendar.identifier)
        let created = try await context.perform(.events) { try await context.store.createEvent(event) }
        let title = created.title.isEmpty ? draft.title : created.title
        let when = CalendarText.span(start: created.start, end: created.end, isAllDay: created.isAllDay, dates)
        let text = "Created the event \"\(CalendarText.inline(title, maxCharacters: 200))\" (\(when)) in the calendar \"\(CalendarText.inline(target.shownName, maxCharacters: 100))\". The user can show it in Calendar from the card."
        return ToolResult(
            text: text,
            card: .events([CalendarToolContext.item(created, calendarName: target.shownName, wasCreated: true)]),
            summary: String(format: String(localized: "Created event “%@”"), title),
            // The calendar's name (the model may not have named it: the default calendar).
            disclosure: ContentDisclosure(kind: .calendarNames, count: 1)
        )
    }

    // MARK: Checking

    /// The event the arguments describe, checked: a title, start before end,
    /// an all-day event as whole days (dates only), at most `maxDays` long.
    struct Draft: Sendable, Hashable {
        var title: String
        /// All-day: the start of the first day.
        var start: Date
        /// All-day: the start of the day after the last one.
        var end: Date
        var isAllDay: Bool
        var location: String?
        var notes: String?
        var calendarName: String?
        /// The calendar the card named (`CalendarToolContext.targetKey`).
        var calendarID: String?

        init(arguments: ToolArguments, dates: CalendarDates) throws {
            title = try CalendarText.title(arguments, maxCharacters: CreateEventTool.maxTitleCharacters)
            let first = try CalendarText.date(try arguments.string("start"), parameter: "start", dates)
            let last = try CalendarText.date(try arguments.string("end"), parameter: "end", dates)
            let allDay: Bool
            if arguments.has("all_day") {
                allDay = try arguments.bool("all_day", default: false)
            } else if first.isDateOnly != last.isDateOnly {
                throw ToolError.invalidArgument("Give 'start' and 'end' both as dates (\"2026-10-06\") for an all-day event, or both with a time (\"2026-10-06T10:00\").")
            } else {
                allDay = first.isDateOnly
            }
            isAllDay = allDay
            if allDay {
                let firstDay = dates.startOfDay(first.date)
                let lastDay = dates.startOfDay(last.date)
                guard lastDay >= firstDay else {
                    throw ToolError.invalidArgument("'end' (\(CalendarText.day(lastDay, dates))) is before 'start' (\(CalendarText.day(firstDay, dates))). For an all-day event 'end' is the last day: the same date as 'start' for a one-day event.")
                }
                let days = dates.days(from: firstDay, to: lastDay) + 1
                guard days <= CreateEventTool.maxDays else {
                    throw ToolError.invalidArgument("An event may last at most \(CreateEventTool.maxDays) days; this one would last \(days) days. Ask the user, or create shorter events.")
                }
                start = firstDay
                end = dates.day(1, after: lastDay)
            } else {
                guard !first.isDateOnly, !last.isDateOnly else {
                    throw ToolError.invalidArgument("Give 'start' and 'end' with a time (\"2026-10-06T10:00\"), or set all_day to true for an all-day event.")
                }
                guard last.date > first.date else {
                    throw ToolError.invalidArgument("'end' (\(CalendarText.dayTime(last.date, dates))) must be after 'start' (\(CalendarText.dayTime(first.date, dates))).")
                }
                let latest = dates.calendar.date(byAdding: .day, value: CreateEventTool.maxDays, to: first.date)
                    ?? first.date.addingTimeInterval(Double(CreateEventTool.maxDays) * 86_400)
                guard last.date <= latest else {
                    throw ToolError.invalidArgument("An event may last at most \(CreateEventTool.maxDays) days. Ask the user, or create shorter events.")
                }
                start = first.date
                end = last.date
            }
            location = try Self.optionalText(arguments, "location", maxCharacters: CreateEventTool.maxLocationCharacters,
                                             singleLine: true)
            notes = try Self.optionalText(arguments, "notes", maxCharacters: CreateEventTool.maxNotesCharacters,
                                          singleLine: false)
            calendarName = arguments.optionalString("calendar").map(NoteText.singleLine).flatMap { $0.isEmpty ? nil : $0 }
            calendarID = arguments.optionalString(CalendarToolContext.targetKey)
        }

        /// The arguments as the card shows them: dates only for an all-day
        /// event (the end as its last day), otherwise with time and offset,
        /// and the calendar's identifier, tool-private.
        func arguments(calendarName: String, calendarID: String, dates: CalendarDates) -> ToolArguments {
            var values: [String: JSONValue] = [
                "title": .string(title),
                "start": .string(CalendarText.argument(start, dateOnly: isAllDay, dates)),
                "end": .string(CalendarText.argument(isAllDay ? dates.day(-1, after: end) : end, dateOnly: isAllDay, dates)),
                "all_day": .bool(isAllDay),
                "calendar": .string(calendarName),
                CalendarToolContext.targetKey: .string(calendarID),
            ]
            if let location { values["location"] = .string(location) }
            if let notes { values["notes"] = .string(notes) }
            return ToolArguments(values)
        }

        private static func optionalText(_ arguments: ToolArguments, _ key: String, maxCharacters: Int,
                                         singleLine: Bool) throws -> String? {
            guard let raw = arguments[key]?.stringValue else { return nil }
            let text = singleLine ? CalendarText.singleLine(raw)
                : NoteText.cleaned(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard text.count <= maxCharacters else {
                throw ToolError.invalidArgument("'\(key)' may have at most \(maxCharacters) characters.")
            }
            return text
        }
    }
}
