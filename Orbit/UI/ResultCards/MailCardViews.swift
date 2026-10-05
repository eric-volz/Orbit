import AppKit
import SwiftUI

/// Mails: sender, subject, date and preview. Click opens the message in Mail
/// (through `MailCardActions` when RootView provides it). Keyboard as on a
/// file card (`CardKeyboard`): ↑/↓ select a message, Return opens it, and
/// VoiceOver hears sender, subject, date and whether it is unread.
struct MailCardView: View {
    /// The chat item showing the card.
    let id: UUID
    let items: [MailItem]
    @Environment(MailCardActions.self) private var actions: MailCardActions?
    @State private var selection: FileCardSelection
    @FocusState private var isFocused: Bool

    init(id: UUID = UUID(), items: [MailItem]) {
        self.id = id
        self.items = items
        _selection = State(initialValue: FileCardSelection(count: items.count))
    }

    var body: some View {
        ResultCardContainer(title: Phrases.emails(items.count), systemImage: ToolCategory.mail.systemImage) {
            ForEach(Array(items.prefix(selection.visibleCount).enumerated()), id: \.offset) { index, item in
                MailRow(item: item, isSelected: selection.index == index, isCardFocused: isFocused,
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
                               announcement: { items.indices.contains($0) ? MailCardFormat.announcement(for: items[$0]) : "" },
                               activate: open(at:)))
        .onChange(of: items.count) { _, count in selection.updateCount(count) }
    }

    /// Return on a row: the message opens in Mail (rows without a link do nothing).
    private func open(at index: Int) {
        guard let actions, items.indices.contains(index), MailCardActions.canOpen(items[index]) else { return }
        actions.open(items[index])
    }
}

struct MailRow: View {
    let item: MailItem
    /// Selected by the keyboard (accent while the card has it, gray otherwise).
    var isSelected = false
    var isCardFocused = false
    /// Opens the message in Mail; nil = open its link directly.
    var open: (() -> Void)?

    private var url: URL? {
        item.messageID.flatMap(MailLink.url(messageID:))
    }

    private var isUnread: Bool {
        item.isRead == false
    }

