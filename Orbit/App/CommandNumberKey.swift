import AppKit

/// ⌘1 … ⌘9 on every keyboard layout. Most layouts type digits on the number
/// row; on some (French and Belgian AZERTY, Czech, Slovak, Lithuanian, …) it
/// types other characters without Shift (⌘ and the "1" key give "&" or "+").
/// There the number row's key counts, with ⌘ or ⇧⌘.
enum CommandNumberKey {
    /// The number row's keys 1 to 9 (`kVK_ANSI_1` …), wherever a layout puts its digits.
    static let numberRowKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// The number of ⌘ (or ⇧⌘) with a digit, typed (also on the numeric
    /// keypad), or else the number row's key at that place; nil for any other
    /// key and with ⌥ or ⌃.
    static func number(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
        let modifiers = modifiers.intersection([.command, .option, .control, .shift])
        guard modifiers == .command || modifiers == [.command, .shift] else { return nil }
        if let characters, characters.count == 1, let digit = Int(characters) {
            return digit
        }
        return numberRowKeyCodes.firstIndex(of: keyCode).map { $0 + 1 }
    }

    /// The key press as the digit it stands for, so what handles ⌘1 … ⌘9 (the
    /// panel's instant results) gets it on every layout; nil when it types its
    /// digit already or is no such key.
    static func digitEvent(for event: NSEvent) -> NSEvent? {
        guard event.type == .keyDown || event.type == .keyUp, let characters = event.charactersIgnoringModifiers,
              Int(characters) == nil,
              let number = number(characters: characters, keyCode: event.keyCode, modifiers: event.modifierFlags) else {
            return nil
        }
        let digit = String(number)
        return NSEvent.keyEvent(with: event.type, location: event.locationInWindow, modifierFlags: event.modifierFlags,
                                timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
                                characters: digit, charactersIgnoringModifiers: digit, isARepeat: event.isARepeat,
                                keyCode: event.keyCode)
    }
}
