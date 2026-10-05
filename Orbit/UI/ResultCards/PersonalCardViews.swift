import SwiftUI

// MARK: - Notes

/// Notes: title, excerpt, folder and date. A click opens the note in Notes
/// (when RootView provides `NoteCardActions`). Keyboard as on a file card
/// (`CardKeyboard`): ↑/↓ select a note, Return opens it, and VoiceOver hears
/// its title, folder and date.
struct NoteCardView: View {
    /// The chat item showing the card.
    let id: UUID
    let items: [NoteItem]
    @Environment(NoteCardActions.self) private var actions: NoteCardActions?
    @State private var selection: FileCardSelection
    @FocusState private var isFocused: Bool

    init(id: UUID = UUID(), items: [NoteItem]) {
        self.id = id
        self.items = items
        _selection = State(initialValue: FileCardSelection(count: items.count))
    }

    var body: some View {
        ResultCardContainer(title: Phrases.notes(items.count), systemImage: ToolCategory.notes.systemImage) {
            ForEach(Array(items.prefix(selection.visibleCount).enumerated()), id: \.offset) { index, item in
                NoteRow(item: item, isSelected: selection.index == index, isCardFocused: isFocused,
                        open: actions.map { actions in
                            {
                                selection.select(index)
                                actions.open(item)
                            }
                        })
                    .id(FileCardCoordinator.rowID(card: id, index: index))
            }
            CollapseToggle(selection: $selection)
        }
        .modifier(CardKeyboard(id: id, selection: $selection, isFocused: $isFocused,
                               announcement: { items.indices.contains($0) ? NoteCardFormat.announcement(for: items[$0]) : "" },
                               activate: open(at:)))
        .onChange(of: items.count) { _, count in selection.updateCount(count) }
    }

    /// Return on a row: the note opens in Notes.
    private func open(at index: Int) {
        guard let actions, items.indices.contains(index) else { return }
        actions.open(items[index])
    }
}

struct NoteRow: View {
    let item: NoteItem
    /// Selected by the keyboard (accent while the card has it, gray otherwise).
    var isSelected = false
    var isCardFocused = false
    /// Opens the note in Notes; nil = not clickable.
    var open: (() -> Void)?

