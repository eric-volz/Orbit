import CoreGraphics
import Testing
@testable import Orbit

@Suite("PanelLayout")
struct PanelLayoutTests {
    /// A 1512×982 MacBook screen minus menu bar (33 pt) and no Dock.
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 949)

    @Test func usesFullWidthOnWideScreens() {
        let layout = PanelLayout(visibleFrame: laptop)
        #expect(layout.width == 720)
        let frame = layout.frame(forPreferredHeight: 64)
        #expect(frame.minX == 396)  // (1512 - 720) / 2
        #expect(frame.midX == laptop.midX)
    }

    @Test(arguments: [
        (CGFloat(700), CGFloat(636)),
        (CGFloat(784), CGFloat(720)),
        (CGFloat(783), CGFloat(719)),
    ])
    func keepsThirtyTwoPointMarginsOnNarrowScreens(screenWidth: CGFloat, expectedWidth: CGFloat) {
        let layout = PanelLayout(visibleFrame: CGRect(x: 0, y: 0, width: screenWidth, height: 800))
        #expect(layout.width == expectedWidth)
    }

    @Test func placesTopEdgeInUpperThird() {
        let layout = PanelLayout(visibleFrame: laptop)
        let frame = layout.frame(forPreferredHeight: 64)
        // 22 % of 949 = 208.78 → top at 949 - 208.78 = 740.22, rounded to whole points.
        #expect(frame.maxY == 740)
        #expect(frame.maxY > laptop.maxY - laptop.height / 3)
    }

    @Test func clampsHeight() {
        let layout = PanelLayout(visibleFrame: laptop)
        #expect(layout.maximumHeight == 664)  // 70 % of 949, rounded down
        #expect(layout.height(forPreferredHeight: 10) == PanelLayout.minimumHeight)
        #expect(layout.height(forPreferredHeight: 64) == 64)
        #expect(layout.height(forPreferredHeight: 300.2) == 301)
        #expect(layout.height(forPreferredHeight: 5000) == 664)
        #expect(layout.height(forPreferredHeight: .nan) == PanelLayout.minimumHeight)
        #expect(layout.height(forPreferredHeight: .infinity) == PanelLayout.minimumHeight)
    }

    @Test func growsDownwardWithFixedTopEdge() {
        let layout = PanelLayout(visibleFrame: laptop)
        let small = layout.frame(forPreferredHeight: 64)
        let large = layout.frame(forPreferredHeight: 480)
        let clamped = layout.frame(forPreferredHeight: 10_000)
        #expect(small.maxY == large.maxY)
        #expect(large.maxY == clamped.maxY)
        #expect(large.minY == small.minY - (480 - 64))
        #expect(small.minX == large.minX && small.width == large.width)
    }

    @Test func maximumHeightStaysOnScreen() {
        for visible in [laptop, CGRect(x: 0, y: 80, width: 1920, height: 1000), CGRect(x: 0, y: 0, width: 1024, height: 700)] {
            let frame = PanelLayout(visibleFrame: visible).frame(forPreferredHeight: .greatestFiniteMagnitude)
            #expect(frame.minY >= visible.minY)
            #expect(frame.maxY <= visible.maxY)
        }
    }

    @Test func worksOnSecondaryScreenWithNegativeOrigin() {
        // A screen to the left of and above the main screen, with a Dock at the bottom.
        let visible = CGRect(x: -2560, y: 982, width: 2560, height: 1370)
        let frame = PanelLayout(visibleFrame: visible).frame(forPreferredHeight: 200)
        #expect(frame.width == 720)
        #expect(frame.midX == visible.midX)
        #expect(frame.maxY == (visible.maxY - visible.height * 0.22).rounded())
        #expect(visible.contains(frame))
    }

    @Test func resizeAnimationKeepsTopEdgeAndEasesOut() {
        let layout = PanelLayout(visibleFrame: laptop)
        let start = layout.frame(forPreferredHeight: 64)
        let target = layout.frame(forPreferredHeight: 464)
        #expect(PanelLayout.interpolatedFrame(from: start, to: target, progress: 0) == start)
        #expect(PanelLayout.interpolatedFrame(from: start, to: target, progress: 1) == target)
        #expect(PanelLayout.interpolatedFrame(from: start, to: target, progress: 7) == target)
        #expect(PanelLayout.interpolatedFrame(from: start, to: target, progress: -1) == start)

        var previousHeight = start.height
        for step in 1...20 {
            let frame = PanelLayout.interpolatedFrame(from: start, to: target, progress: Double(step) / 20)
            #expect(frame.maxY == target.maxY)
            #expect(frame.height >= previousHeight)
            #expect(frame.height == frame.height.rounded() && frame.minY == frame.minY.rounded())
            previousHeight = frame.height
        }
        // Ease-out: more than half of the way after a quarter of the time.
        let quarter = PanelLayout.interpolatedFrame(from: start, to: target, progress: 0.25)
        #expect(quarter.height > start.height + (target.height - start.height) / 2)
    }

    @Test func resizeAnimationShrinksToo() {
        let layout = PanelLayout(visibleFrame: laptop)
        let start = layout.frame(forPreferredHeight: 600)
        let target = layout.frame(forPreferredHeight: 64)
        let middle = PanelLayout.interpolatedFrame(from: start, to: target, progress: 0.5)
        #expect(middle.height < start.height && middle.height > target.height)
        #expect(middle.maxY == start.maxY)
    }

    @Test func findsScreenContainingMouse() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
        let frames = [main, external]
        #expect(PanelLayout.indexOfScreen(containing: CGPoint(x: 700, y: 500), screenFrames: frames) == 0)
        #expect(PanelLayout.indexOfScreen(containing: CGPoint(x: 2000, y: 0), screenFrames: frames) == 1)
        // Top edge belongs to the screen, bottom edge does not (like NSMouseInRect).
        #expect(PanelLayout.indexOfScreen(containing: CGPoint(x: 10, y: 982), screenFrames: frames) == 0)
        #expect(PanelLayout.indexOfScreen(containing: CGPoint(x: 10, y: 0), screenFrames: frames) == nil)
        // Left edge belongs to the screen on the right.
        #expect(PanelLayout.indexOfScreen(containing: CGPoint(x: 1512, y: 100), screenFrames: frames) == 1)
        #expect(PanelLayout.indexOfScreen(containing: CGPoint(x: -5, y: 100), screenFrames: frames) == nil)
    }
}

