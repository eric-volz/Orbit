import AppKit
import SwiftUI

/// The keyboard on a card whose rows (or buttons, or tiles) it selects, like
/// on a file card: mail, note, event and reminder cards, the tiles of a photo
/// grid and the buttons of a mail draft. Tab in the input reaches the latest
/// card, Tab and Shift-Tab move to the next and previous card and, past the
/// last or first one, back to the input. ↑/↓ select (←/→ too for buttons side
/// by side; in a grid ←/→ move by a tile and ↑/↓ by a row), past the
/// collapsed rows the card expands, Return opens the selected row or tile
/// or presses the selected button (Space presses a button too). Escape is not handled here: it acts as Escape anywhere in the
/// panel (`AppEnvironment.handleEscape`): it stops a running answer, otherwise
/// it closes the panel, as on file cards (spec §4: Escape closes the panel);
/// Tab and Shift-Tab, not Escape, lead back to the input. VoiceOver hears what
/// the keyboard selects, because the keyboard stays on the card.
struct CardKeyboard: ViewModifier {
    /// The chat item showing the card.
    let id: UUID
    @Binding var selection: FileCardSelection
    let isFocused: FocusState<Bool>.Binding
    /// What VoiceOver hears for the row (or button) at an index.
    let announcement: (Int) -> String
    /// Return: opens the row (or presses the button) at an index.
    let activate: (Int) -> Void
    /// The selection is a row of buttons side by side.
    var selectsButtons = false
    /// Tiles per row of a grid (1: rows or buttons).
    var columns = 1

    @Environment(FileCardCoordinator.self) private var coordinator: FileCardCoordinator?

    func body(content: Content) -> some View {
        content
            // `.edit`: a click or Tab focuses the card even without full keyboard access.
            .focusable(selection.count > 0, interactions: .edit)
            .focused(isFocused)
            // The selection shows the focus (accent when focused, gray otherwise), like a list.
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat], action: handleKey)
            .onChange(of: isFocused.wrappedValue) { _, focused in
                // From the keyboard the first row shows where the keyboard is; a click selects its own row.
                if focused, NSEvent.pressedMouseButtons == 0 { selection.selectFirstIfNeeded() }
            }
            .onChange(of: selection.index) { old, new in
                guard let new, new != old else { return }
                coordinator?.scroll(to: .row(FileCardCoordinator.rowID(card: id, index: new)))
            }
            .onChange(of: coordinator?.focusRequest) { _, request in takeFocus(request) }
            .onAppear { takeFocus(coordinator?.focusRequest) }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Shift-Tab arrives as back tab (U+0019).
        if press.key == .tab || press.key == KeyEquivalent("\u{19}") {
            guard press.phase == .down, press.modifiers.intersection([.command, .option, .control]).isEmpty else {
                return .ignored
            }
            let backward = press.key != .tab || press.modifiers.contains(.shift)
            return coordinator?.focusCard(nextTo: id, backward: backward) == true ? .handled : .ignored
        }
        guard press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return .ignored }
        let isRepeat = press.phase == .repeat
        let isGrid = columns > 1
        switch press.key {
        case .downArrow:
            move { isGrid ? $0.moveVertically(by: 1, columns: columns) : $0.moveDown() }
        case .upArrow:
            move { isGrid ? $0.moveVertically(by: -1, columns: columns) : $0.moveUp() }
        case .rightArrow where selectsButtons || isGrid:
            move { $0.moveDown() }
        case .leftArrow where selectsButtons || isGrid:
            move { $0.moveUp() }
        case .return:
            if !isRepeat { activateSelection() }
        case .space where selectsButtons:
            if !isRepeat { activateSelection() }
        default:
            // Escape and everything else: as anywhere in the panel. Escape stops a running
            // answer, otherwise closes the panel (like on file cards); it does not lead back
            // to the input (Tab and Shift-Tab do).
            return .ignored
        }
        return .handled
    }

    /// An arrow key: VoiceOver hears the new selection, also when it stopped
    /// at the first or last row. (The binding reads the old value until the
    /// view updates, so the new one is worked out here.)
    private func move(_ change: (inout FileCardSelection) -> Void) {
        var moved = selection
        change(&moved)
        selection = moved
        announce(moved.index, priority: .high)
    }

    private func activateSelection() {
        guard let index = selection.index else { return }
        activate(index)
    }

    private func announce(_ index: Int?, priority: NSAccessibilityPriorityLevel) {
        guard let index else { return }
        coordinator?.announce(announcement(index), priority: priority)
    }

    private func takeFocus(_ request: FileCardCoordinator.FocusRequest?) {
        guard let request, request.cardID == id else { return }
        coordinator?.didTakeFocus(request)
        isFocused.wrappedValue = true
        var focused = selection
        focused.selectFirstIfNeeded()
        selection = focused
        // After VoiceOver named the card that took the keyboard.
        announce(focused.index, priority: .medium)
    }
}

/// "Show N More" / "Show Less" under the rows of a card the
/// keyboard can select in.
struct CollapseToggle: View {
    @Binding var selection: FileCardSelection

    var body: some View {
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
}
