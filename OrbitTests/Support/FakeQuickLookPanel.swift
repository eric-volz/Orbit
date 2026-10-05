import AppKit
@testable import Orbit

/// A Quick Look panel that only records what it was told; no window is ever
/// created or shown. `userClicks()`, `userShows(_:)`, `userMoves(by:)` and
/// `userCloses()` act like the user in the real panel, through the
/// controller's data-source and delegate methods.
@MainActor
final class FakeQuickLookPanel: QuickLookPanel {
    private weak var controller: QuickLookController?
    private(set) var isVisible = false
    /// Set by `userClicks()` (or directly by tests).
    var isKey = false
    private(set) var showCount = 0
    private(set) var showItemCount = 0
    /// How often the panel loaded the files from the controller.
    private(set) var itemLoads = 0
    private(set) var closeCount = 0
    /// The file the panel shows, as the controller told it last.
    private(set) var shownIndex: Int?
    /// The visible frame of the screen the panel was last shown on (Orbit's panel's).
    private(set) var shownOnScreen: CGRect?

    nonisolated init() {}

    func show(controller: QuickLookController) {
        self.controller = controller
        isVisible = true
        showCount += 1
        itemLoads += 1
        shownIndex = controller.preview?.index
        shownOnScreen = controller.hostScreenFrame()
    }

    func showItem(at index: Int, reloadingItems: Bool) {
        showItemCount += 1
        if reloadingItems { itemLoads += 1 }
        shownIndex = index
    }

    func close() {
        isVisible = false
        isKey = false
        closeCount += 1
    }

    // MARK: The user in the panel

    /// The files the panel would show, as its data source hands them out.
    var items: [URL] {
        guard let controller else { return [] }
        return (0..<controller.numberOfPreviewItems(in: nil)).compactMap {
            (controller.previewPanel(nil, previewItemAt: $0) as? NSURL) as URL?
        }
    }

    /// A click into the preview makes it key.
    func userClicks() {
        isKey = true
        controller?.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
    }

    /// The panel's own navigation shows another file.
    func userShows(_ index: Int) {
        shownIndex = index
        controller?.panelDidShowItem(at: index)
    }

    /// ↑ or ↓ pressed while the preview has the keyboard, `abs(delta)` times.
    func userMoves(by delta: Int) {
        let (keyCode, characters): (UInt16, String) = delta > 0 ? (125, "\u{F701}") : (126, "\u{F700}")
        for _ in 0..<abs(delta) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad],
                                               timestamp: 0, windowNumber: 0, context: nil, characters: characters,
                                               charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
            else { continue }
            _ = controller?.previewPanel(nil, handle: event)
        }
    }

    /// The close button, or Space or Escape in the panel.
    func userCloses() {
        isVisible = false
        isKey = false
        controller?.windowWillClose(Notification(name: NSWindow.willCloseNotification))
    }
}
