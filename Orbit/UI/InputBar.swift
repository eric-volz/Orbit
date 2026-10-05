import AppKit
import SwiftUI

/// Keyboard commands of the input field. The move and number handlers return
/// whether they consumed the key.
struct InputCommands {
    /// Return.
    var submit: () -> Void = {}
    /// ⌘Return (see `ConfirmationKeyboard`); false when it did nothing.
    var commandSubmit: () -> Bool = { false }
    var moveUp: () -> Bool = { false }
    var moveDown: () -> Bool = { false }
    /// ⌘1 … ⌘9.
    var openResult: (Int) -> Bool = { _ in false }
    /// Page Up/Down, Home/End, ⌘↑/⌘↓ (the chat).
    var scroll: (ChatScroller.Target) -> Bool = { _ in false }
    /// Tab and Shift-Tab: the keyboard moves to the latest card (files, mails,
    /// notes, a draft's buttons).
    var focusCard: () -> Bool = { false }
    /// ⌫ in the empty input: removes the last context chip (`ContextChipRemoval`).
    var removeLastChip: () -> Bool = { false }
    /// Escape.
    var escape: () -> Void = {}
}

/// The large input field of the panel with its leading icon and the stop and
/// "New Chat" buttons.
struct InputBar: View {
    @Binding var text: String
    let mode: PanelMode
    let isRunning: Bool
    let isFocused: FocusState<Bool>.Binding
    let commands: InputCommands
    let onStop: () -> Void
    let onNewChat: () -> Void
    /// The chat is parked and the input empty: ↑ shows it again.
    var canContinueChat = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: mode == .chat ? "sparkles" : "magnifyingglass")
                .font(.system(size: Theme.inputIconSize, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            TextField(text: $text, prompt: prompt) {
                Text("Input")
            }
            .textFieldStyle(.plain)
            .font(.system(size: Theme.inputFontSize))
            .focused(isFocused)
            .onSubmit(commands.submit)
            .onKeyPress(keys: [.upArrow], phases: .down) { press in
                if press.modifiers.contains(.command) {
                    return commands.scroll(.top) ? .handled : .ignored
                }
                return commands.moveUp() ? .handled : .ignored
            }
            .onKeyPress(keys: [.downArrow], phases: .down) { press in
                if press.modifiers.contains(.command) {
                    return commands.scroll(.bottom) ? .handled : .ignored
                }
                return commands.moveDown() ? .handled : .ignored
            }
            .onKeyPress(keys: [.pageUp, .pageDown, .home, .end], phases: .down) { press in
                let target: ChatScroller.Target = switch press.key {
                case .pageUp: .pageUp
                case .pageDown: .pageDown
                case .home: .top
                default: .bottom
                }
                return commands.scroll(target) ? .handled : .ignored
            }
            .onKeyPress(keys: [.return], phases: .down) { press in
                guard press.modifiers.contains(.command) else { return .ignored }
                return commands.commandSubmit() ? .handled : .ignored
            }
            .onKeyPress(characters: .decimalDigits, phases: .down) { press in
                guard press.modifiers.contains(.command),
                      !press.modifiers.contains(.option), !press.modifiers.contains(.control),
                      let number = Int(press.characters), (1...SearchSelection.shortcutCount).contains(number) else {
                    return .ignored
                }
                return commands.openResult(number) ? .handled : .ignored
            }
            .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")], phases: .down) { press in
                // Shift-Tab arrives as back tab (U+0019). While an input method composes text, Tab is its own.
                guard press.modifiers.intersection([.command, .option, .control]).isEmpty, !isComposingText else {
                    return .ignored
                }
                return commands.focusCard() ? .handled : .ignored
            }
            .onKeyPress(keys: [.delete, InputBar.backspace], phases: .down) { press in
                // ⌫ in the empty input removes the last context chip, like a token; with text it edits the text.
                // Held down, it stops at the empty input (repeats are the field's). The Mac's ⌫ key arrives as
                // DEL (U+007F), not as SwiftUI's `.delete` (U+0008).
                guard press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty, text.isEmpty,
                      !isComposingText else {
                    return .ignored
                }
                return commands.removeLastChip() ? .handled : .ignored
            }
            .onKeyPress(.escape) {
                commands.escape()
                return .handled
            }
            // Fallback when the field editor turns Escape into cancelOperation:.
            .onExitCommand(perform: commands.escape)
            .accessibilityHint(hint)

            if isRunning {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 19))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(PanelIconButtonStyle())
                .help(Text("Stop Answer (Esc)"))
                .accessibilityLabel(Text("Stop Answer"))
            }
            if mode == .chat {
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .regular))
                }
                .buttonStyle(PanelIconButtonStyle())
                .keyboardShortcut("n", modifiers: .command)
                .help(Text("New Chat (⌘N)"))
                .accessibilityLabel(Text("New Chat"))
            }
        }
        .padding(.horizontal, Theme.contentInset)
        .padding(.vertical, 14)
        .frame(minHeight: 58)
    }

    private var prompt: Text {
        mode == .chat ? Text("Message Orbit…") : Text("Ask Orbit or search…")
    }

    private var hint: Text {
        if mode == .chat { return Text("Return sends the message.") }
        if canContinueChat { return Text("Type to search; the Up Arrow continues the last chat.") }
        return Text("Return asks Orbit; the arrow keys select a result.")
    }

    /// The ⌫ key as macOS reports it: DEL (U+007F, `NSDeleteCharacter`).
    nonisolated static let backspace = KeyEquivalent("\u{7F}")

    /// Whether the field editor holds marked text of an input method.
    private var isComposingText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
    }
}

/// Round, borderless icon button with a hover highlight (panel toolbar).
struct PanelIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverIconButton(configuration: configuration)
    }

    private struct HoverIconButton: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (isHovered ? 0.07 : 0)))
                )
                .contentShape(Circle())
                .onHover { isHovered = $0 }
        }
    }
}