    var body: some View {
        if let open {
            Button(action: open) {
                content
            }
            .buttonStyle(.plain)
            .rowHighlight(isSelected: isSelected, isFocused: isCardFocused)
            .help(Text("Open in Notes"))
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens the note in Notes"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            content
                .background(RowSelectionBackground(isSelected: isSelected, isFocused: isCardFocused))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: item.title.isEmpty ? String(localized: "New Note") : item.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if let excerpt = item.excerpt, !excerpt.isEmpty {
                Text(verbatim: excerpt)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            let meta = [item.folder, item.modified.map { CardDateFormatter.string(for: $0) }].compactMap { $0 }
            if !meta.isEmpty {
                Text(verbatim: meta.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// What VoiceOver hears when the keyboard selects a note.
enum NoteCardFormat {
    /// Title, folder and date.
    static func announcement(for item: NoteItem, now: Date = Date(), calendar: Calendar = .current,
                             locale: Locale = AppLanguage.locale) -> String {
        [
            item.title.isEmpty ? String(localized: "New Note") : item.title,
            item.folder,
            item.modified.map { CardDateFormatter.string(for: $0, now: now, calendar: calendar, locale: locale) },
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }
}

// MARK: - Events

/// Events: calendar color, title, time, location and calendar; declined and
/// canceled events are marked, recurring ones carry a symbol. A click (or
/// Return on the row the keyboard selected) shows the event in Calendar
/// (when RootView provides `CalendarCardActions`). A card with an event Orbit
/// created says so and offers "Show in Calendar". Keyboard as on a note card
/// (`CardKeyboard`): ↑/↓ select an event, and VoiceOver hears its title,
/// time, location, calendar and state.
struct EventCardView: View {
    /// The chat item showing the card.
    let id: UUID
    let items: [EventItem]
    @Environment(CalendarCardActions.self) private var actions: CalendarCardActions?
    @State private var selection: FileCardSelection
    @FocusState private var isFocused: Bool

    init(id: UUID = UUID(), items: [EventItem]) {
        self.id = id
        self.items = items
        _selection = State(initialValue: FileCardSelection(count: items.count))
    }

    var body: some View {
        ResultCardContainer(title: Phrases.events(items.count), systemImage: ToolCategory.calendar.systemImage) {
            ForEach(Array(items.prefix(selection.visibleCount).enumerated()), id: \.offset) { index, item in
                EventRow(item: item, isSelected: selection.index == index, isCardFocused: isFocused,
                         show: actions.map { actions in
                             {
                                 selection.select(index)
                                 actions.showEvent(item)
                             }
                         })
                    .id(FileCardCoordinator.rowID(card: id, index: index))
            }
            CollapseToggle(selection: $selection)
            if let created = items.first(where: { $0.wasCreated == true }) {
                CreatedItemFooter(status: String(localized: "Saved in Calendar"),
                                  buttonTitle: String(localized: "Show in Calendar"),
                                  hint: String(localized: "Shows the event in Calendar"),
                                  action: actions.map { actions in { actions.showEvent(created) } })
            }
        }
        .modifier(CardKeyboard(id: id, selection: $selection, isFocused: $isFocused,
                               announcement: { items.indices.contains($0) ? EventCardFormat.announcement(for: items[$0]) : "" },
                               activate: show(at:)))
        .onChange(of: items.count) { _, count in selection.updateCount(count) }
    }

    /// Return on a row: the event shows in Calendar.
    private func show(at index: Int) {
        guard let actions, items.indices.contains(index) else { return }
        actions.showEvent(items[index])
    }
}

struct EventRow: View {
    let item: EventItem
    /// Selected by the keyboard (accent while the card has it, gray otherwise).
    var isSelected = false
    var isCardFocused = false
    /// Shows the event in Calendar; nil = not clickable.
    var show: (() -> Void)?

    /// Declined or canceled: shown struck through, with the reason.
    private var state: String? { EventCardFormat.state(of: item) }

    var body: some View {
        if let show {
            Button(action: show) {
                content
            }
            .buttonStyle(.plain)
            .rowHighlight(isSelected: isSelected, isFocused: isCardFocused)
            .help(Text("Show in Calendar"))
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Shows the event in Calendar"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            content
                .background(RowSelectionBackground(isSelected: isSelected, isFocused: isCardFocused))
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Theme.color(hex: item.calendarColor) ?? .accentColor)
                .opacity(state == nil ? 1 : 0.45)
                .frame(width: 4)
                .padding(.vertical, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: item.title.isEmpty ? String(localized: "New Event") : item.title)
                        .font(.system(size: 13, weight: .medium))
                        .strikethrough(state != nil)
                        .foregroundStyle(state == nil ? .primary : .secondary)
                        .lineLimit(2)
                    if item.isRecurring == true {
                        Image(systemName: "repeat")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Repeats"))
                    }
                }
                Text(verbatim: EventTimeFormatter.string(start: item.start, end: item.end, isAllDay: item.isAllDay))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if let location = item.location, !location.isEmpty {
                    Label {
                        Text(verbatim: location)
                    } icon: {
                        Image(systemName: "mappin.and.ellipse")
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                if let state {
                    Text(verbatim: state)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if let calendarName = item.calendarName {
                Text(verbatim: calendarName)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// What an event row says beyond its fields, and what VoiceOver hears when
/// the keyboard selects one.
enum EventCardFormat {
    /// "Declined" (the user declined), "Canceled (event)" (canceled); nil otherwise.
    static func state(of item: EventItem) -> String? {
        if item.isCanceled == true { return String(localized: "Canceled (event)", defaultValue: "Canceled") }
        if item.isDeclined == true { return String(localized: "Declined") }
        return nil
    }

    /// Title, time, location, calendar and state.
    static func announcement(for item: EventItem, calendar: Calendar = .current, locale: Locale = AppLanguage.locale) -> String {
        [
            item.title.isEmpty ? String(localized: "New Event") : item.title,
            EventTimeFormatter.string(start: item.start, end: item.end, isAllDay: item.isAllDay, calendar: calendar,
                                      locale: locale),
            item.location,
            item.calendarName,
            item.isRecurring == true ? String(localized: "Repeats") : nil,
            state(of: item),
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }
}

/// "Tue, Sep 29 · 2:00 PM to 3:00 PM", "Tue, Sep 29 · all day"; in German
/// "Di. 29. Sept. · 14:00 bis 15:00". Ranges are written out with "to" ("bis")
/// rather than the locale's interval dash: "Sun, Oct 4 to Thu, Oct 8".
enum EventTimeFormatter {
    static func string(start: Date, end: Date, isAllDay: Bool, calendar: Calendar = .current,
                       locale: Locale = AppLanguage.locale) -> String {
        let day = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).day().month(.abbreviated)
        let end = max(end, start)
        if isAllDay {
            // All-day events end at midnight of the following day.
            let lastDay = end > start ? end.addingTimeInterval(-1) : start
            let shown = calendar.isDate(start, inSameDayAs: lastDay) ? start.formatted(day)
                : range(start.formatted(day), lastDay.formatted(day))
            return String(format: String(localized: "%@ · all day"), shown)
        }
        if calendar.isDate(start, inSameDayAs: end) {
            let time = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                                        timeZone: calendar.timeZone)
            // An event without length shows its start.
            let times = end > start ? range(start.formatted(time), end.formatted(time)) : start.formatted(time)
            return "\(start.formatted(day)) · \(times)"
        }
        let dayAndTime = day.hour().minute()
        return range(start.formatted(dayAndTime), end.formatted(dayAndTime))
    }

    /// "10:00 AM to 11:30 AM" ("10:00 bis 11:30").
    static func range(_ start: String, _ end: String) -> String {
        String(format: String(localized: "%1$@ to %2$@"), start, end)
    }
}

// MARK: - Reminders

/// Reminders: done state, title, due date and list. A click (or Return on
/// the row the keyboard selected) shows the reminder in Reminders (when
/// RootView provides `CalendarCardActions`). A card with a reminder Orbit
/// created says so and offers "Show in Reminders". Keyboard as on a note
/// card (`CardKeyboard`): ↑/↓ select a reminder, and VoiceOver hears its
/// title, due date, list and state.
struct ReminderCardView: View {
    /// The chat item showing the card.
    let id: UUID
    let items: [ReminderItem]
    @Environment(CalendarCardActions.self) private var actions: CalendarCardActions?
    @State private var selection: FileCardSelection
    @FocusState private var isFocused: Bool

    init(id: UUID = UUID(), items: [ReminderItem]) {
        self.id = id
        self.items = items
        _selection = State(initialValue: FileCardSelection(count: items.count))
    }

    var body: some View {
        ResultCardContainer(title: Phrases.reminders(items.count), systemImage: ToolCategory.reminders.systemImage) {
            ForEach(Array(items.prefix(selection.visibleCount).enumerated()), id: \.offset) { index, item in
                ReminderRow(item: item, isSelected: selection.index == index, isCardFocused: isFocused,
                            show: actions.map { actions in
                                {
                                    selection.select(index)
                                    actions.showReminder(item)
                                }
                            })
                    .id(FileCardCoordinator.rowID(card: id, index: index))
            }
            CollapseToggle(selection: $selection)
            if let created = items.first(where: { $0.wasCreated == true }) {
                CreatedItemFooter(status: String(localized: "Saved in Reminders"),
                                  buttonTitle: String(localized: "Show in Reminders"),
                                  hint: String(localized: "Shows the reminder in Reminders"),
                                  action: actions.map { actions in { actions.showReminder(created) } })
            }
        }
        .modifier(CardKeyboard(id: id, selection: $selection, isFocused: $isFocused,
                               announcement: { items.indices.contains($0) ? ReminderCardFormat.announcement(for: items[$0]) : "" },
                               activate: show(at:)))
        .onChange(of: items.count) { _, count in selection.updateCount(count) }
    }

    /// Return on a row: the reminder shows in Reminders.
    private func show(at index: Int) {
        guard let actions, items.indices.contains(index) else { return }
        actions.showReminder(items[index])
    }
}

struct ReminderRow: View {
    let item: ReminderItem
    /// Selected by the keyboard (accent while the card has it, gray otherwise).
    var isSelected = false
    var isCardFocused = false
    /// Shows the reminder in Reminders; nil = not clickable.
    var show: (() -> Void)?
    var now = Date()
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    private var isOverdue: Bool {
        ReminderCardFormat.isOverdue(item, now: now)
    }

    var body: some View {
        if let show {
            Button(action: show) {
                content
            }
            .buttonStyle(.plain)
            .rowHighlight(isSelected: isSelected, isFocused: isCardFocused)
            .help(Text("Show in Reminders"))
            .accessibilityElement(children: .combine)
            .accessibilityValue(Text(verbatim: ReminderCardFormat.state(of: item, now: now)))
            .accessibilityHint(Text("Shows the reminder in Reminders"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            content
                .background(RowSelectionBackground(isSelected: isSelected, isFocused: isCardFocused))
                .accessibilityElement(children: .combine)
                .accessibilityValue(Text(verbatim: ReminderCardFormat.state(of: item, now: now)))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 14))
                .foregroundStyle(Theme.color(hex: item.listColor) ?? .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title.isEmpty ? String(localized: "New Reminder") : item.title)
                    .font(.system(size: 13))
                    .strikethrough(item.isCompleted)
                    .foregroundStyle(item.isCompleted ? .secondary : .primary)
                    .lineLimit(2)
                if let details = ReminderCardFormat.details(for: item, isOverdue: isOverdue,
                                                            differentiateWithoutColor: differentiateWithoutColor) {
                    Text(verbatim: details)
                        .font(.system(size: 11.5))
                        .foregroundStyle(isOverdue ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// What VoiceOver hears when the keyboard selects a reminder.
enum ReminderCardFormat {
    /// Open and past its due time, or, without a time, due before today.
    static func isOverdue(_ item: ReminderItem, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let due = item.due, !item.isCompleted else { return false }
        return item.dueHasTime ? due < now : due < calendar.startOfDay(for: now)
    }

    /// "Completed", "Overdue" or "Not completed": what VoiceOver reads as the row's value.
    static func state(of item: ReminderItem, now: Date = Date(), calendar: Calendar = .current) -> String {
        item.isCompleted ? String(localized: "Completed")
            : isOverdue(item, now: now, calendar: calendar) ? String(localized: "Overdue") : String(localized: "Not completed")
    }

    /// The line under the title: due date and list, led by "Overdue" when an overdue
    /// reminder must not be told by its red color alone (Differentiate Without Color).
    static func details(for item: ReminderItem, isOverdue: Bool, differentiateWithoutColor: Bool,
                        calendar: Calendar = .current, locale: Locale = AppLanguage.locale) -> String? {
        let parts = [
            isOverdue && differentiateWithoutColor ? String(localized: "Overdue") : nil,
            item.due.map { CardDateFormatter.dateTime($0, includesTime: item.dueHasTime, calendar: calendar, locale: locale) },
            item.listName,
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Title, due date, list and state ("Not completed", "Overdue", "Completed").
    static func announcement(for item: ReminderItem, now: Date = Date(), calendar: Calendar = .current,
                             locale: Locale = AppLanguage.locale) -> String {
        [
            item.title.isEmpty ? String(localized: "New Reminder") : item.title,
            item.due.map { CardDateFormatter.dateTime($0, includesTime: item.dueHasTime, calendar: calendar, locale: locale) },
            item.listName,
            state(of: item, now: now, calendar: calendar),
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }
}

/// Under a card with something Orbit just created: that it is saved, and a
/// button that shows it in its app.
struct CreatedItemFooter: View {
    let status: String
    let buttonTitle: String
    let hint: String
    /// nil: no button (cards without `CalendarCardActions`).
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label {
                Text(verbatim: status)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.green)
            Spacer(minLength: 8)
            if let action {
                Button(action: action) {
                    Text(verbatim: buttonTitle)
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .help(Text(verbatim: hint))
                .accessibilityHint(Text(verbatim: hint))
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 5)
        .padding(.bottom, 1)
    }
}

// MARK: - Contacts

/// Contacts: initials, name, organization, mail addresses and phone numbers.
struct ContactCardView: View {
    let items: [ContactItem]

    var body: some View {
        ResultCardContainer(title: Phrases.contacts(items.count), systemImage: ToolCategory.contacts.systemImage) {
            CollapsibleRows(items: items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Text(verbatim: ContactInitials.initials(for: item.name))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.secondary.opacity(0.75)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.name)
                            .font(.system(size: 13, weight: .medium))
                        if let organization = item.organization, !organization.isEmpty {
                            Text(verbatim: organization)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(item.emails.enumerated()), id: \.offset) { _, email in
                            if let url = ContactLinks.mailURL(email) {
                                Link(destination: url) {
                                    Text(verbatim: email)
                                }
                                .font(.system(size: 12))
                            } else {
                                Text(verbatim: email)
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                            }
                        }
                        ForEach(Array(item.phones.enumerated()), id: \.offset) { _, phone in
                            Text(verbatim: phone)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .accessibilityElement(children: .contain)
            }
        }
    }
}

enum ContactLinks {
    /// A mailto: link for a plain address, or nil when it does not look like one.
    static func mailURL(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("@"), !trimmed.contains(where: { $0.isWhitespace || $0 == "?" || $0 == "&" }),
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed.union(["@"])) else {
            return nil
        }
        return URL(string: "mailto:\(encoded)")
    }
}

enum ContactInitials {
    /// "LM" for "Lisa Müller", "L" for "Lisa", "?" for an empty name.
    static func initials(for name: String) -> String {
        let words = name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }
}
