import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import Testing
@testable import Orbit

@Suite("Hotkey formatting and validation")
@MainActor
struct HotkeyValidationTests {
    @Test func formatsSpaceWithoutPackageResources() {
        #expect(HotkeyFormatter.string(for: KeyboardShortcuts.Shortcut(.space, modifiers: [.option])) == "⌥Space")
        #expect(HotkeyFormatter.string(for: KeyboardShortcuts.Shortcut(.space, modifiers: [.command, .control])) == "⌃⌘Space")
    }

    @Test func modifierOrderMatchesMacOS() {
        #expect(HotkeyFormatter.modifierSymbols([.command, .shift, .option, .control]) == "⌃⌥⇧⌘")
        #expect(HotkeyFormatter.modifierSymbols([]) == "")
    }

    @Test func requiresARealModifierExceptForFunctionKeys() {
        let noModifier = KeyboardShortcuts.Shortcut(.k)
        #expect(HotkeyValidation.evaluate(noModifier, isFunctionKey: false, menuItemTitle: nil, systemShortcuts: []) == .needsModifier)
        let shiftOnly = KeyboardShortcuts.Shortcut(.k, modifiers: [.shift])
        #expect(HotkeyValidation.evaluate(shiftOnly, isFunctionKey: false, menuItemTitle: nil, systemShortcuts: []) == .needsModifier)
        let functionKey = KeyboardShortcuts.Shortcut(.f5)
        #expect(HotkeyValidation.evaluate(functionKey, isFunctionKey: true, menuItemTitle: nil, systemShortcuts: []) == .accepted)
        let option = KeyboardShortcuts.Shortcut(.space, modifiers: [.option])
        #expect(HotkeyValidation.evaluate(option, isFunctionKey: false, menuItemTitle: nil, systemShortcuts: []) == .accepted)
    }

    @Test func reportsConflicts() {
        let commandSpace = KeyboardShortcuts.Shortcut(.space, modifiers: [.command])
        #expect(HotkeyValidation.evaluate(commandSpace, isFunctionKey: false, menuItemTitle: nil, systemShortcuts: [commandSpace]) == .takenBySystem)
        #expect(HotkeyValidation.evaluate(commandSpace, isFunctionKey: false, menuItemTitle: "New Chat", systemShortcuts: []) == .takenByMenu("New Chat"))
        let f12 = KeyboardShortcuts.Shortcut(.f12)
        #expect(HotkeyValidation.evaluate(f12, isFunctionKey: true, menuItemTitle: nil, systemShortcuts: [f12]) == .accepted)
    }

    @Test func findsMenuItemsRecursively() {
        let menu = NSMenu()
        let chat = NSMenu(title: "Chat")
        chat.addItem(NSMenuItem(title: "New Chat", action: nil, keyEquivalent: "n"))
        // Letters that are identical on QWERTY and QWERTZ: matching goes through the keyboard layout.
        let saveAs = NSMenuItem(title: "Sichern unter", action: nil, keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        chat.addItem(saveAs)
        let upper = NSMenuItem(title: "Groß", action: nil, keyEquivalent: "G")
        chat.addItem(upper)
        let submenuItem = NSMenuItem(title: "Chat", action: nil, keyEquivalent: "")
        submenuItem.submenu = chat
        menu.addItem(submenuItem)

        #expect(HotkeyValidation.menuItemTitle(matching: KeyboardShortcuts.Shortcut(.n, modifiers: [.command]), in: menu) == "New Chat")
        #expect(HotkeyValidation.menuItemTitle(matching: KeyboardShortcuts.Shortcut(.n, modifiers: [.command, .option]), in: menu) == nil)
        #expect(HotkeyValidation.menuItemTitle(matching: KeyboardShortcuts.Shortcut(.s, modifiers: [.command, .shift]), in: menu) == "Sichern unter")
        #expect(HotkeyValidation.menuItemTitle(matching: KeyboardShortcuts.Shortcut(.g, modifiers: [.command, .shift]), in: menu) == "Groß")
        #expect(HotkeyValidation.menuItemTitle(matching: KeyboardShortcuts.Shortcut(.space, modifiers: [.option]), in: menu) == nil)
    }

    @Test func functionKeys() {
        #expect(HotkeyValidation.isFunctionKey(kVK_F1))
        #expect(HotkeyValidation.isFunctionKey(kVK_F20))
        #expect(!HotkeyValidation.isFunctionKey(kVK_ANSI_A))
        #expect(!HotkeyValidation.isFunctionKey(kVK_Space))
    }

    @Test func readsSystemShortcutsWithoutCrashing() {
        _ = SystemHotkeys.enabledShortcuts()
    }
}

extension UIWindowTests {
    /// Sends real key events through the app's event queue so the recorder's
    /// local event monitor sees them (opt-in: needs a window server session).
    ///
    ///     ORBIT_UI_TESTS=1 Scripts/swiftpm.sh test --filter HotkeyRecorderEvents
    @Suite("HotkeyRecorderEvents", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_UI_TESTS"] == "1"))
    @MainActor
    struct HotkeyRecorderEventTests {
        static let name = KeyboardShortcuts.Name("orbitTestRecorder")

        private func press(keyCode: Int, characters: String, modifiers: NSEvent.ModifierFlags = []) {
            _ = NSApplication.shared
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: UInt16(keyCode)) else { return }
            // sendEvent(_:) runs the local event monitors first.
            NSApp.sendEvent(event)
        }

        @Test func recordsValidatesCancelsAndClears() {
            KeyboardShortcuts.reset(Self.name)
            defer { KeyboardShortcuts.reset(Self.name) }
            let model = HotkeyRecorderModel(name: Self.name)
            #expect(model.shortcut == nil)
            #expect(model.fieldText == "No Shortcut")

            model.startRecording()
            #expect(model.isRecording)
            #expect(!KeyboardShortcuts.isEnabled(for: Self.name), "the hotkey is paused while recording")
            press(keyCode: kVK_ANSI_K, characters: "k")
            #expect(model.feedback == .needsModifier)
            #expect(model.isRecording)

            press(keyCode: kVK_ANSI_K, characters: "k", modifiers: [.command, .option])
            #expect(!model.isRecording)
            #expect(model.shortcut == KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option]))
            #expect(KeyboardShortcuts.getShortcut(for: Self.name) == model.shortcut)
            #expect(KeyboardShortcuts.isEnabled(for: Self.name))

            model.startRecording()
            press(keyCode: kVK_Escape, characters: "\u{1B}")
            #expect(!model.isRecording)
            #expect(model.shortcut == KeyboardShortcuts.Shortcut(.k, modifiers: [.command, .option]))

            model.startRecording()
            press(keyCode: kVK_Delete, characters: "\u{7F}")
            #expect(!model.isRecording)
            #expect(model.shortcut == nil)
            #expect(KeyboardShortcuts.getShortcut(for: Self.name) == nil)
        }
    }
}
