import AppKit
import Observation
import Quartz

/// The system's Quick Look panel as `QuickLookController` drives it. Live: the
/// shared `QLPreviewPanel` (`LiveQuickLookPanel`); tests use a fake, so they
/// never show a window.
@MainActor
protocol QuickLookPanel: Sendable {
    /// Whether the panel is on screen.
    var isVisible: Bool { get }
    /// Whether the panel has the keyboard (the user clicked into it).
    var isKey: Bool { get }
    /// Shows `controller`'s preview above Orbit's panel; Orbit's panel keeps
    /// the keyboard. The panel finds its controller through the responder chain.
    func show(controller: QuickLookController)
    /// Shows another file of the preview; `reloadingItems` when the files changed.
    func showItem(at index: Int, reloadingItems: Bool)
    func close()
}

/// Quick Look for file cards: shows a card's files in the system's preview
/// panel, starting at its selected row, as the panel's data source and
/// delegate. Card and panel stay in step: moving the card's selection shows
/// another file, and moving in the panel (↑/↓ while it has the keyboard, or its
/// own controls) moves the card's selection. Escape closes the preview before
/// anything else; hiding Orbit's panel closes it too.
///
/// The panel looks for its controller in the responder chain: `OrbitPanel`
/// (and, as fallbacks, the app delegate and this object as the panel's
/// delegate, for when the preview itself is the key window) hands it here.
@MainActor
@Observable
final class QuickLookController: NSObject {
    /// The files of one card and the one shown.
    struct Preview: Equatable, Sendable {
        /// The chat item of the card.
        var source: UUID
        var urls: [URL]
        var index: Int
    }

    /// Asks the card that was previewed to take the keyboard back.
    struct FocusReturn: Equatable, Sendable {
        var source: UUID
        var count: Int
    }

    /// What the panel shows; nil once it closed.
    private(set) var preview: Preview?
    /// Set when a preview closed while the Quick Look panel had the keyboard.
    private(set) var focusReturn: FocusReturn?

    /// Called after a preview closed, with whether the Quick Look panel had the
    /// keyboard (the panel controller then makes Orbit's panel key again).
    @ObservationIgnored var didClose: (_ panelHadKeyboard: Bool) -> Void = { _ in }
    /// The visible frame of the screen Orbit's panel is on: the preview
    /// appears there (set by the panel controller).
    @ObservationIgnored var hostScreenFrame: () -> CGRect? = { nil }
    @ObservationIgnored let panel: any QuickLookPanel
    /// begin/end calls can interleave when control moves between responders.
    @ObservationIgnored private var controlDepth = 0
    /// Whether the panel became key since it was shown.
    @ObservationIgnored private var panelHadKeyboard = false
    @ObservationIgnored private var indexObservation: NSKeyValueObservation?

    init(panel: any QuickLookPanel) {
        self.panel = panel
        super.init()
    }

    /// Whether a preview is on screen.
    var isVisible: Bool {
        preview != nil && panel.isVisible
    }

    /// Whether the Quick Look panel is on screen and has the keyboard.
    var hasKeyboard: Bool {
        isVisible && panel.isKey
    }

    /// Whether the card `source` is being previewed.
    func isPreviewing(_ source: UUID) -> Bool {
        isVisible && preview?.source == source
    }

    /// Space in a card: previews its files from `index`, or closes the preview
    /// when it shows this card already.
    func toggle(source: UUID, urls: [URL], index: Int) {
        if isPreviewing(source) {
            close()
        } else {
            show(source: source, urls: urls, index: index)
        }
    }

    /// Previews `urls` from `index`; replaces the preview of another card.
    func show(source: UUID, urls: [URL], index: Int) {
        guard !urls.isEmpty else { return }
        let wasVisible = isVisible
        let previousURLs = preview?.urls
        let clamped = min(max(index, 0), urls.count - 1)
        preview = Preview(source: source, urls: urls, index: clamped)
        if wasVisible {
            panel.showItem(at: clamped, reloadingItems: previousURLs != urls)
        } else {
            panelHadKeyboard = false
            panel.show(controller: self)
        }
        Log.panel.debug("Quick Look shows \(urls.count, privacy: .public) files")
    }

