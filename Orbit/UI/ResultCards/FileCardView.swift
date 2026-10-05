import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files a tool found: icon, name, folder, date and size per row.
///
/// Mouse: a click selects a row and gives the card the keyboard, a double
/// click opens the file, rows drag out as files, the button that appears on
/// hover shows the file in Finder, and the context menu offers Öffnen,
/// Übersicht (Quick Look), Im Finder zeigen and Pfad kopieren. Keyboard (Tab in
/// the input reaches the latest card, Tab and Shift-Tab move between cards):
/// ↑/↓ select (past the collapsed rows the card expands), Space toggles Quick
/// Look, Return opens, ⇧⌘R shows the file in Finder, ⌥⌘C copies its path
/// (`FileCardKeyCommand`), Escape closes Quick Look before anything else.
/// VoiceOver hears the row the keyboard selects.
struct FileCardView: View {
    /// The chat item showing the card.
    let id: UUID
    let items: [FileItem]

    @Environment(FileCardCoordinator.self) private var coordinator: FileCardCoordinator?
    @State private var selection: FileCardSelection
    @FocusState private var isFocused: Bool

    init(id: UUID, items: [FileItem], selection: FileCardSelection? = nil) {
        self.id = id
        self.items = items
        _selection = State(initialValue: selection ?? FileCardSelection(count: items.count))
    }

    private var quickLook: QuickLookController? {
        coordinator?.quickLook
    }

    var body: some View {
        ResultCardContainer(title: Phrases.files(items.count), systemImage: ToolCategory.files.systemImage) {
            ForEach(Array(items.prefix(selection.visibleCount).enumerated()), id: \.offset) { index, item in
                FileRow(item: item, isSelected: selection.index == index, isCardFocused: isFocused,
                        actions: actions(forRowAt: index))
                    .id(FileCardCoordinator.rowID(card: id, index: index))
            }
            if selection.isCollapsible {
                Button {
                    selection.toggleExpanded()
                } label: {
                    Text(verbatim: selection.isExpanded
                         ? String(localized: "Show Less")
                         : String(format: String(localized: "Show %lld More"), selection.hiddenCount))
                        .font(.system(size: 12))
                }
                .buttonStyle(.link)
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 2)
            }
        }
        // `.edit`: a click or Tab focuses the card even without full keyboard access.
        .focusable(!items.isEmpty, interactions: .edit)
        .focused($isFocused)
        // The selected row shows the focus (accent when focused, gray otherwise), like a list.
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat], action: handleKey)
        .onChange(of: isFocused) { _, focused in
            // From the keyboard the first row shows where the keyboard is; a click selects its own row.
            if focused, NSEvent.pressedMouseButtons == 0 { selection.selectFirstIfNeeded() }
        }
        .onChange(of: selection) { old, new in selectionChanged(from: old, to: new) }
        .onChange(of: items.count) { _, count in selection.updateCount(count) }
        .onChange(of: coordinator?.focusRequest) { _, request in takeFocus(request) }
        .onChange(of: quickLook?.preview) { _, preview in follow(preview) }
        .onChange(of: quickLook?.focusReturn) { _, focusReturn in
            if focusReturn?.source == id { isFocused = true }
        }
        .onAppear {
            takeFocus(coordinator?.focusRequest)
            follow(quickLook?.preview)
        }
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Shift-Tab arrives as back tab (U+0019).
        if press.key == .tab || press.key == KeyEquivalent("\u{19}") {
            guard press.phase == .down, press.modifiers.intersection([.command, .option, .control]).isEmpty else {
                return .ignored
            }
            let backward = press.key != .tab || press.modifiers.contains(.shift)
            return coordinator?.focusCard(nextTo: id, backward: backward) == true ? .handled : .ignored
        }
        if let command = FileCardKeyCommand(key: press.key, modifiers: press.modifiers) {
            if press.phase == .down { perform(command) }
            return .handled
        }
        guard press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return .ignored }
        let isRepeat = press.phase == .repeat
        switch press.key {
        case .downArrow:
            selection.moveDown()
            announceSelection(priority: .high)
        case .upArrow:
            selection.moveUp()
            announceSelection(priority: .high)
        case .space:
            if !isRepeat { toggleQuickLook() }
        case .return:
            if !isRepeat { openSelection() }
        case .escape:
            // Only a preview; otherwise the panel handles Escape as usual.
            return !isRepeat && quickLook?.close() == true ? .handled : .ignored
        default:
            return .ignored
        }
        return .handled
    }

    private func toggleQuickLook() {
        selection.selectFirstIfNeeded()
        guard let index = selection.index else { return }
        quickLook?.toggle(source: id, urls: items.map(\.url), index: index)
    }

    private func openSelection() {
        guard let index = selection.index, items.indices.contains(index) else { return }
        coordinator?.open(items[index])
    }

    /// ⇧⌘R and ⌥⌘C on the selected row (the first one when none is selected yet).
    private func perform(_ command: FileCardKeyCommand) {
        selection.selectFirstIfNeeded()
        guard let index = selection.index, items.indices.contains(index) else { return }
        switch command {
        case .reveal: coordinator?.reveal(items[index])
        case .copyPath: coordinator?.copyPath(items[index])
        }
    }

    /// The row the keyboard selected, for VoiceOver (also when an arrow key
    /// stopped at the first or last row).
    private func announceSelection(priority: NSAccessibilityPriorityLevel) {
        guard let index = selection.index, items.indices.contains(index) else { return }
        coordinator?.announceSelection(of: items[index], priority: priority)
    }

    // MARK: Rows

    private func actions(forRowAt index: Int) -> FileRowActions {
        let item = items[index]
        return FileRowActions(
            select: { select(index) },
            open: {
                select(index)
                coordinator?.open(item)
            },
            quickLook: {
                select(index)
                quickLook?.show(source: id, urls: items.map(\.url), index: index)
            },
            reveal: { coordinator?.reveal(item) },
            copyPath: { coordinator?.copyPath(item) }
        )
    }

    /// A click: selects the row and gives the card the keyboard.
    private func select(_ index: Int) {
        selection.select(index)
        isFocused = true
    }

    // MARK: Staying in step

    private func selectionChanged(from old: FileCardSelection, to new: FileCardSelection) {
        guard let index = new.index, index != old.index else { return }
        quickLook?.follow(index: index, in: id)
        coordinator?.scroll(to: .row(FileCardCoordinator.rowID(card: id, index: index)))
    }

    /// Navigation in the Quick Look panel moves the selection.
    private func follow(_ preview: QuickLookController.Preview?) {
        guard let preview, preview.source == id, selection.index != preview.index else { return }
        selection.select(preview.index)
    }

    private func takeFocus(_ request: FileCardCoordinator.FocusRequest?) {
        guard let request, request.cardID == id else { return }
        coordinator?.didTakeFocus(request)
        isFocused = true
        selection.selectFirstIfNeeded()
        // After VoiceOver named the card that took the keyboard.
        announceSelection(priority: .medium)
    }
}

