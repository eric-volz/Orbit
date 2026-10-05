import AppKit

/// A panel far away from every screen that can become key, for tests that
/// drive views with key events. Borderless like Orbit's own panel: AppKit
/// moves titled windows onto a screen when they are created or ordered front,
/// borderless ones stay where they are. It refuses to be ordered front
/// anywhere a screen could show it.
@MainActor
final class OffscreenKeyPanel: NSPanel {
    static let origin = CGPoint(x: -20_000, y: -20_000)

    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: Self.origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
    }

    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Whether the panel is off every screen.
    var isOffscreen: Bool {
        NSScreen.screens.allSatisfy { !$0.frame.intersects(frame) }
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        precondition(isOffscreen, "a test panel would appear on the screen")
        super.makeKeyAndOrderFront(sender)
    }

    override func orderFront(_ sender: Any?) {
        precondition(isOffscreen, "a test panel would appear on the screen")
        super.orderFront(sender)
    }

    override func orderFrontRegardless() {
        precondition(isOffscreen, "a test panel would appear on the screen")
        super.orderFrontRegardless()
    }
}