    /// The card's selection moved: the preview follows (only the previewed card's).
    func follow(index: Int, in source: UUID) {
        guard var preview, preview.source == source, preview.urls.indices.contains(index), preview.index != index else {
            return
        }
        preview.index = index
        self.preview = preview
        panel.showItem(at: index, reloadingItems: false)
    }

    /// Closes the preview. Returns whether one was on screen.
    @discardableResult
    func close() -> Bool {
        let isOnScreen = panel.isVisible
        guard preview != nil || isOnScreen else { return false }
        let hadKeyboard = isOnScreen && panel.isKey
        if isOnScreen {
            panel.close()
        }
        finish(hadKeyboard: hadKeyboard)
        return isOnScreen
    }

    /// Forgets a preview whose panel closed without telling.
    func syncWithPanel() {
        if preview != nil, !panel.isVisible {
            finish(hadKeyboard: false)
        }
    }

    // MARK: Events from the panel

    /// The panel shows another file (its own navigation).
    func panelDidShowItem(at index: Int) {
        guard var preview, preview.urls.indices.contains(index), preview.index != index else { return }
        preview.index = index
        self.preview = preview
    }

    /// ↑/↓ while the panel has the keyboard: moves the preview and with it the
    /// card's selection. Stops at the first and last file.
    func panelDidRequestMove(by delta: Int) {
        guard var preview else { return }
        let index = min(max(preview.index + delta, 0), preview.urls.count - 1)
        guard index != preview.index else { return }
        preview.index = index
        self.preview = preview
        panel.showItem(at: index, reloadingItems: false)
    }

    /// The panel closed itself (its close button, or Space or Escape in it).
    func panelDidClose(hadKeyboard: Bool) {
        guard preview != nil else { return }
        finish(hadKeyboard: hadKeyboard)
    }

    private func finish(hadKeyboard: Bool) {
        let source = preview?.source
        preview = nil
        panelHadKeyboard = false
        if hadKeyboard, let source {
            focusReturn = FocusReturn(source: source, count: (focusReturn?.count ?? 0) + 1)
        }
        didClose(hadKeyboard)
    }

    // MARK: Items

    var itemCount: Int {
        preview?.urls.count ?? 0
    }

    func url(at index: Int) -> URL? {
        guard let urls = preview?.urls, urls.indices.contains(index) else { return nil }
        return urls[index]
    }

    // MARK: Control through the responder chain

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated {
            preview != nil
        }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            beginControl(panel)
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            endControl(panel)
        }
    }

    private func beginControl(_ panel: QLPreviewPanel?) {
        controlDepth += 1
        guard let panel else { return }
        panel.dataSource = self
        panel.delegate = self
        LiveQuickLookPanel.arrange(panel)
        indexObservation = panel.observe(\.currentPreviewItemIndex, options: [.new]) { [weak self] _, change in
            guard let index = change.newValue else { return }
            MainActor.assumeIsolated {
                self?.panelDidShowItem(at: index)
            }
        }
    }

    private func endControl(_ panel: QLPreviewPanel?) {
        controlDepth = max(0, controlDepth - 1)
        guard controlDepth == 0 else { return }
        indexObservation = nil
        if let panel {
            if panel.dataSource.map({ $0 === self }) ?? false { panel.dataSource = nil }
            if (panel.delegate as AnyObject?) === self { panel.delegate = nil }
        }
        // The panel gives up its controller when it closes, also by itself.
        let hadKeyboard = panelHadKeyboard
        Task { @MainActor [weak self] in
            guard let self, !self.panel.isVisible else { return }
            self.panelDidClose(hadKeyboard: hadKeyboard)
        }
    }
}

extension QuickLookController: QLPreviewPanelDataSource {
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            itemCount
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url = MainActor.assumeIsolated {
            self.url(at: index)
        }
        return url.map { $0 as NSURL }
    }
}

extension QuickLookController: QLPreviewPanelDelegate {
    /// ↑/↓ in the panel move the card's selection, like in Finder; the panel
    /// handles everything else itself (Space and Escape close it).
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown,
              let delta = QuickLookKeys.selectionMove(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
            return false
        }
        MainActor.assumeIsolated {
            panelDidRequestMove(by: delta)
        }
        return true
    }

    /// No zoom from the row: the panel fades in and out.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        .zero
    }

    func windowDidBecomeKey(_ notification: Notification) {
        panelHadKeyboard = true
    }

    func windowWillClose(_ notification: Notification) {
        panelDidClose(hadKeyboard: panelHadKeyboard)
    }
}

