import AppKit
import Testing
@testable import Orbit

extension UIWindowTests {
    /// How the panel and Escape treat a Quick Look preview. Nothing is shown: the
    /// preview is a fake and the Orbit panel is never ordered front. Opt-in with
    /// the other UI tests: `SnapshotEnvironment` sets process-wide ORBIT_DEBUG_*
    /// variables that parallel suites would see.
    ///
    ///     ORBIT_UI_TESTS=1 Scripts/swiftpm.sh test --filter PanelQuickLook
    @Suite("PanelQuickLook", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_UI_TESTS"] == "1"))
    @MainActor
    struct PanelQuickLookTests {
        private let urls = ["Rechnung-1.pdf", "Rechnung-2.pdf"].map { URL(fileURLWithPath: "/Users/orbit-test/Documents/\($0)") }

        private func makeEnvironment() -> (AppEnvironment, FakeQuickLookPanel) {
            _ = NSApplication.shared
            let panel = FakeQuickLookPanel()
            return (SnapshotEnvironment.make(services: .fake(quickLookPanel: panel)), panel)
        }

        @Test func escapeClosesThePreviewBeforeThePanel() {
            let (environment, preview) = makeEnvironment()
            var closes = 0
            environment.panelState.closePanel = { closes += 1 }
            environment.quickLook.show(source: UUID(), urls: urls, index: 0)

            environment.handleEscape()
            #expect(!preview.isVisible)
            #expect(closes == 0)
            environment.handleEscape()
            #expect(closes == 1)
        }

        @Test func escapeClosesThePreviewBeforeStoppingAnAnswer() async {
            let (environment, preview) = makeEnvironment()
            environment.agentLoop.send("Hallo")
            #expect(environment.agentLoop.isRunning)
            environment.quickLook.show(source: UUID(), urls: urls, index: 0)

            environment.handleEscape()
            #expect(!preview.isVisible)
            #expect(environment.agentLoop.isRunning, "the answer keeps running")
            environment.handleEscape()
            #expect(!environment.agentLoop.isRunning)
        }

        @Test func aNewChatClosesThePreview() {
            let (environment, preview) = makeEnvironment()
            environment.quickLook.show(source: UUID(), urls: urls, index: 1)
            environment.startNewChat()
            #expect(!preview.isVisible)
            #expect(environment.quickLook.preview == nil)
        }

        @Test func hidingThePanelClosesThePreview() {
            let (environment, preview) = makeEnvironment()
            let controller = PanelController(environment: environment, openSettings: { _ in })
            #expect(controller.panel.quickLook === environment.quickLook, "the panel hands the preview to the controller")
            environment.panelState.isVisible = true
            environment.quickLook.show(source: UUID(), urls: urls, index: 0)

            controller.hide()
            #expect(!preview.isVisible)
            #expect(!environment.panelState.isVisible)
            #expect(!controller.panel.isVisible)

            // Also when the panel was already hidden.
            environment.quickLook.show(source: UUID(), urls: urls, index: 0)
            controller.hide()
            #expect(!preview.isVisible)
        }

        /// REV-C3: another Orbit window (Settings, About) takes the keyboard while
        /// the preview has it; the panel never resigns key then. The panel and
        /// the preview close, like after a click into another app. "Settings" is
        /// an offscreen panel that is never shown; AppKit's notification that it
        /// became key is posted here (a locked screen gives no window the keyboard).
        /// Orbit's panel is never ordered front.
        @Test func anotherOrbitWindowTakingTheKeyboardClosesThePanelAndThePreview() {
            let (environment, preview) = makeEnvironment()
            let controller = PanelController(environment: environment, openSettings: { _ in })
            environment.panelState.isVisible = true
            environment.quickLook.show(source: UUID(), urls: urls, index: 0)
            preview.userClicks()
            let settings = OffscreenKeyPanel(size: CGSize(width: 480, height: 320))

            // A window of the panel itself (here: the panel) keeps it.
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: controller.panel)
            #expect(environment.panelState.isVisible)
            #expect(preview.isVisible)

            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: settings)
            #expect(!environment.panelState.isVisible)
            #expect(!preview.isVisible)
            #expect(!controller.panel.isVisible)
        }

        /// E2E-1: the preview appears on the screen of Orbit's panel, whatever
        /// frame it remembers.
        @Test func thePreviewIsShownOnThePanelsScreen() {
            let (environment, preview) = makeEnvironment()
            let controller = PanelController(environment: environment, openSettings: { _ in })
            environment.quickLook.show(source: UUID(), urls: urls, index: 0)
            let screen = (controller.panel.screen ?? PanelController.activeScreen())?.visibleFrame
            #expect(screen != nil)
            #expect(preview.shownOnScreen == screen)
        }

        /// UX-1: hiding the panel starts the pause after which the chat is parked.
        @Test func hidingThePanelStartsThePause() async {
            let (environment, _) = makeEnvironment()
            let controller = PanelController(environment: environment, openSettings: { _ in })
            environment.agentLoop.send("Wie spät ist es?")
            await environment.agentLoop.waitUntilIdle()
            let start = Date()
            environment.chatParking.now = { start }
            environment.panelState.isVisible = true
            controller.hide()
            environment.chatParking.now = { start.addingTimeInterval(ChatParking.pause) }
            environment.chatParking.panelWillAppear()
            #expect(environment.chatParking.isParked)
        }
    }
}
