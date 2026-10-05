import Foundation

/// `create_reminder`: creates a reminder in Apple Reminders, only after the
/// user confirmed it on a card where title and due date can still be edited.
/// A due date without a time makes a reminder for that day; one with a time
/// alerts then. Checked and its list resolved before the card appears (and
/// again after edits).
struct CreateReminderTool: Tool {
    static let maxTitleCharacters = 500

    let context: CalendarToolContext

    let name = "create_reminder"
    var displayName: String { String(localized: "Create reminder") }
    let description = """
        Creates a new reminder in Apple Reminders. The user first sees a confirmation card where they can \
        still change the title and the due date; the reminder is only created after they confirm, so never say \
        it exists unless the result confirms it. Use it when the user asks to be reminded of something or to \
        put something on a to-do or shopping list ("Remind me tomorrow at 9 to call Lisa", "Put milk on my \
        shopping list"). 'due' is optional: a date and time ("2026-10-05T09:00", the user's time zone) gives a \
        reminder with that time, and Reminders alerts then; a date only ("2026-10-05") gives a reminder for \
        that day without a time; leave it out for no due date. Without 'list' it goes to the default list; \
        name a list only when the user does (e.g. "Einkauf" for a shopping list). Not for events with a start \
        and end (use create_event), and it cannot change, complete or delete existing reminders.
        """
    var inputSchema: JSONSchema {
        .object(properties: [
            "title": .string(description: "What to remember, e.g. \"Lisa anrufen\"."),
            "due": .string(description: "When it is due: a date and time (\"2026-10-05T09:00\") for a reminder with an alert, or a date (\"2026-10-05\") for that day without a time. Leave it out for no due date.",
                           format: .dateTime),
            "list": .string(description: "Name of the list (as Reminders shows it, e.g. \"Einkauf\"). Leave it out for the default list."),
        ], required: ["title"])
    }
    let riskLevel: ToolRiskLevel = .write
    let category: ToolCategory = .reminders
    var requiredPermissions: [PermissionKind] { [.reminders] }

    func statusText(for arguments: ToolArguments) -> String {
        String(localized: "Creating reminder…")
    }

    // MARK: Confirmation

    func prepareForConfirmation(_ arguments: ToolArguments) async throws -> ToolArguments {
        let dates = context.dates
        let draft = try Draft(arguments: arguments, dates: dates)
        try await context.ensureAccess(.reminders)
        let target = try await context.target(named: draft.listName, identifier: draft.listID, for: .reminders)
        return draft.arguments(listName: target.shownName, listID: target.calendar.identifier, dates: dates)
    }

    func confirmationRequest(for arguments: ToolArguments) -> ConfirmationRequest {
        ConfirmationRequest(
            toolName: name,
            riskLevel: riskLevel,
            title: String(localized: "Create reminder"),
            message: String(localized: "Orbit creates this reminder in Reminders. A date without a time covers the whole day."),
            fields: [
                ConfirmationField(id: "title", label: String(localized: "Title"),
                                  value: CalendarText.singleLine(arguments["title"]?.stringValue ?? ""), kind: .text),
                ConfirmationField(id: "due", label: String(localized: "Due"),
                                  value: arguments.optionalString("due") ?? "", kind: .dateTime, isOptionalDate: true),
                ConfirmationField(id: "list", label: String(localized: "List"),
                                  value: arguments.optionalString("list") ?? String(localized: "Default list"), kind: .readOnly),
            ],
            confirmLabel: String(localized: "Create")
        )
    }

    /// The card's edits; "Due" emptied on the card means no due date: the
    /// argument is left out rather than set to an empty date.
    func applyingEdits(_ edits: [String: String], to arguments: ToolArguments) -> ToolArguments {
        var result = arguments
        for (key, value) in edits where !ToolArguments.isPrivateKey(key) {
            if key == "due", value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.values["due"] = nil
            } else {
                result.values[key] = .string(value)
            }
        }
        return result
    }

    // MARK: Run

    func run(arguments: ToolArguments) async throws -> ToolResult {
        let dates = context.dates
        // The list is the one the card named (its identifier), not a name resolved anew.
        let draft = try Draft(arguments: arguments, dates: dates)
        try await context.ensureAccess(.reminders)
        let target = try await context.target(named: draft.listName, identifier: draft.listID, for: .reminders)
        let reminder = NewReminder(title: draft.title, due: draft.due, listID: target.calendar.identifier,
                                   timeZone: dates.timeZone)
        let created = try await context.perform(.reminders) { try await context.store.createReminder(reminder) }
        let title = created.title.isEmpty ? draft.title : created.title
        // As stored.
        let due: String
        if let date = created.due {
            due = created.dueHasTime ? "due \(CalendarText.dayTime(date, dates)) (Reminders alerts then)"
                : "due \(CalendarText.day(date, dates)) (no time)"
        } else {
            due = "without a due date"
        }
        let text = "Created the reminder \"\(CalendarText.inline(title, maxCharacters: 200))\", \(due), in the list \"\(CalendarText.inline(target.shownName, maxCharacters: 100))\". The user can show it in Reminders from the card."
        return ToolResult(
            text: text,
            card: .reminders([CalendarToolContext.item(created, listName: target.shownName, wasCreated: true)]),
            summary: String(format: String(localized: "Created reminder “%@”"), title),
            // The list's name (the model may not have named it: the default list).
            disclosure: ContentDisclosure(kind: .reminderListNames, count: 1)
        )
    }

    // MARK: Checking

    /// The reminder the arguments describe, checked.
    struct Draft: Sendable, Hashable {
        var title: String
        var due: ReminderDue?
        var listName: String?
        /// The list the card named (`CalendarToolContext.targetKey`).
        var listID: String?

        init(arguments: ToolArguments, dates: CalendarDates) throws {
            title = try CalendarText.title(arguments, maxCharacters: CreateReminderTool.maxTitleCharacters)
            if let text = arguments.optionalString("due") {
                let parsed = try CalendarText.date(text, parameter: "due", dates)
                due = ReminderDue(date: parsed.isDateOnly ? dates.startOfDay(parsed.date) : parsed.date,
                                  hasTime: !parsed.isDateOnly)
            } else {
                due = nil
            }
            listName = arguments.optionalString("list").map(NoteText.singleLine).flatMap { $0.isEmpty ? nil : $0 }
            listID = arguments.optionalString(CalendarToolContext.targetKey)
        }

        /// The arguments as the card shows them: the due date as a day or with
        /// time and offset, the list as it will be used, and its identifier,
        /// tool-private.
        func arguments(listName: String, listID: String, dates: CalendarDates) -> ToolArguments {
            var values: [String: JSONValue] = ["title": .string(title), "list": .string(listName),
                                               CalendarToolContext.targetKey: .string(listID)]
            if let due {
                values["due"] = .string(CalendarText.argument(due.date, dateOnly: !due.hasTime, dates))
            }
            return ToolArguments(values)
        }
    }
}