/// Whether the panel stays up after the keyboard moved (REV-C3).
@Suite("Panel focus")
struct PanelFocusTests {
    @Test func anotherOrbitWindowClosesThePanelEvenWithAPreviewUp() {
        // Settings or the About panel took the keyboard while the preview was up and Orbit active.
        #expect(!PanelController.staysUp(afterKeyboardMovedTo: .otherWindow, isPreviewVisible: true, isAppActive: true))
        #expect(!PanelController.staysUp(afterKeyboardMovedTo: .otherWindow, isPreviewVisible: false, isAppActive: true))
        #expect(!PanelController.staysUp(afterKeyboardMovedTo: .otherWindow, isPreviewVisible: true, isAppActive: false))
    }

    @Test func aClickIntoThePreviewKeepsThePanel() {
        // Orbit became active; the preview is about to become key.
        #expect(PanelController.staysUp(afterKeyboardMovedTo: .noWindow, isPreviewVisible: true, isAppActive: true))
        // The preview (or a sheet of the panel) has the keyboard.
        #expect(PanelController.staysUp(afterKeyboardMovedTo: .panel, isPreviewVisible: true, isAppActive: true))
        #expect(PanelController.staysUp(afterKeyboardMovedTo: .panel, isPreviewVisible: false, isAppActive: false))
    }

    @Test func anotherAppClosesThePanel() {
        #expect(!PanelController.staysUp(afterKeyboardMovedTo: .noWindow, isPreviewVisible: true, isAppActive: false))
        #expect(!PanelController.staysUp(afterKeyboardMovedTo: .noWindow, isPreviewVisible: false, isAppActive: false))
        #expect(!PanelController.staysUp(afterKeyboardMovedTo: .noWindow, isPreviewVisible: false, isAppActive: true))
    }

    /// UX-1: while Orbit hands the keyboard to Mail's reply window, another
    /// app's window taking it keeps the panel; another Orbit window never does.
    @Test func orbitsHandoffKeepsThePanelForAnotherAppsWindowOnly() {
        #expect(PanelController.staysUp(afterKeyboardMovedTo: .noWindow, isPreviewVisible: false, isAppActive: false,
                                        isHandingOffKeyboard: true))
        #expect(PanelController.staysUp(afterKeyboardMovedTo: .noWindow, isPreviewVisible: false, isAppActive: true,
                                        isHandingOffKeyboard: true))
        #expect(!PanelController.staysUp(afterKeyboardMovedTo: .otherWindow, isPreviewVisible: false, isAppActive: true,
                                         isHandingOffKeyboard: true), "Settings or About still close it")
        #expect(PanelController.staysUp(afterKeyboardMovedTo: .panel, isPreviewVisible: false, isAppActive: false,
                                        isHandingOffKeyboard: true))
    }
}
