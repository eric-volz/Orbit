import AppKit
import Quartz
import SwiftUI

/// The floating Spotlight-style window that hosts `RootView`.
///
/// Window style: **borderless** (plus `.nonactivatingPanel`) instead of a titled window with a
/// transparent title bar. A titled window keeps an invisible title bar strip at its top whose
/// drag and double-click behavior overlaps the 56 pt input row, and its corner radius and frame
/// border are dictated by the OS version. In a borderless panel the content view is an
/// `NSVisualEffectView` with a stretchable rounded-rect `maskImage`: that gives exact corners and
/// AppKit derives the window shadow from the mask (documented for a window's content view).
/// Borderless windows refuse key status by default, hence the `canBecomeKey` override; key
/// events then reach the SwiftUI text field while the frontmost app stays active.
///
/// The panel is the end of its views' responder chain, so the Quick Look panel asks it for a
/// controller; it hands the preview to `quickLook` while a file card wants one.
///
/// It follows macOS's display options (Accessibility > Display) as they change: with Reduce
/// Transparency an opaque window background replaces the material, with Increase Contrast its
/// edge is drawn clearly (`applyDisplayOptions`). The SwiftUI content follows them itself.
final class OrbitPanel: NSPanel {
    /// Called for Escape (`cancelOperation(_:)`) when no view in the panel handled it.
    var escapeHandler: (() -> Void)?
    /// Quick Look for the file cards in the panel.
    weak var quickLook: QuickLookController?
    /// What the panel shows of the display options now.
    private(set) var displayOptions = AccessibilityDisplayOptions()
    /// Covers the material with the window background color (Reduce Transparency).
    private let opaqueBackground = PanelOpaqueBackground()
    private let border: PanelBorderView
    private var displayOptionsObserver: (any NSObjectProtocol)?

    static var cornerRadius: CGFloat {
        if #available(macOS 26, *) { 20 } else { 14 }
    }

    init<Content: View>(rootView: Content) {
        border = PanelBorderView(frame: .zero, cornerRadius: Self.cornerRadius)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: PanelLayout.maximumWidth, height: PanelLayout.minimumHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        title = "Orbit"
        isFloatingPanel = true
        // Above floating windows of other apps; together with `.fullScreenAuxiliary` this also
        // covers full-screen apps. Menus and pop-ups (level 101) still appear above the panel.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .utilityWindow

        contentView = makeContentView(rootView: rootView)
        applyDisplayOptions(.current)
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyDisplayOptions(.current) }
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Reduce Transparency: an opaque background instead of the translucent material (the
    /// material may or may not turn opaque by itself; this does not depend on it). Increase
    /// Contrast: a clear edge instead of the hairline.
    func applyDisplayOptions(_ options: AccessibilityDisplayOptions) {
        displayOptions = options
        opaqueBackground.isHidden = !options.reduceTransparency
        border.increasedContrast = options.increaseContrast
    }

    /// Whether the panel's background is opaque now (tests).
    var hasOpaqueBackground: Bool { !opaqueBackground.isHidden }

    override func cancelOperation(_ sender: Any?) {
        escapeHandler?()
    }

    // MARK: Keys

    /// ⌘1 to ⌘9 open instant results on every keyboard layout: where the number row types other
    /// characters (AZERTY), its keys reach the views as the digits they stand for.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        super.performKeyEquivalent(with: CommandNumberKey.digitEvent(for: event) ?? event)
    }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(CommandNumberKey.digitEvent(for: event) ?? event)
    }

    // MARK: Quick Look

    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated {
            quickLook?.acceptsPreviewPanelControl(panel) ?? false
        }
    }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            quickLook?.beginPreviewPanelControl(panel)
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            quickLook?.endPreviewPanelControl(panel)
        }
    }

    // MARK: Content

    private func makeContentView<Content: View>(rootView: Content) -> NSView {
        let radius = Self.cornerRadius
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        // The app is never active while the panel is up; keep the material vibrant anyway.
        effectView.state = .active
        effectView.maskImage = Self.roundedMask(cornerRadius: radius)
        effectView.autoresizingMask = [.width, .height]

        // `maskImage` does not clip subviews, so the SwiftUI content gets its own rounded clip.
        let clipView = NSView(frame: effectView.bounds)
        clipView.wantsLayer = true
        clipView.layer?.cornerRadius = radius
        clipView.layer?.masksToBounds = true
        clipView.autoresizingMask = [.width, .height]

        // Below the content, inside the rounded clip: hidden unless Reduce Transparency is on.
        opaqueBackground.frame = clipView.bounds
        opaqueBackground.autoresizingMask = [.width, .height]
        opaqueBackground.isHidden = true
        clipView.addSubview(opaqueBackground)

        let hostingView = NSHostingView(rootView: rootView)
        // The controller owns the window size; SwiftUI must not add size constraints to it.
        hostingView.sizingOptions = []
        hostingView.frame = clipView.bounds
        hostingView.autoresizingMask = [.width, .height]
        clipView.addSubview(hostingView)
        effectView.addSubview(clipView)

        border.frame = effectView.bounds
        border.autoresizingMask = [.width, .height]
        effectView.addSubview(border)
        return effectView
    }

    /// A 9-slice rounded rectangle; `capInsets` keep the corners unstretched.
    static func roundedMask(cornerRadius radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The accessibility display options of macOS (System Settings > Accessibility > Display) that
/// Orbit's AppKit drawing follows; SwiftUI views read the same options from their environment.
struct AccessibilityDisplayOptions: Equatable, Sendable {
    var reduceMotion = false
    var reduceTransparency = false
    var increaseContrast = false
    var differentiateWithoutColor = false

    /// As macOS reports them now.
    @MainActor static var current: AccessibilityDisplayOptions {
        let workspace = NSWorkspace.shared
        return AccessibilityDisplayOptions(
            reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
            reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency,
            increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
            differentiateWithoutColor: workspace.accessibilityDisplayShouldDifferentiateWithoutColor
        )
    }
}

/// The window background color behind the panel's content: shown instead of the translucent
/// material while Reduce Transparency is on. Never takes mouse events.
private final class PanelOpaqueBackground: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// The hairline edge macOS draws around windows: light in Dark Mode (separates the panel from
/// dark backgrounds), a faint dark line in Light Mode; with Increase Contrast a clear line of a
/// full point. Never takes mouse events.
final class PanelBorderView: NSView {
    private let cornerRadius: CGFloat
    var increasedContrast = false {
        didSet { if increasedContrast != oldValue { needsDisplay = true } }
    }

    init(frame: NSRect, cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// The hairline is one device pixel wide; redraw when moving between screen scales.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    /// The edge's alpha (white in Dark Mode, black in Light Mode) and width in points.
    nonisolated static func edge(isDark: Bool, increasedContrast: Bool, backingScale: CGFloat) -> (alpha: CGFloat, width: CGFloat) {
        guard !increasedContrast else { return (isDark ? 0.6 : 0.5, 1) }
        return (isDark ? 0.16 : 0.08, 1 / max(backingScale, 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let edge = Self.edge(isDark: isDark, increasedContrast: increasedContrast, backingScale: window?.backingScaleFactor ?? 2)
        let color = (isDark ? NSColor.white : NSColor.black).withAlphaComponent(edge.alpha)
        let lineWidth = edge.width
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2),
            xRadius: cornerRadius - lineWidth / 2,
            yRadius: cornerRadius - lineWidth / 2
        )
        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()
    }
}
