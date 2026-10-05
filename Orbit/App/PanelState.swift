import CoreGraphics
import Foundation
import Observation

/// Shared state between the panel (AppKit, PanelController) and its SwiftUI
/// content (RootView).
@MainActor
@Observable
final class PanelState {
    /// Height the SwiftUI content wants, measured by RootView. The controller
    /// resizes the panel, keeping its top edge fixed (it grows downward).
    var preferredContentHeight: CGFloat = 64
    /// Maximum content height (about 70% of the active screen), set by the controller.
    var maximumContentHeight: CGFloat = 640
    /// Set by the controller. Shown, the panel has the keyboard again (`keyboardDidReturn`).
    var isVisible = false {
        didSet {
            if isVisible, !oldValue, hasKeyboard() {
                keyboardDidReturn()
            }
        }
    }
    /// Incremented every time the panel is shown; RootView focuses the input.
    var showCount = 0
    /// Text in the input field (search query or chat message).
    var inputText = ""
    /// Context chips captured when the panel opened (removable by the user).
    var attachments: [ContextAttachment] = []
    /// Orbit handing the keyboard to Mail's reply window: the panel stays
    /// visible meanwhile (the controller decides with it; RootView shows the
    /// reply's card).
    var keyboardHandoff = KeyboardHandoff()

    /// Wired by the controller.
    @ObservationIgnored var closePanel: () -> Void = {}
    /// Wired by the controller: closes the panel unless it has the keyboard.
    @ObservationIgnored var closePanelIfNotKey: () -> Void = {}
    /// Opens Settings on a tab (nil: the tab shown last).
    @ObservationIgnored var openSettings: (SettingsTab?) -> Void = { _ in }
    /// Wired by the environment: the panel has the keyboard again (it was shown, or took the keyboard back
    /// from Mail's reply window), so VoiceOver hears a card that waits with the keys that decide it.
    @ObservationIgnored var keyboardDidReturn: () -> Void = {}

    /// Whether the panel is shown and has the keyboard, so keys such as ⌘↩ reach it; not while Orbit hands
    /// the keyboard to Mail's reply window (`KeyboardHandoff.isKeyboardAway(at:)`).
    func hasKeyboard(at now: Date = Date()) -> Bool {
        isVisible && !keyboardHandoff.isKeyboardAway(at: now)
    }

    /// The panel became key (the controller): after it stayed visible without the keyboard for Mail's reply
    /// window, the hand-off is over and the panel has the keyboard again (`keyboardDidReturn`).
    func panelDidBecomeKey() {
        let tookKeyboardBack = isVisible && keyboardHandoff.isPanelKeptVisible
        keyboardHandoff.panelDidBecomeKey()
        if tookKeyboardBack {
            keyboardDidReturn()
        }
    }
}

/// The tools announce a hand-off of the keyboard here (`create_mail_draft`
/// for a reply). Only while the panel is visible: a panel the user closed is
/// never brought back. A panel that stayed visible for a window that then did
/// not open closes.
extension PanelState: KeyboardHandoffAnnouncing {
    func beginKeyboardHandoff(to app: String) async -> UUID? {
        guard isVisible else { return nil }
        return keyboardHandoff.begin(to: app, now: Date())
    }

    func endKeyboardHandoff(_ handoff: UUID?, opened: Bool) async {
        guard let handoff else { return }
        if keyboardHandoff.end(handoff, opened: opened, now: Date()) {
            closePanelIfNotKey()
        }
    }
}
