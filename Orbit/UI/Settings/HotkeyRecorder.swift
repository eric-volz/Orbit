import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

/// Records a global keyboard shortcut (stored and registered by
/// KeyboardShortcuts).
///
/// Why not `KeyboardShortcuts.Recorder`: it loads its texts from the
/// package's SwiftPM resource bundle via `Bundle.module`, which works only
/// because Scripts/build-app.sh ships that bundle inside Orbit.app and points
/// the accessor at it. This recorder uses only the package's public API, so it
/// never depends on those resources, and it says in Orbit's own words why a
/// shortcut was refused.
struct HotkeyRecorder: View {
    @State private var model: HotkeyRecorderModel
    @Environment(\.controlActiveState) private var controlActiveState

    init(name: KeyboardShortcuts.Name) {
        _model = State(initialValue: HotkeyRecorderModel(name: name))
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                Button(action: model.toggleRecording) {
                    Text(verbatim: model.fieldText)
                        .foregroundStyle(model.isRecording ? .secondary : .primary)
                        .frame(minWidth: 150)
                }
                .help(model.isRecording
                      ? Text("Press the new key combination. Esc cancels, ⌫ removes the shortcut.")
                      : Text("Click to record a new shortcut."))
                .accessibilityLabel(Text("Keyboard shortcut to open Orbit"))
                .accessibilityValue(Text(verbatim: model.fieldText))
                .accessibilityHint(Text("Activate, then press the new key combination. Esc cancels."))
                if model.shortcut != nil, !model.isRecording {
                    Button(action: model.clear) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(Text("Remove Shortcut"))
                    .accessibilityLabel(Text("Remove Shortcut"))
                }
            }
            if let feedback = model.feedback {
                feedbackView(feedback)
            }
        }
        .onChange(of: controlActiveState) { _, state in
            // Leaving the window ends a recording (and re-enables the hotkey).
            if state == .inactive { model.stopRecording() }
        }
        .onDisappear(perform: model.stopRecording)
    }

    @ViewBuilder
    private func feedbackView(_ feedback: HotkeyRecorderModel.Feedback) -> some View {
        switch feedback {
        case .needsModifier:
            Text(verbatim: feedback.text)
                .font(.callout)
                .foregroundStyle(.orange)
        case .takenByMenu:
            Text(verbatim: feedback.text)
                .font(.callout)
                .foregroundStyle(.red)
        case .takenBySystem(let shortcut):
            VStack(alignment: .trailing, spacing: 4) {
                Text(verbatim: feedback.text)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Use Anyway") {
                    model.save(shortcut)
                }
                .controlSize(.small)
            }
        }
    }
}

/// State and key handling of `HotkeyRecorder`. VoiceOver hears the shortcut it
/// recorded and why it refused one: the keyboard stays on the recorder.
@MainActor
@Observable
final class HotkeyRecorderModel {
    enum Feedback: Equatable {
        case needsModifier
        case takenByMenu(String)
        case takenBySystem(KeyboardShortcuts.Shortcut)

        /// What the recorder says under the field.
        var text: String {
            switch self {
            case .needsModifier: String(localized: "Use at least one of the keys ⌘, ⌥ or ⌃.")
            case .takenByMenu(let title):
                String(format: String(localized: "Orbit already uses this shortcut for “%@”."), title)
            case .takenBySystem:
                String(localized: "macOS already uses this shortcut. Change it first in System Settings > Keyboard > Keyboard Shortcuts.")
            }
        }
    }

    let name: KeyboardShortcuts.Name
    private(set) var shortcut: KeyboardShortcuts.Shortcut?
    private(set) var isRecording = false
    private(set) var feedback: Feedback? {
        didSet {
            if let feedback, feedback != oldValue { announcer?.announce(feedback.text, priority: .high) }
        }
    }

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var wasEnabled = true
    @ObservationIgnored private let announcer: (any Announcing)?

    init(name: KeyboardShortcuts.Name, announcer: (any Announcing)? = VoiceOverAnnouncer()) {
        self.name = name
        self.announcer = announcer
        shortcut = KeyboardShortcuts.getShortcut(for: name)
    }

    var fieldText: String {
        if isRecording { return String(localized: "Press a key combination…") }
        return shortcut.map(HotkeyFormatter.string(for:)) ?? String(localized: "No Shortcut")
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard !isRecording else { return }
        feedback = nil
        isRecording = true
        // Pressing the current shortcut must be recorded, not open the panel.
        wasEnabled = KeyboardShortcuts.isEnabled(for: name)
        KeyboardShortcuts.disable(name)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            let consumed = MainActor.assumeIsolated {
                guard let self, self.isRecording else { return false }
                return self.handle(event)
            }
            return consumed ? nil : event
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if wasEnabled {
            KeyboardShortcuts.enable(name)
        }
    }

    func clear() {
        stopRecording()
        feedback = nil
        KeyboardShortcuts.setShortcut(nil, for: name)
        shortcut = nil
        announcer?.announce(fieldText, priority: .high)
    }

