import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Shows or hides the Orbit panel. Default ⌥Space; the user changes it in Settings with
    /// `KeyboardShortcuts.Recorder("Tastenkürzel:", name: .togglePanel)`.
    static let togglePanel = Self("togglePanel", default: HotkeyManager.defaultShortcut)
}

/// Registers the global hotkey that toggles the panel (Carbon hot key via KeyboardShortcuts;
/// needs no Accessibility permission).
@MainActor
final class HotkeyManager {
    nonisolated static let defaultShortcut = KeyboardShortcuts.Shortcut(.space, modifiers: [.option])

    private let onToggle: () -> Void
    private var isStarted = false

    init(onToggle: @escaping () -> Void) {
        self.onToggle = onToggle
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // KeyboardShortcuts calls handlers on the main thread.
        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak self] in
            self?.onToggle()
        }
        Log.app.info("Hotkey handler registered (shortcut set: \(self.shortcut != nil, privacy: .public))")
    }

    /// The current shortcut; nil when the user removed it in Settings.
    var shortcut: KeyboardShortcuts.Shortcut? {
        KeyboardShortcuts.getShortcut(for: .togglePanel)
    }

    /// E.g. "⌥Space"; nil when no shortcut is set.
    var shortcutDescription: String? {
        shortcut?.description
    }
}
