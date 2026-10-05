import AppKit
import SwiftUI

/// The settings window: one reusable titled window hosting `SettingsView`. Opening it hides
/// the panel and activates Orbit, so text fields in Settings get normal keyboard focus. ⌘1 to ⌘5
/// choose a tab (`SettingsWindow`).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let frameAutosaveName = "OrbitSettingsWindow"

    private let environment: AppEnvironment
    private let hidePanel: () -> Void
    /// Created on first use and kept (with its SwiftUI state) afterwards.
    private(set) var window: NSWindow?
    /// The tab the window shows.
    let navigation = SettingsNavigation()

    init(environment: AppEnvironment, hidePanel: @escaping () -> Void) {
        self.environment = environment
        self.hidePanel = hidePanel
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Shows the window, on `tab` when one is given (else on the tab shown last).
    func show(tab: SettingsTab? = nil) {
        if let tab {
            navigation.tab = tab
        }
        hidePanel()
        let window = window ?? makeWindow()
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // Activation is cooperative since macOS 14; the window still comes to the front if
        // the system declines to activate Orbit.
        window.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    /// Orbit has no other windows to fall back to: hand focus back to the app the user came
    /// from instead of leaving a windowless Orbit active (unless e.g. the onboarding is open).
    func windowWillClose(_ notification: Notification) {
        guard NSApp.isActive, !environment.panelState.isVisible,
              !NSApp.hasOtherTitledWindow(besides: notification.object as? NSWindow) else { return }
        Task { @MainActor in
            NSApp.hide(nil)
        }
    }

    private func makeWindow() -> NSWindow {
        let hostingController = NSHostingController(rootView: SettingsView(environment: environment, navigation: navigation))
        let window = SettingsWindow(contentViewController: hostingController)
        window.selectTab = { [navigation] tab in navigation.tab = tab }
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = String(localized: "Orbit Settings")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Opens on the Space the user is on instead of switching to where it was last shown.
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        // The hosting view reports its size lazily; size the window before positioning it.
        let fittingSize = hostingController.view.fittingSize
        if fittingSize.width > 0, fittingSize.height > 0 {
            window.setContentSize(fittingSize)
        }
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
        self.window = window
        return window
    }
}

/// The window of `SettingsView`: ⌘1 to ⌘5 choose a tab in the tab bar's order, also without
/// Full Keyboard Access, which the tab bar itself needs to take the keyboard, and on layouts
/// whose number row types other characters (`CommandNumberKey`).
final class SettingsWindow: NSWindow {
    var selectTab: ((SettingsTab) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           let tab = SettingsTab.forShortcut(characters: event.charactersIgnoringModifiers, keyCode: event.keyCode,
                                             modifiers: event.modifierFlags) {
            selectTab?(tab)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension SettingsTab {
    /// ⌘1 … ⌘5 (or ⇧⌘, see `CommandNumberKey`): the tab at that position; nil for any other key.
    static func forShortcut(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> SettingsTab? {
        guard let number = CommandNumberKey.number(characters: characters, keyCode: keyCode, modifiers: modifiers),
              allCases.indices.contains(number - 1) else { return nil }
        return allCases[number - 1]
    }
}

extension NSApplication {
    /// Whether a titled Orbit window other than `window` is open (Settings,
    /// the onboarding, the About panel); the panel does not count.
    func hasOtherTitledWindow(besides window: NSWindow?) -> Bool {
        windows.contains { candidate in
            candidate !== window && candidate.isVisible && candidate.styleMask.contains(.titled)
                && !(candidate is OrbitPanel)
        }
    }
}