    func save(_ shortcut: KeyboardShortcuts.Shortcut) {
        stopRecording()
        feedback = nil
        KeyboardShortcuts.setShortcut(shortcut, for: name)
        self.shortcut = shortcut
        announcer?.announce(String(format: String(localized: "Keyboard shortcut: %@"), fieldText), priority: .high)
    }

    /// Handles a key press while recording. Returns true when it consumed the event.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad])
        let plain = modifiers.subtracting(.function).isEmpty
        switch Int(event.keyCode) {
        case kVK_Escape where plain:
            stopRecording()
            return true
        case kVK_Delete where plain, kVK_ForwardDelete where plain:
            clear()
            return true
        case kVK_Tab where plain:
            stopRecording()
            return false
        default:
            break
        }
        guard let shortcut = KeyboardShortcuts.Shortcut(event: event) else { return true }
        let result = HotkeyValidation.evaluate(
            shortcut,
            isFunctionKey: HotkeyValidation.isFunctionKey(Int(event.keyCode)),
            menuItemTitle: NSApp.mainMenu.flatMap { HotkeyValidation.menuItemTitle(matching: shortcut, in: $0) },
            systemShortcuts: SystemHotkeys.enabledShortcuts()
        )
        switch result {
        case .accepted:
            save(shortcut)
        case .needsModifier:
            NSSound.beep()
            feedback = .needsModifier
        case .takenByMenu(let title):
            NSSound.beep()
            feedback = .takenByMenu(title)
        case .takenBySystem:
            stopRecording()
            feedback = .takenBySystem(shortcut)
        }
        return true
    }
}

/// Display strings for shortcuts ("⌥ Leertaste" style, as macOS shows them).
@MainActor
enum HotkeyFormatter {
    static func string(for shortcut: KeyboardShortcuts.Shortcut) -> String {
        // `Shortcut.description` localizes "Space" through the package's resource
        // bundle (see HotkeyRecorder); all other keys use layout characters or symbols.
        if shortcut.key == .space {
            return modifierSymbols(shortcut.modifiers) + String(localized: "Space")
        }
        return shortcut.description
    }

    /// In macOS order: ⌃ ⌥ ⇧ ⌘.
    static func modifierSymbols(_ modifiers: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols
    }
}

/// Which recorded shortcuts Orbit accepts (the rules of KeyboardShortcuts' recorder).
enum HotkeyValidation {
    enum Result: Equatable {
        case accepted
        /// Global shortcuts need ⌘, ⌥ or ⌃ (⇧ alone does not work), except function keys.
        case needsModifier
        case takenByMenu(String)
        case takenBySystem
    }

    static func evaluate(_ shortcut: KeyboardShortcuts.Shortcut, isFunctionKey: Bool, menuItemTitle: String?,
                         systemShortcuts: [KeyboardShortcuts.Shortcut]) -> Result {
        if shortcut.modifiers.subtracting([.shift, .function]).isEmpty, !isFunctionKey {
            return .needsModifier
        }
        if let menuItemTitle {
            return .takenByMenu(menuItemTitle)
        }
        // F12 without modifiers is listed by the system but usable.
        if shortcut != KeyboardShortcuts.Shortcut(.f12), systemShortcuts.contains(shortcut) {
            return .takenBySystem
        }
        return .accepted
    }

    static func isFunctionKey(_ keyCode: Int) -> Bool {
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        return functionKeys.contains(keyCode)
    }

    /// The title of a menu item (searched recursively) with the same key equivalent.
    @MainActor
    static func menuItemTitle(matching shortcut: KeyboardShortcuts.Shortcut, in menu: NSMenu) -> String? {
        for item in menu.items {
            var keyEquivalent = item.keyEquivalent
            var mask = item.keyEquivalentModifierMask
            if shortcut.modifiers.contains(.shift), keyEquivalent.lowercased() != keyEquivalent {
                keyEquivalent = keyEquivalent.lowercased()
                mask.insert(.shift)
            }
            if !keyEquivalent.isEmpty, shortcut.nsMenuItemKeyEquivalent == keyEquivalent, shortcut.modifiers == mask {
                return item.title
            }
            if let submenu = item.submenu, let title = menuItemTitle(matching: shortcut, in: submenu) {
                return title
            }
        }
        return nil
    }
}

/// The system-wide shortcuts macOS currently uses (Spotlight, Mission Control, …).
enum SystemHotkeys {
    static func enabledShortcuts() -> [KeyboardShortcuts.Shortcut] {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let hotKeys = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return hotKeys.compactMap { hotKey in
            guard (hotKey[kHISymbolicHotKeyEnabled] as? Bool) == true,
                  let keyCode = hotKey[kHISymbolicHotKeyCode] as? Int,
                  let modifiers = hotKey[kHISymbolicHotKeyModifiers] as? Int else { return nil }
            return KeyboardShortcuts.Shortcut(carbonKeyCode: keyCode, carbonModifiers: modifiers)
        }
    }
}