/// How keys pressed in the Quick Look panel map to the card: ↑/↓ move the
/// selection (like in Finder); everything else stays with the panel.
enum QuickLookKeys {
    /// The selection change for a key press in the panel, or nil when the
    /// panel handles the key itself.
    static func selectionMove(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Int? {
        guard modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return nil }
        switch keyCode {
        case 125: return 1  // ↓
        case 126: return -1  // ↑
        default: return nil
        }
    }
}

/// The shared `QLPreviewPanel`, raised above Orbit's panel (which floats at
/// `.statusBar`) and shown on every Space and over full-screen apps, on the
/// screen of Orbit's panel. It is ordered front without becoming key, so the
/// file card keeps the keyboard. The panel is created on first use.
struct LiveQuickLookPanel: QuickLookPanel {
    /// Just above Orbit's panel.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    /// The preview's size when it has none yet.
    nonisolated static let defaultSize = CGSize(width: 800, height: 500)
    /// Distance to the edges of the screen's visible area when the preview is centered there.
    nonisolated static let screenMargin: CGFloat = 20

    private var existingPanel: QLPreviewPanel? {
        QLPreviewPanel.sharedPreviewPanelExists() ? QLPreviewPanel.shared() : nil
    }

    var isVisible: Bool {
        existingPanel?.isVisible ?? false
    }

    var isKey: Bool {
        existingPanel?.isKeyWindow ?? false
    }

    func show(controller: QuickLookController) {
        guard let panel = QLPreviewPanel.shared() else { return }
        Self.arrange(panel)
        // Orbit's panel is the key window, so the search through its responder
        // chain ends at OrbitPanel, which hands the panel to the controller.
        panel.updateController()
        if !(panel.dataSource.map { $0 === controller } ?? false) {
            Log.panel.notice("Quick Look found no controller in the responder chain; using the preview directly")
            panel.dataSource = controller
            panel.delegate = controller
        }
        panel.reloadData()
        panel.currentPreviewItemIndex = controller.preview?.index ?? 0
        // Every time: the preview remembers its last frame, which may be on another screen.
        let screen = controller.hostScreenFrame()
        Self.place(panel, onScreenWith: screen)
        panel.orderFrontRegardless()
        Self.arrange(panel)
        Self.place(panel, onScreenWith: screen)
    }

    private static func place(_ panel: QLPreviewPanel, onScreenWith visibleFrame: CGRect?) {
        guard let visibleFrame else { return }
        let frame = frame(for: panel.frame, onScreenWith: visibleFrame)
        if frame != panel.frame {
            panel.setFrame(frame, display: panel.isVisible)
        }
    }

    /// Where the preview appears on the screen of Orbit's panel (`visibleFrame`,
    /// AppKit coordinates): where it was last (`current`) when that lies
    /// within this screen (the user may have moved or resized it), otherwise
    /// centered there at its size, made to fit.
    nonisolated static func frame(for current: CGRect, onScreenWith visibleFrame: CGRect) -> CGRect {
        if current.width >= 1, current.height >= 1, visibleFrame.contains(current) {
            return current
        }
        let size = current.width >= 1 && current.height >= 1 ? current.size : defaultSize
        let width = min(size.width, max(visibleFrame.width - 2 * screenMargin, 1)).rounded(.down)
        let height = min(size.height, max(visibleFrame.height - 2 * screenMargin, 1)).rounded(.down)
        return CGRect(x: (visibleFrame.midX - width / 2).rounded(), y: (visibleFrame.midY - height / 2).rounded(),
                      width: width, height: height)
    }

    func showItem(at index: Int, reloadingItems: Bool) {
        guard let panel = existingPanel, panel.isVisible else { return }
        if reloadingItems {
            panel.reloadData()
        }
        if panel.currentPreviewItemIndex != index {
            panel.currentPreviewItemIndex = index
        }
    }

    func close() {
        guard let panel = existingPanel, panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Above Orbit's panel, on the Space (or full-screen app) Orbit is shown on.
    static func arrange(_ panel: QLPreviewPanel) {
        if panel.level != level {
            panel.level = level
        }
        panel.collectionBehavior.insert(.fullScreenAuxiliary)
        panel.hidesOnDeactivate = false
    }
}
