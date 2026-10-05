import AppKit
import Observation
import Quartz

/// Where the panel goes on a screen. Pure geometry in AppKit screen coordinates (origin
/// bottom-left), so it is unit-tested without windows.
struct PanelLayout: Equatable, Sendable {
    static let maximumWidth: CGFloat = 720
    /// Minimum distance between the panel and the left/right screen edges.
    static let horizontalMargin: CGFloat = 32
    static let minimumHeight: CGFloat = 56
    /// The top edge sits this fraction of the visible height below the top of the screen.
    static let topOffsetFraction: CGFloat = 0.22
    /// The panel never grows taller than this fraction of the visible height.
    static let maximumHeightFraction: CGFloat = 0.7

    /// `NSScreen.visibleFrame` of the screen the panel is shown on.
    let visibleFrame: CGRect

    var width: CGFloat {
        let fitting = visibleFrame.width - 2 * Self.horizontalMargin
        return max(min(Self.maximumWidth, fitting), min(visibleFrame.width, 320)).rounded(.down)
    }

    var maximumHeight: CGFloat {
        max(Self.minimumHeight, (visibleFrame.height * Self.maximumHeightFraction).rounded(.down))
    }

    /// Fixed while the panel is visible: the panel grows and shrinks downward.
    var topEdge: CGFloat {
        (visibleFrame.maxY - visibleFrame.height * Self.topOffsetFraction).rounded()
    }

    func height(forPreferredHeight preferred: CGFloat) -> CGFloat {
        guard preferred.isFinite else { return Self.minimumHeight }
        return min(max(preferred.rounded(.up), Self.minimumHeight), maximumHeight)
    }

    func frame(forPreferredHeight preferred: CGFloat) -> CGRect {
        let height = height(forPreferredHeight: preferred)
        let x = (visibleFrame.midX - width / 2).rounded()
        return CGRect(x: x, y: topEdge - height, width: width, height: height)
    }

    /// Index of the screen frame containing `point` (the mouse location), nil if none does.
    /// Edges count as inside like `NSMouseInRect` does for the bottom-left origin.
    static func indexOfScreen(containing point: CGPoint, screenFrames: [CGRect]) -> Int? {
        screenFrames.firstIndex { frame in
            point.x >= frame.minX && point.x < frame.maxX && point.y > frame.minY && point.y <= frame.maxY
        }
    }

    /// A step of the resize animation: eased (cubic ease-out), on whole points, and anchored
    /// at the target's top edge so the panel only ever moves its bottom edge.
    static func interpolatedFrame(from start: CGRect, to target: CGRect, progress: Double) -> CGRect {
        let linear = min(max(progress, 0), 1)
        let eased = CGFloat(1 - pow(1 - linear, 3))
        let height = (start.height + (target.height - start.height) * eased).rounded()
        let width = (start.width + (target.width - start.width) * eased).rounded()
        let x = (start.minX + (target.minX - start.minX) * eased).rounded()
        return CGRect(x: x, y: target.maxY - height, width: width, height: height)
    }
}

/// Animates the panel frame. Driven by a run loop timer rather than the display link behind
/// `NSAnimationContext`: that one stalls while the display sleeps (e.g. during a long streamed
/// answer), and a stalled animation could later resume towards an outdated height. A new
/// target retargets the running animation from the current frame. With Reduce Motion the
/// panel takes its new height at once.
@MainActor
final class PanelFrameAnimator {
    static let duration: CFTimeInterval = 0.16

    /// Whether macOS asks to reduce motion (Accessibility > Display), read for every change.
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private weak var window: NSWindow?
    private var timer: Timer?
    private var start = CGRect.zero
    private var target = CGRect.zero
    private var startTime: CFTimeInterval = 0

    init(window: NSWindow) {
        self.window = window
    }

    var isAnimating: Bool { timer != nil }

