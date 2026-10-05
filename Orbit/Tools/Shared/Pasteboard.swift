import AppKit

/// Puts text on the clipboard: the text Orbit wrote for a reply, which the
/// user pastes into Mail's reply window (Mail does not let scripts write into
/// it), and "Copy Text" on the reply's card. The app writes the user's
/// clipboard (`SystemPasteboard.general`); services built for tests and
/// restricted debug sessions use one that never does, and the DEBUG fake-data
/// mode records the text instead.
protocol PasteboardWriting: Sendable {
    /// Replaces the clipboard's contents with `text`; false when that failed.
    func write(_ text: String) async -> Bool
}

/// A pasteboard by name, written on the main actor: `.general` is the user's
/// clipboard; tests use a private name.
struct SystemPasteboard: PasteboardWriting {
    /// The user's clipboard.
    static let general = SystemPasteboard(name: .general)

    let name: NSPasteboard.Name

    func write(_ text: String) async -> Bool {
        let name = name
        return await MainActor.run {
            let pasteboard = NSPasteboard(name: name)
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }
    }
}

/// Writes nothing (services built for tests, restricted debug sessions).
struct DisabledPasteboard: PasteboardWriting {
    func write(_ text: String) async -> Bool { false }
}
