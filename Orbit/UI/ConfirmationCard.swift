import SwiftUI

/// Asks the user before a `write`/`destructive` tool runs: title, what will
/// happen, editable fields and "Run" / "Cancel". Once resolved, the
/// card stays in the chat read-only with its outcome.
struct ConfirmationCard: View {
    let state: ConfirmationState
    /// ⌘Return runs the action only while the chat input is empty: with text in
    /// it, ⌘Return means "send", and must never approve the action instead.
    var approveShortcutEnabled = true
    let onResolve: (ConfirmationDecision) -> Void

    /// Edited field values by field id (only fields the user touched).
    @State private var values: [String: String] = [:]
    /// Set on the first click so a double click cannot answer twice.
    @State private var hasDecided = false
    /// The card's frame in the chat's scroll view (nil until laid out).
    @State private var frameInChat: CGRect?
    /// The field with the keyboard (by field id).
    @FocusState private var focusedField: String?
    @Environment(ConfirmationKeyboard.self) private var keyboard: ConfirmationKeyboard?

    private var request: ConfirmationRequest { state.request }
    private var isPending: Bool { state.status == .pending }
    private var isDestructive: Bool { request.riskLevel == .destructive }
    private var tint: Color { isDestructive ? .red : .accentColor }

    /// Whether the waiting card is wholly in the visible part of the chat.
    private var isInView: Bool {
        guard isPending, let frameInChat else { return false }
        return ConfirmationKeyboard.isInView(frame: frameInChat, viewportHeight: keyboard?.viewportHeight)
    }

    /// ⌘Return runs the card only while the user can see it (`ConfirmationKeyboard.mayRun`).
    private var mayRunFromKeyboard: Bool {
        guard let keyboard else { return isInView }
        return keyboard.mayRun(request.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let warning = warningText {
                warningBanner(warning)
            }
            if !request.fields.isEmpty {
                fields
            }
            footer
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(tint: isPending ? tint : nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: String(format: String(localized: "Confirmation: %@"), request.title)))
        // Only a waiting card follows the scrolling (decided cards in a long chat stay still).
        .onGeometryChange(for: CGRect?.self) { [tracksFrame = isPending] proxy in
            tracksFrame ? proxy.frame(in: .named(chatScrollSpace)) : nil
        } action: { frame in
            frameInChat = frame
        }
        .onChange(of: isInView, initial: true) { _, inView in
            keyboard?.setInView(inView, requestID: request.id)
        }
        .onDisappear { keyboard?.setInView(false, requestID: request.id) }
        .onChange(of: keyboard?.approveRequest) { _, approval in
            guard let approval, approval.requestID == request.id else { return }
            keyboard?.didHandle(approval)
            if isPending { approve() }
        }
        .onChange(of: keyboard?.focusRequest) { _, focus in takeKeyboard(focus) }
        // The keyboard left the waiting card's fields (the user clicked back into the input, say): from now on
        // ⌘Return runs the card only while it is in view. (A decided card's fields go away with the keyboard;
        // the input takes it back, see `ConfirmationKeyboard.cardDone`.)
        .onChange(of: focusedField) { _, field in
            guard field == nil, isPending else { return }
            keyboard?.cardLostKeyboard(request.id)
        }
        .onAppear {
            // A row the chat builds again (scrolled back) reports where it is anew; none of its fields has the
            // keyboard unless ⌘Return asks it to take it.
            keyboard?.setInView(isInView, requestID: request.id)
            if !takeKeyboard(keyboard?.focusRequest) {
                keyboard?.cardLostKeyboard(request.id)
            }
        }
    }

    /// ⌘Return revealed the card: its first editable field takes the keyboard,
    /// so the user can still change a value; ⌘Return there runs the action.
    /// True when a field took it.
    @discardableResult
    private func takeKeyboard(_ focus: ConfirmationKeyboard.Request?) -> Bool {
        guard let focus, focus.requestID == request.id else { return false }
        keyboard?.didHandle(focus)
        guard isPending, let field = request.fields.first(where: Self.takesKeyboard) else { return false }
        focusedField = field.id
        keyboard?.cardTookKeyboard(request.id)
        return true
    }