/// What a row can do; the card fills in the handlers.
struct FileRowActions {
    var select: () -> Void = {}
    var open: () -> Void = {}
    var quickLook: () -> Void = {}
    var reveal: () -> Void = {}
    var copyPath: () -> Void = {}
}

/// One file: icon, name and folder on the left; date and size on the right,
/// with a "Show in Finder" button while the pointer is over the row.
struct FileRow: View {
    let item: FileItem
    var isSelected = false
    /// Whether the card has the keyboard (selection in the accent color).
    var isCardFocused = false
    var actions = FileRowActions()

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            FileIconView(path: item.path, contentType: item.contentType, isDirectory: item.isDirectory, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: item.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: FileCardFormat.folder(of: item))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(action: actions.reveal) {
                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 15))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(Text("Show in Finder"))
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            // VoiceOver offers "Show in Finder" as an action of the row.
            .accessibilityHidden(true)
            VStack(alignment: .trailing, spacing: 1) {
                if let modified = item.modified {
                    Text(verbatim: CardDateFormatter.string(for: modified))
                }
                if let size = FileCardFormat.size(of: item) {
                    Text(verbatim: size)
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(RowSelectionBackground(isSelected: isSelected, isFocused: isCardFocused,
                                           unselectedFill: isHovered ? Theme.hoverFill : .clear))
        .onHover { isHovered = $0 }
        // The single click must not wait for a possible second one.
        .onTapGesture(count: 2, perform: actions.open)
        .simultaneousGesture(TapGesture().onEnded(actions.select))
        .onDrag { FileDrag.itemProvider(for: item) }
        .contextMenu {
            Button("Open", action: actions.open)
            Button("Quick Look", action: actions.quickLook)
            Button("Show in Finder", action: actions.reveal)
                .keyboardShortcut(FileCardKeyCommand.reveal.shortcut)
            Divider()
            Button("Copy Path", action: actions.copyPath)
                .keyboardShortcut(FileCardKeyCommand.copyPath.shortcut)
        }
        .help(Text(verbatim: FilePathFormatter.abbreviate(item.path)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: item.name))
        .accessibilityValue(Text(verbatim: FileCardFormat.accessibilityValue(for: item)))
        .accessibilityHint(FileCardFormat.opensInFinder(item) ? Text("Shows the file in Finder")
                           : item.isDirectory ? Text("Opens the folder") : Text("Opens the file"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, actions.open)
        // VoiceOver lists the named actions last modifier first.
        .accessibilityAction(named: Text("Copy Path"), actions.copyPath)
        .accessibilityAction(named: Text("Show in Finder"), actions.reveal)
        .accessibilityAction(named: Text("Quick Look"), actions.quickLook)
        .accessibilityAction(named: Text("Open"), actions.open)
    }
}

/// Keys of a file card besides the arrows, Space and Return: the row's
/// commands that have no key of their own, as other Mac apps have them.
enum FileCardKeyCommand: Equatable, Sendable {
    /// ⇧⌘R: "Show in Finder" (as "Show in Finder" in Music).
    case reveal
    /// ⌥⌘C: "Copy Path" (as Finder's "Copy as Pathname").
    case copyPath

    /// The command a key press means on a card; nil for any other key.
    init?(key: KeyEquivalent, modifiers: EventModifiers) {
        let character = String(key.character).lowercased()
        let pressed = modifiers.intersection([.command, .option, .control, .shift])
        if character == "r", pressed == [.command, .shift] {
            self = .reveal
        } else if character == "c", pressed == [.command, .option] {
            self = .copyPath
        } else {
            return nil
        }
    }

    /// Shown next to the command in the row's context menu.
    var shortcut: KeyboardShortcut {
        switch self {
        case .reveal: KeyboardShortcut("r", modifiers: [.command, .shift])
        case .copyPath: KeyboardShortcut("c", modifiers: [.command, .option])
        }
    }
}

/// Texts of a file row.
enum FileCardFormat {
    /// Whether "Open" shows the item in Finder instead: it could run code
    /// (by name and type; opening checks the file itself again).
    static func opensInFinder(_ item: FileItem) -> Bool {
        let type = item.contentType.flatMap { UTType($0) }
        return OpenFileSafety.refusal(contentType: type, pathExtension: (item.path as NSString).pathExtension,
                                      isRegularFileWithExecuteBit: false) != nil
    }

    /// "2,3 MB" (decimal units like Finder, localized); nil for folders and unknown sizes.
    static func size(of item: FileItem, locale: Locale = AppLanguage.locale) -> String? {
        guard !item.isDirectory, let size = item.size, size >= 0 else { return nil }
        return size.formatted(.byteCount(style: .file).locale(locale))
    }

    /// The folder line: the folder as Finder names it ("Dokumente ▸
    /// Rechnungen"), or (in chats saved before Orbit named folders) its path.
    /// The tooltip and "Copy Path" keep the path.
    static func folder(of item: FileItem, homeDirectory: String = NSHomeDirectory()) -> String {
        guard let names = item.folderNames, !names.isEmpty else {
            return FilePathFormatter.parentFolder(of: item.path, homeDirectory: homeDirectory)
        }
        return FolderNames.shown(names)
    }

    /// What VoiceOver reads after the name: folder, date and size.
    static func accessibilityValue(for item: FileItem, now: Date = Date(), calendar: Calendar = .current,
                                   locale: Locale = AppLanguage.locale, homeDirectory: String = NSHomeDirectory()) -> String {
        [
            item.folderNames.flatMap { $0.isEmpty ? nil : FolderNames.spoken($0) }
                ?? FilePathFormatter.parentFolder(of: item.path, homeDirectory: homeDirectory),
            item.modified.map { CardDateFormatter.string(for: $0, now: now, calendar: calendar, locale: locale) },
            size(of: item, locale: locale),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }

    /// What VoiceOver announces when the keyboard selects a row: name, folder, date and size.
    static func announcement(for item: FileItem, now: Date = Date(), calendar: Calendar = .current,
                             locale: Locale = AppLanguage.locale, homeDirectory: String = NSHomeDirectory()) -> String {
        let value = accessibilityValue(for: item, now: now, calendar: calendar, locale: locale, homeDirectory: homeDirectory)
        return value.isEmpty ? item.name : item.name + ", " + value
    }
}