    var body: some View {
        if let url {
            Button {
                if let open {
                    open()
                } else {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                content
            }
            .buttonStyle(.plain)
            .rowHighlight(isSelected: isSelected, isFocused: isCardFocused)
            .help(Text("Open in Mail"))
            .accessibilityElement(children: .combine)
            .accessibilityValue(isUnread ? Text("Unread") : Text(verbatim: ""))
            .accessibilityHint(Text("Opens the email in Mail"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            content
                .background(RowSelectionBackground(isSelected: isSelected, isFocused: isCardFocused))
                .accessibilityElement(children: .combine)
                .accessibilityValue(isUnread ? Text("Unread") : Text(verbatim: ""))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(isUnread ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: item.sender)
                        .font(.system(size: 13, weight: isUnread ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let date = item.date {
                        Text(verbatim: CardDateFormatter.string(for: date))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                Text(verbatim: item.subject.isEmpty ? String(localized: "(No Subject)") : item.subject)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                if let preview = item.preview, !preview.isEmpty {
                    Text(verbatim: preview)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// What VoiceOver hears when the keyboard selects a message.
enum MailCardFormat {
    /// Sender, subject, date and, when it is, "Unread".
    static func announcement(for item: MailItem, now: Date = Date(), calendar: Calendar = .current,
                             locale: Locale = AppLanguage.locale) -> String {
        [
            item.sender,
            item.subject.isEmpty ? String(localized: "(No Subject)") : item.subject,
            item.date.map { CardDateFormatter.string(for: $0, now: now, calendar: calendar, locale: locale) },
            item.isRead == false ? String(localized: "Unread") : nil,
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }
}

/// The buttons of a draft card, in the order shown: what the keyboard selects
/// on the card.
enum MailDraftButton: Hashable, Sendable {
    /// "Copy Text" (replies with text).
    case copyText
    /// "Show in Mail" (drafts and replies Mail named).
    case show

    static func available(for draft: MailDraftItem) -> [MailDraftButton] {
        guard draft.isOpenInMail else { return [] }
        var buttons: [MailDraftButton] = []
        if MailCardActions.canCopyText(draft) { buttons.append(.copyText) }
        if MailCardActions.canShow(draft) { buttons.append(.show) }
        return buttons
    }

    /// The button's title: what VoiceOver hears when the keyboard selects it.
    var title: String {
        switch self {
        case .copyText: String(localized: "Copy Text")
        case .show: String(localized: "Show in Mail")
        }
    }
}

/// A mail draft Orbit prepared (opened in Mail for the user to send).
/// "Show in Mail" brings its window to the front (when RootView provides
/// `MailCardActions`). A reply is Mail's own reply window, which Orbit cannot
/// write into: the card says that the text is on the clipboard for ⌘V and
/// offers "Copy Text". Keyboard as on a file card (`CardKeyboard`): the
/// arrow keys select a button, Return or Space presses it.
struct MailDraftCardView: View {
    /// The chat item showing the card.
    let id: UUID
    let draft: MailDraftItem
    @Environment(MailCardActions.self) private var actions: MailCardActions?
    /// "Copied" for a moment after "Copy Text".
    @State private var didCopy = false
    @State private var copyFeedback: Task<Void, Never>?
    @State private var selection: FileCardSelection
    @FocusState private var isFocused: Bool

    init(id: UUID = UUID(), draft: MailDraftItem) {
        self.id = id
        self.draft = draft
        _selection = State(initialValue: FileCardSelection(count: MailDraftButton.available(for: draft).count))
    }

    /// The buttons shown (none without `MailCardActions`).
    private var buttons: [MailDraftButton] {
        actions == nil ? [] : MailDraftButton.available(for: draft)
    }

    var body: some View {
        ResultCardContainer(title: draft.reply == nil ? String(localized: "Email draft") : String(localized: "Email reply"),
                            systemImage: draft.reply == nil ? "square.and.pencil" : "arrowshape.turn.up.left") {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
                    header(label: Text("To:"), value: draft.to.joined(separator: ", "))
                    if !draft.cc.isEmpty {
                        header(label: Text("Cc:"), value: draft.cc.joined(separator: ", "))
                    }
                    header(label: Text("Subject:"), value: draft.subject)
                }
                .font(.system(size: 12.5))
                if !draft.body.isEmpty {
                    Divider()
                    Text(verbatim: draft.body)
                        .font(.system(size: 13))
                        .lineSpacing(2)
                        .lineLimit(12)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if draft.isOpenInMail {
                    // The keyboard selects the buttons; the text above stays selectable with the mouse.
                    Group {
                        if let reply = draft.reply {
                            replyFooter(reply)
                        } else {
                            draftFooter
                        }
                    }
                    .modifier(CardKeyboard(id: id, selection: $selection, isFocused: $isFocused,
                                           announcement: { buttons.indices.contains($0) ? buttons[$0].title : "" },
                                           activate: { index in
                                               if buttons.indices.contains(index) { press(buttons[index]) }
                                           },
                                           selectsButtons: true))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
    }

    /// A button, clicked or pressed from the keyboard.
    private func press(_ button: MailDraftButton) {
        guard let actions else { return }
        switch button {
        case .copyText: copyText(actions)
        case .show: actions.showDraft(draft)
        }
    }

    /// The keyboard's selection around a button.
    private func selectionMark(_ button: MailDraftButton) -> some View {
        let isSelected = buttons.firstIndex(of: button).map { $0 == selection.index } ?? false
        return RowSelectionBackground(isSelected: isSelected, isFocused: isFocused, cornerRadius: 5)
            .padding(.horizontal, -5)
            .padding(.vertical, -2)
    }

    private var draftFooter: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label("Opened in Mail: review it there before sending", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.green)
            Spacer(minLength: 8)
            if actions != nil, MailCardActions.canShow(draft) {
                Button("Show in Mail") {
                    press(.show)
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .background(selectionMark(.show))
                .help(Text("Brings the draft window in Mail to the front"))
                .accessibilityHint(Text("Brings the draft window in Mail to the front"))
            }
        }
    }

    /// Where the reply's text is and what to do with it, then the buttons.
    private func replyFooter(_ reply: MailReplyInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(verbatim: Self.replyStatus(reply, hasText: !draft.body.isEmpty))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: reply.isTextOnClipboard ? "doc.on.clipboard" : "checkmark.circle.fill")
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.green)
            if actions != nil, MailCardActions.canCopyText(draft) || MailCardActions.canShow(draft) {
                HStack(spacing: 14) {
                    if MailCardActions.canCopyText(draft) {
                        Button {
                            press(.copyText)
                        } label: {
                            didCopy ? Text("Copied") : Text("Copy Text")
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .background(selectionMark(.copyText))
                        .help(Text("Puts the reply’s text on the clipboard again"))
                        .accessibilityHint(Text("Puts the reply’s text on the clipboard again"))
                    }
                    if MailCardActions.canShow(draft) {
                        Button("Show in Mail") {
                            press(.show)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .background(selectionMark(.show))
                        .help(Text("Brings the reply window in Mail to the front"))
                        .accessibilityHint(Text("Brings the reply window in Mail to the front"))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// The line under a reply: the window is open, and where its text is.
    static func replyStatus(_ reply: MailReplyInfo, hasText: Bool) -> String {
        if !hasText {
            return String(localized: "Reply opened in Mail: write it there")
        }
        if reply.isTextOnClipboard {
            return String(localized: "Reply opened in Mail: paste the text from the clipboard with ⌘V")
        }
        return String(localized: "Reply opened in Mail: copy the text with “Copy Text” and paste it with ⌘V")
    }

    private func copyText(_ actions: MailCardActions) {
        let copy = actions.copyText(draft)
        copyFeedback?.cancel()
        copyFeedback = Task { @MainActor in
            guard await copy.value else { return }
            didCopy = true
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            didCopy = false
        }
    }

    private func header(label: Text, value: String) -> some View {
        GridRow {
            label
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(verbatim: value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Links that open a message in Mail.
enum MailLink {
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~@")

    /// "message://%3Cid%3E" for an RFC 5322 Message-ID (with or without angle brackets).
    static func url(messageID: String) -> URL? {
        let trimmed = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\n"))
        guard !trimmed.isEmpty, let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "message://%3C\(encoded)%3E")
    }
}