    func animate(to frame: CGRect) {
        guard let window else { return }
        guard !reducesMotion() else {
            jump(to: frame)
            return
        }
        start = window.frame
        target = frame
        startTime = CACurrentMediaTime()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            // Scheduled on the main run loop below.
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops any animation and sets the frame immediately.
    func jump(to frame: CGRect) {
        stop()
        window?.setFrame(frame, display: window?.isVisible ?? false)
    }

    /// Completes a running animation immediately.
    func finish() {
        guard isAnimating else { return }
        jump(to: target)
    }

    private func step() {
        guard let window else {
            stop()
            return
        }
        let progress = (CACurrentMediaTime() - startTime) / Self.duration
        window.setFrame(PanelLayout.interpolatedFrame(from: start, to: target, progress: progress), display: true)
        if progress >= 1 {
            stop()
        }
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// Owns the Orbit panel: shows it on the active screen without activating Orbit, hides it on
/// Escape or when the user clicks elsewhere, and resizes it downward when the SwiftUI content
/// asks for a new height (`PanelState.preferredContentHeight`). Hiding keeps the content alive,
/// so the chat is still there when the panel comes back. A Quick Look preview opened from a
/// file card belongs to the panel: it keeps the panel up while it has the keyboard, closes
/// when the panel hides, and hands the keyboard back when it closes. When Orbit itself hands
/// the keyboard to Mail's reply window (`PanelState.keyboardHandoff`), the panel stays visible
/// without the keyboard until the next click outside, the hotkey, or another app coming to
/// the front.
@MainActor
final class PanelController: NSObject, NSWindowDelegate {
    let panel: OrbitPanel
    /// Whether a window of this process is one of Orbit's own (in the app, all of them). A
    /// test lets an offscreen window stand in for another app's window, which Orbit never sees.
    var isOrbitWindow: (NSWindow) -> Bool = { _ in true }

    private let environment: AppEnvironment
    /// Layout of the screen the panel was last shown on.
    private var layout: PanelLayout?
    /// The frame the panel is animating (or animated) to.
    private var targetFrame: CGRect?
    private let frameAnimator: PanelFrameAnimator
    private var outsideClickMonitor: Any?
    private var appActivationObserver: (any NSObjectProtocol)?

    private var panelState: PanelState { environment.panelState }
    private var quickLook: QuickLookController { environment.quickLook }

    init(environment: AppEnvironment, openSettings: @escaping @MainActor (SettingsTab?) -> Void) {
        self.environment = environment
        panel = OrbitPanel(rootView: RootView(environment: environment))
        frameAnimator = PanelFrameAnimator(window: panel)
        super.init()
        panel.delegate = self
        panel.escapeHandler = { [weak environment] in environment?.handleEscape() }
        panel.quickLook = environment.quickLook
        environment.panelState.closePanel = { [weak self] in self?.hide() }
        environment.panelState.closePanelIfNotKey = { [weak self] in self?.hideIfNotKey() }
        environment.panelState.openSettings = { tab in openSettings(tab) }
        environment.quickLook.didClose = { [weak self] panelHadKeyboard in
            self?.previewDidClose(panelHadKeyboard: panelHadKeyboard)
        }
        // The preview appears on the screen of the panel, not where it was last.
        environment.quickLook.hostScreenFrame = { [weak panel] in
            (panel?.screen ?? Self.activeScreen())?.visibleFrame
        }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screenParametersDidChange(_:)),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDidHide(_:)),
                           name: NSApplication.didHideNotification, object: nil)
        center.addObserver(self, selector: #selector(applicationDidResignActive(_:)),
                           name: NSApplication.didResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(anyWindowDidBecomeKey(_:)),
                           name: NSWindow.didBecomeKeyNotification, object: nil)
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleIdentifier = app?.bundleIdentifier
            let processIdentifier = app?.processIdentifier ?? 0
            MainActor.assumeIsolated {
                self?.applicationDidActivate(bundleIdentifier: bundleIdentifier, processIdentifier: processIdentifier)
            }
        }
        observePreferredContentHeight()
    }

    // MARK: Show / hide

    /// Shows the panel on the screen with the mouse pointer and makes it key without
    /// activating Orbit: the frontmost app stays frontmost. `capturingContext`: the user
    /// opened it (hotkey or menu), so the selection of the app they came from becomes the
    /// context chips (`ContextCapture`), not when Orbit shows the panel itself.
    func show(capturingContext: Bool = false) {
        let started = ContinuousClock.now
        guard let screen = Self.activeScreen() else {
            Log.panel.error("No screen to show the panel on")
            return
        }
        let wasVisible = panelState.isVisible
        let layout = PanelLayout(visibleFrame: screen.visibleFrame)
        self.layout = layout
        panelState.maximumContentHeight = layout.maximumHeight
        var frame = layout.frame(forPreferredHeight: panelState.preferredContentHeight)
        frameAnimator.jump(to: frame)  // no animation when the panel appears
        if !panelState.isVisible {
            if capturingContext {
                // Before the panel appears; the capture finishes after it (the chips follow).
                environment.contextCapture.panelOpened()
            }
            // After a pause Orbit opens in search mode (ChatParking). The content is laid out
            // for it now (SwiftUI measures synchronously), so the panel appears at its height.
            environment.chatParking.panelWillAppear()
            panel.contentView?.layoutSubtreeIfNeeded()
            frame = layout.frame(forPreferredHeight: panelState.preferredContentHeight)
            frameAnimator.jump(to: frame)
        }
        targetFrame = frame

        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }
        panel.orderFrontRegardless()
        panel.makeKey()
        // Shown with the keyboard: a card that waits is read again, with its keys (`PanelState.keyboardDidReturn`).
        panelState.isVisible = true
        panelState.showCount += 1
        installOutsideClickMonitor()
        Log.panel.debug("Panel shown (height \(frame.height, privacy: .public))")
        guard !wasVisible else { return }
        // The next turn of the run loop comes after the first frame was committed: how long the
        // panel took to appear (target ≈ 50 ms from the hotkey).
        DispatchQueue.main.async {
            let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
            Log.panel.info("Panel appeared in \(milliseconds, privacy: .public) ms")
        }
    }

    /// Orders the panel out. The SwiftUI content stays alive (never rebuilt).
    ///
    /// When Orbit itself became the active app (e.g. it was launched again from
    /// Finder or Spotlight) and no other Orbit window is open, it hides the app
    /// too, so the previous app gets the keyboard back. `yieldFocus: false` for
    /// callers that activate Orbit themselves (Settings, About).
    func hide(yieldFocus: Bool = true) {
        removeOutsideClickMonitor()
        // A hand-off of the keyboard never brings a closed panel back.
        panelState.keyboardHandoff.reset()
        frameAnimator.finish()
        let wasVisible = panel.isVisible || panelState.isVisible
        if wasVisible {
            panel.orderOut(nil)
            panelState.isVisible = false
            environment.chatParking.panelDidHide()
            environment.contextCapture.panelClosed()
        }
        // A preview opened from the panel closes with it, before the check below, which
        // looks for other visible windows.
        quickLook.close()
        guard wasVisible else { return }
        Log.panel.debug("Panel hidden")
        if yieldFocus, NSApp.isActive,
           !NSApp.windows.contains(where: { $0 !== panel && $0.isVisible && $0.canBecomeKey }) {
            NSApp.hide(nil)
        }
    }

    /// Hotkey behavior: hide when the panel (or its Quick Look preview) is up and focused,
    /// otherwise bring it up; the user opens it, so with the context chips.
    func toggle() {
        if panel.isVisible && (panel.isKeyWindow || quickLook.hasKeyboard) {
            hide()
        } else {
            show(capturingContext: true)
        }
    }

    // MARK: Height

    /// Re-armed after every change: `withObservationTracking` reports one change per call.
    private func observePreferredContentHeight() {
        withObservationTracking {
            _ = panelState.preferredContentHeight
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyPreferredContentHeight()
                self.observePreferredContentHeight()
            }
        }
    }

    /// Resizes to the preferred height with the top edge fixed; animated while visible.
    private func applyPreferredContentHeight() {
        guard let layout else { return }  // not shown yet: show() sizes the panel
        let frame = layout.frame(forPreferredHeight: panelState.preferredContentHeight)
        guard frame != targetFrame else { return }
        targetFrame = frame
        if panel.isVisible {
            frameAnimator.animate(to: frame)
        } else {
            frameAnimator.jump(to: frame)
        }
    }

    // MARK: Closing when focus moves elsewhere

    func windowDidResignKey(_ notification: Notification) {
        // AppKit assigns the new key window after this callback returns.
        Task { @MainActor [weak self] in
            self?.hideIfFocusLeftPanel()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        quickLook.syncWithPanel()
        // A click into the panel (or the hotkey) after Orbit handed the keyboard to Mail: a card that waits is
        // read again, with its keys.
        panelState.panelDidBecomeKey()
    }

    private func hideIfFocusLeftPanel() {
        guard panel.isVisible, !panel.isKeyWindow else { return }
        let focus: KeyboardFocus = NSApp.keyWindow.flatMap { isOrbitWindow($0) ? $0 : nil }
            .map { belongsToPanel($0) ? .panel : .otherWindow } ?? .noWindow
        let isHandingOff = focus == .noWindow && panelState.keyboardHandoff.isHandingOff(at: Date())
        guard !Self.staysUp(afterKeyboardMovedTo: focus, isPreviewVisible: quickLook.isVisible,
                            isAppActive: NSApp.isActive, isHandingOffKeyboard: isHandingOff) else {
            if isHandingOff {
                keepVisibleForHandoff()
            }
            return
        }
        hide()
    }

    /// Mail's reply window took the keyboard from the panel on Orbit's behalf: the panel stays
    /// visible without it, so the reply's card (the text is on the clipboard) stays in view.
    private func keepVisibleForHandoff() {
        panelState.keyboardHandoff.keepPanelVisible()
        Log.panel.info("Panel stays visible without the keyboard: Orbit handed it to another app's window")
    }

    /// The panel stayed visible without the keyboard for a window that did not open after all:
    /// it closes as the focus loss would have closed it.
    private func hideIfNotKey() {
        guard panel.isVisible, !panel.isKeyWindow else { return }
        hide()
    }

    /// Where the keyboard went when the panel lost it.
    enum KeyboardFocus: Sendable {
        /// The panel or a window that belongs to it (see `belongsToPanel`).
        case panel
        /// Another window of Orbit, e.g. Settings or the About panel.
        case otherWindow
        /// No window of Orbit (another app has the keyboard, or none has it yet).
        case noWindow
    }

    /// Whether the panel stays up after the keyboard moved. A click into the Quick Look
    /// preview activates Orbit before the preview becomes key, so while a preview is visible
    /// and Orbit is active, "no window yet" keeps the panel. So does another app's window
    /// while Orbit hands the keyboard to it (`KeyboardHandoff`). Any other window (also
    /// another Orbit window such as Settings) closes it, like a click into another app does.
    nonisolated static func staysUp(afterKeyboardMovedTo focus: KeyboardFocus, isPreviewVisible: Bool,
                                    isAppActive: Bool, isHandingOffKeyboard: Bool = false) -> Bool {
        switch focus {
        case .panel: true
        case .otherWindow: false
        case .noWindow: (isPreviewVisible && isAppActive) || isHandingOffKeyboard
        }
    }

    /// After the preview had the keyboard, the panel takes it back (the card that was
    /// previewed refocuses itself).
    private func previewDidClose(panelHadKeyboard: Bool) {
        guard panelHadKeyboard, panel.isVisible, !panel.isKeyWindow else { return }
        panel.makeKey()
    }

    /// Sheets, popovers and child windows of the panel, and Quick Look previews opened from
    /// it, are part of the panel's interaction and do not close it.
    private func belongsToPanel(_ window: NSWindow) -> Bool {
        if window is QLPreviewPanel { return true }
        var current: NSWindow? = window
        while let candidate = current {
            if candidate === panel { return true }
            current = candidate.parent ?? candidate.sheetParent
        }
        return false
    }

    /// Clicks in other apps never reach our windows; this monitor sees them (including the
    /// Dock and the menu bar, which do not take key status). Mouse monitoring needs no
    /// Accessibility permission.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.mouseDownOutsideOrbit(at: NSEvent.mouseLocation)
        }
    }

    /// A click in another app (seen by the monitor) closes the panel, also while it stays
    /// visible for Mail's reply window, unless it hit the panel or the system's text input.
    func mouseDownOutsideOrbit(at location: CGPoint) {
        guard panel.isVisible, !panel.frame.contains(location), !Self.isTextInputWindow(at: location) else { return }
        hide()
    }

    /// Whether the window under `location` belongs to the text-input UI of the
    /// system (emoji picker, input-method candidates, AutoFill, Writing Tools):
    /// those windows serve the panel's text field. Reading the owner needs no
    /// Screen Recording permission.
    private static func isTextInputWindow(at location: CGPoint) -> Bool {
        let number = NSWindow.windowNumber(at: location, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]])?.first,
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let owner = NSRunningApplication(processIdentifier: pid) else { return false }
        return isTextInputHelper(bundleIdentifier: owner.bundleIdentifier, bundlePath: owner.bundleURL?.path)
    }

    nonisolated static func isTextInputHelper(bundleIdentifier: String?, bundlePath: String?) -> Bool {
        if let path = bundlePath, path.hasPrefix("/System/Library/Input Methods/") { return true }
        guard let identifier = bundleIdentifier?.lowercased() else { return false }
        let markers = ["com.apple.inputmethod.", "com.apple.charactersetpalette", "com.apple.characterpaletteim",
                       "com.apple.textinputui", "com.apple.textinputmenuagent", "com.apple.pressandhold",
                       "autofill", "writingtools", "com.apple.inputmethodkit"]
        return markers.contains { identifier.hasPrefix($0) || identifier.contains($0) }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    // MARK: System events

    @objc private func screenParametersDidChange(_ notification: Notification) {
        // Only a panel `show()` placed (tests keep theirs offscreen).
        guard panel.isVisible, layout != nil else { return }
        guard let screen = panel.screen ?? Self.activeScreen() else { return }
        let layout = PanelLayout(visibleFrame: screen.visibleFrame)
        self.layout = layout
        panelState.maximumContentHeight = layout.maximumHeight
        let frame = layout.frame(forPreferredHeight: panelState.preferredContentHeight)
        targetFrame = frame
        frameAnimator.jump(to: frame)
    }

    /// "Hide Orbit" (⌘H) hides all windows; keep the panel state in sync.
    @objc private func applicationDidHide(_ notification: Notification) {
        hide()
    }

    /// Orbit is active only while the user works in one of its windows, e.g. after
    /// clicking the Quick Look preview. Switching to another app then closes the panel and
    /// the preview, like a click outside does.
    @objc private func applicationDidResignActive(_ notification: Notification) {
        guard panel.isVisible, !panel.isKeyWindow else { return }
        if panelState.keyboardHandoff.isHandingOff(at: Date()) {
            keepVisibleForHandoff()
            return
        }
        hide(yieldFocus: false)
    }

    /// Another app came to the front while the panel stays visible for Mail's reply window: it
    /// closes like after a click outside (Mail itself and Orbit do not close it). While the
    /// reply window is still opening, such an app ends the hand-off: the panel closes when it
    /// loses the keyboard (or now, when it already lost it), as after any focus change.
    func applicationDidActivate(bundleIdentifier: String?, processIdentifier: pid_t) {
        let isOrbit = processIdentifier == ProcessInfo.processInfo.processIdentifier
        guard panelState.keyboardHandoff.appDidActivate(bundleIdentifier, isOrbit: isOrbit),
              panel.isVisible, !panel.isKeyWindow else { return }
        hide(yieldFocus: false)
    }

    /// Another Orbit window took the keyboard (Settings, the About panel) while the panel is
    /// up: it closes with its preview, like after a click into another app. This also covers
    /// the preview having had the keyboard, when the panel itself never resigns key.
    @objc private func anyWindowDidBecomeKey(_ notification: Notification) {
        // `panelState.isVisible` follows the panel's `isVisible` (show and hide set both).
        guard panelState.isVisible, let window = notification.object as? NSWindow, isOrbitWindow(window),
              !belongsToPanel(window) else { return }
        hide()
    }

    /// The screen with the mouse pointer, else the main screen.
    static func activeScreen() -> NSScreen? {
        let screens = NSScreen.screens
        if let index = PanelLayout.indexOfScreen(containing: NSEvent.mouseLocation, screenFrames: screens.map(\.frame)) {
            return screens[index]
        }
        return NSScreen.main ?? screens.first
    }
}