    /// Fields the keyboard can be in: text, a text area, a date picker or a date as text.
    static func takesKeyboard(_ field: ConfirmationField) -> Bool {
        switch field.kind {
        case .text, .multilineText: true
        case .dateTime: !(field.isOptionalDate == true && field.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        case .readOnly: false
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: isDestructive ? "exclamationmark.triangle.fill" : "hand.raised.fill")
                .font(.system(size: 14))
                .foregroundStyle(isPending ? tint : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: request.title)
                    .font(.system(size: 14, weight: .semibold))
                if !request.message.isEmpty {
                    Text(verbatim: request.message)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var warningText: String? {
        if let warning = request.warning, !warning.isEmpty { return warning }
        return isDestructive ? String(localized: "This action cannot be undone.") : nil
    }

    private func warningBanner(_ text: String) -> some View {
        Label {
            Text(verbatim: text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.octagon.fill")
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(.red)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.red.opacity(0.1)))
        .contrastEdge(RoundedRectangle(cornerRadius: 6, style: .continuous), color: .red)
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(request.fields) { field in
                GridRow {
                    Text(verbatim: field.label)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                        .accessibilityHidden(true)
                    editor(for: field)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.system(size: 13))
    }

    @ViewBuilder
    private func editor(for field: ConfirmationField) -> some View {
        let value = values[field.id] ?? field.value
        if !isPending || field.kind == .readOnly {
            Text(verbatim: ConfirmationDateValue.displayText(for: field, value: value))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(verbatim: field.label))
                .accessibilityValue(Text(verbatim: ConfirmationDateValue.accessibilityValue(for: field, value: value)))
        } else {
            switch field.kind {
            case .text, .readOnly:
                TextField(text: binding(for: field), prompt: nil) {
                    Text(verbatim: field.label)
                }
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: field.id)
            case .multilineText:
                TextEditor(text: binding(for: field))
                    .focused($focusedField, equals: field.id)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 4)
                    .frame(minHeight: 58, maxHeight: 150)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor))
                    )
                    .accessibilityLabel(Text(verbatim: field.label))
            case .dateTime:
                if field.isOptionalDate == true {
                    optionalDateEditor(for: field)
                } else if let parsed = ConfirmationDateValue.parse(field.value) {
                    DatePicker(selection: dateBinding(for: field, original: parsed),
                               displayedComponents: parsed.isDateOnly ? [.date] : [.date, .hourAndMinute]) {
                        Text(verbatim: field.label)
                    }
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .fixedSize()
                    .focused($focusedField, equals: field.id)
                } else {
                    dateTextField(for: field)
                }
            }
        }
    }

    /// A date that may be removed, added and switched between a day and a day
    /// with a time (a reminder's due date): "Add Date" while there is
    /// none, otherwise the picker, "With time" and "No Date".
    @ViewBuilder
    private func optionalDateEditor(for field: ConfirmationField) -> some View {
        let current = values[field.id] ?? field.value
        if let parsed = ConfirmationDateValue.parse(current) {
            HStack(spacing: 10) {
                DatePicker(selection: optionalDateBinding(for: field),
                           displayedComponents: parsed.isDateOnly ? [.date] : [.date, .hourAndMinute]) {
                    Text(verbatim: field.label)
                }
                .labelsHidden()
                .datePickerStyle(.field)
                .fixedSize()
                .focused($focusedField, equals: field.id)
                Toggle(isOn: timeBinding(for: field)) {
                    Text("With time")
                }
                .toggleStyle(.checkbox)
                .fixedSize()
                Button("No Date") {
                    values[field.id] = ""
                }
                .fixedSize()
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: field.label))
        } else if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button("Add Date") {
                values[field.id] = ConfirmationDateValue.added()
            }
            .accessibilityHint(Text(verbatim: field.label))
        } else {
            dateTextField(for: field)
        }
    }

    /// Not a date the picker understands: edited as text, with the format as its prompt.
    private func dateTextField(for field: ConfirmationField) -> some View {
        TextField(text: binding(for: field), prompt: Text("YYYY-MM-DD HH:MM")) {
            Text(verbatim: field.label)
        }
        .textFieldStyle(.roundedBorder)
        .focused($focusedField, equals: field.id)
    }

    @ViewBuilder
    private var footer: some View {
        if isPending {
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    decide(.cancelled)
                } label: {
                    Text("Cancel")
                        .frame(minWidth: 64)
                }
                .keyboardShortcut(".", modifiers: .command)
                .help(Text("Cancel (⌘.)"))
                Button {
                    approve()
                } label: {
                    Text(verbatim: request.confirmLabel ?? String(localized: "Run"))
                        .frame(minWidth: 64)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                // Only for a card in view: out of view, ⌘Return reaches the input, which brings the card into
                // view first (`ConfirmationKeyboard`).
                .keyboardShortcut(approveShortcutEnabled && mayRunFromKeyboard ? KeyboardShortcut(.return, modifiers: .command) : nil)
                .help(approveShortcutEnabled ? Text("Run (⌘↩)") : Text("Run"))
            }
            .disabled(hasDecided)
        } else {
            statusLabel
        }
    }

    /// "Run", ⌘Return: runs the action with the values edited on the card.
    private func approve() {
        decide(.approved(edits: ConfirmationEdits.changes(fields: request.fields, values: values)))
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch state.status {
        case .approved:
            Label("Completed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 12.5, weight: .medium))
        case .confirmed:
            Label("Running…", systemImage: "hourglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12.5, weight: .medium))
        case .failed:
            Label("Failed", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .font(.system(size: 12.5, weight: .medium))
        case .notRun:
            Label("Not run", systemImage: "minus.circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 12.5, weight: .medium))
        case .outcomeUnknown:
            Label("Stopped, result unknown", systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
                .font(.system(size: 12.5, weight: .medium))
        case .cancelled:
            Label("Canceled", systemImage: "xmark.circle.fill")
                .foregroundStyle(.secondary)
                .font(.system(size: 12.5, weight: .medium))
        case .expired:
            Label("Not run: the request ended.", systemImage: "clock")
                .foregroundStyle(.secondary)
                .font(.system(size: 12.5, weight: .medium))
        case .pending:
            EmptyView()
        }
    }

    private func decide(_ decision: ConfirmationDecision) {
        guard !hasDecided else { return }
        hasDecided = true
        onResolve(decision)
    }

    // MARK: Bindings

    private func binding(for field: ConfirmationField) -> Binding<String> {
        Binding {
            values[field.id] ?? field.value
        } set: { newValue in
            values[field.id] = newValue
        }
    }

    private func dateBinding(for field: ConfirmationField, original: FlexibleDate) -> Binding<Date> {
        Binding {
            values[field.id].flatMap { ConfirmationDateValue.parse($0)?.date } ?? original.date
        } set: { newDate in
            values[field.id] = ConfirmationDateValue.format(newDate, isDateOnly: original.isDateOnly)
        }
    }

    /// The picker of an optional date: a new date keeps the current form (a day, or a day with a time).
    private func optionalDateBinding(for field: ConfirmationField) -> Binding<Date> {
        Binding {
            ConfirmationDateValue.parse(values[field.id] ?? field.value)?.date ?? Date()
        } set: { newDate in
            let isDateOnly = ConfirmationDateValue.parse(values[field.id] ?? field.value)?.isDateOnly ?? true
            values[field.id] = ConfirmationDateValue.format(newDate, isDateOnly: isDateOnly)
        }
    }

    /// "With time": whether the optional date has a time.
    private func timeBinding(for field: ConfirmationField) -> Binding<Bool> {
        Binding {
            ConfirmationDateValue.parse(values[field.id] ?? field.value).map { !$0.isDateOnly } ?? false
        } set: { withTime in
            let current = values[field.id] ?? field.value
            values[field.id] = ConfirmationDateValue.switching(current, toTime: withTime) ?? current
        }
    }
}

/// Reading and writing `dateTime` field values (ISO 8601, see FlexibleDate).
enum ConfirmationDateValue {
    static func parse(_ value: String, timeZone: TimeZone = .current) -> FlexibleDate? {
        FlexibleDate.parse(value, timeZone: timeZone)
    }

    /// "2026-09-29" for date-only values, otherwise ISO 8601 with offset
    /// ("2026-09-29T14:30:00+02:00").
    static func format(_ date: Date, isDateOnly: Bool, timeZone: TimeZone = .current) -> String {
        guard isDateOnly else { return FlexibleDate.iso8601(date, timeZone: timeZone) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    /// Read-only text for a field: dates formatted for people ("No Date"
    /// for an optional date that was left out), everything else verbatim.
    static func displayText(for field: ConfirmationField, value: String, timeZone: TimeZone = .current,
                            locale: Locale = AppLanguage.locale) -> String {
        guard field.kind == .dateTime else { return value }
        if field.isOptionalDate == true, value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "No Date")
        }
        guard let parsed = parse(value, timeZone: timeZone) else { return value }
        var style = Date.FormatStyle(date: .complete, time: parsed.isDateOnly ? .omitted : .shortened)
        style.timeZone = timeZone
        style.locale = locale
        return parsed.date.formatted(style)
    }

    /// What VoiceOver reads for a read-only field: exactly what the card
    /// shows ("Dienstag, 6. Oktober 2026 um 10:00", never "2026-10-06T10:00:00+02:00").
    static func accessibilityValue(for field: ConfirmationField, value: String, timeZone: TimeZone = .current,
                                   locale: Locale = AppLanguage.locale) -> String {
        displayText(for: field, value: value, timeZone: timeZone, locale: locale)
    }

    /// The time an optional date gets with "With time": 9:00 on its day.
    static let defaultHour = 9

    /// "Add Date": today, as a day ("2026-10-04").
    static func added(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        format(now, isDateOnly: true, timeZone: timeZone)
    }

    /// "With time" switched on: the day at `defaultHour`; off: the day
    /// alone. A value already in that form stays; nil when it is no date.
    static func switching(_ value: String, toTime withTime: Bool, timeZone: TimeZone = .current) -> String? {
        guard let parsed = parse(value, timeZone: timeZone) else { return nil }
        guard parsed.isDateOnly == withTime else { return value }
        guard withTime else { return format(parsed.date, isDateOnly: true, timeZone: timeZone) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.startOfDay(for: parsed.date)
        let date = calendar.date(bySettingHour: defaultHour, minute: 0, second: 0, of: day) ?? day
        return format(date, isDateOnly: false, timeZone: timeZone)
    }
}

/// Which fields the user changed on a confirmation card.
enum ConfirmationEdits {
    /// Edited values that differ from the request (read-only fields are
    /// ignored; dates count as unchanged when they denote the same instant).
    static func changes(fields: [ConfirmationField], values: [String: String],
                        timeZone: TimeZone = .current) -> [String: String] {
        var changes: [String: String] = [:]
        for field in fields where field.kind != .readOnly {
            guard let value = values[field.id], value != field.value else { continue }
            if field.kind == .dateTime,
               let original = FlexibleDate.parse(field.value, timeZone: timeZone),
               let edited = FlexibleDate.parse(value, timeZone: timeZone),
               original.date == edited.date, original.isDateOnly == edited.isDateOnly {
                continue
            }
            changes[field.id] = value
        }
        return changes
    }
}
