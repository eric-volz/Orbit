import AppKit
import Quartz
import SwiftUI
import Testing
@testable import Orbit

@Suite("QuickLookController")
@MainActor
struct QuickLookControllerTests {
    private let card = UUID()
    private let otherCard = UUID()
    private let urls = (1...4).map { URL(fileURLWithPath: "/Users/orbit-test/Documents/Rechnung-\($0).pdf") }

    private func makeController() -> (QuickLookController, FakeQuickLookPanel) {
        let panel = FakeQuickLookPanel()
        return (QuickLookController(panel: panel), panel)
    }

    @Test func showsACardsFilesFromTheSelectedRow() {
        let (quickLook, panel) = makeController()
        #expect(!quickLook.isVisible)

        quickLook.toggle(source: card, urls: urls, index: 2)
        #expect(quickLook.isVisible)
        #expect(quickLook.isPreviewing(card))
        #expect(!quickLook.isPreviewing(otherCard))
        #expect(panel.showCount == 1)
        #expect(panel.shownIndex == 2)
        // As the panel's data source.
        #expect(panel.items == urls)
        #expect(quickLook.numberOfPreviewItems(in: nil) == 4)
        #expect(quickLook.previewPanel(nil, previewItemAt: 4) == nil)
    }

    @Test func spaceAgainClosesThePreviewOfTheSameCard() {
        let (quickLook, panel) = makeController()
        quickLook.toggle(source: card, urls: urls, index: 0)
        quickLook.toggle(source: card, urls: urls, index: 0)
        #expect(!quickLook.isVisible)
        #expect(quickLook.preview == nil)
        #expect(panel.closeCount == 1)
        #expect(quickLook.numberOfPreviewItems(in: nil) == 0)
    }

    @Test func anotherCardReplacesThePreview() {
        let (quickLook, panel) = makeController()
        quickLook.toggle(source: card, urls: urls, index: 1)
        let others = [URL(fileURLWithPath: "/Users/orbit-test/Desktop/Notizen.md")]
        quickLook.toggle(source: otherCard, urls: others, index: 0)
        #expect(quickLook.isPreviewing(otherCard))
        #expect(panel.items == others)
        #expect(panel.showCount == 1, "the open panel shows the other files")
        #expect(panel.itemLoads == 2)
        #expect(panel.shownIndex == 0)
        #expect(panel.closeCount == 0)

        // The same files again only move the panel.
        quickLook.show(source: otherCard, urls: others, index: 0)
        #expect(panel.itemLoads == 2)
    }

    @Test func indexesAreClampedAndEmptyCardsShowNothing() {
        let (quickLook, panel) = makeController()
        quickLook.show(source: card, urls: [], index: 0)
        #expect(!quickLook.isVisible)
        #expect(panel.showCount == 0)
        quickLook.show(source: card, urls: urls, index: 9)
        #expect(quickLook.preview?.index == 3)
        quickLook.show(source: card, urls: urls, index: -2)
        #expect(quickLook.preview?.index == 0)
    }

    @Test func thePreviewFollowsOnlyThePreviewedCardsSelection() {
        let (quickLook, panel) = makeController()
        quickLook.show(source: card, urls: urls, index: 0)
        quickLook.follow(index: 3, in: otherCard)
        #expect(quickLook.preview?.index == 0)
        quickLook.follow(index: 7, in: card)
        #expect(quickLook.preview?.index == 0, "out of range")
        quickLook.follow(index: 3, in: card)
        #expect(quickLook.preview?.index == 3)
        #expect(panel.shownIndex == 3)
        let moves = panel.showItemCount
        quickLook.follow(index: 3, in: card)
        #expect(panel.showItemCount == moves, "nothing to do for the same file")
        #expect(panel.itemLoads == 1)
    }

    @Test func navigatingInThePanelMovesThePreview() {
        let (quickLook, panel) = makeController()
        quickLook.show(source: card, urls: urls, index: 1)
        panel.userShows(2)
        #expect(quickLook.preview?.index == 2)
        panel.userShows(8)
        #expect(quickLook.preview?.index == 2)

        // ↑/↓ while the panel has the keyboard (its delegate); they stop at the ends.
        panel.userClicks()
        panel.userMoves(by: 1)
        #expect(quickLook.preview?.index == 3)
        #expect(panel.shownIndex == 3)
        panel.userMoves(by: 1)
        #expect(quickLook.preview?.index == 3)
        panel.userMoves(by: -5)
        #expect(quickLook.preview?.index == 0)
    }

    @Test func theDelegatePassesOnlyUpAndDownToTheCard() throws {
        let (quickLook, _) = makeController()
        quickLook.show(source: card, urls: urls, index: 1)
        func key(_ keyCode: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                          windowNumber: 0, context: nil, characters: characters,
                                          charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        }
        #expect(quickLook.previewPanel(nil, handle: try key(125, "\u{F701}", [.function, .numericPad])))
        #expect(quickLook.preview?.index == 2)
        // Space and Escape close the panel, ←/→ belong to it.
        #expect(!quickLook.previewPanel(nil, handle: try key(49, " ")))
        #expect(!quickLook.previewPanel(nil, handle: try key(53, "\u{1B}")))
        #expect(!quickLook.previewPanel(nil, handle: try key(124, "\u{F703}", [.function, .numericPad])))
        #expect(quickLook.preview?.index == 2)
        #expect(quickLook.previewPanel(nil, sourceFrameOnScreenFor: nil) == .zero, "a fade, no zoom")
    }

    @Test func arrowsInThePanelMapToSelectionMoves() {
        let arrow: NSEvent.ModifierFlags = [.function, .numericPad]
        #expect(QuickLookKeys.selectionMove(keyCode: 125, modifiers: arrow) == 1)
        #expect(QuickLookKeys.selectionMove(keyCode: 126, modifiers: arrow) == -1)
        #expect(QuickLookKeys.selectionMove(keyCode: 126, modifiers: []) == -1)
        #expect(QuickLookKeys.selectionMove(keyCode: 125, modifiers: arrow.union(.command)) == nil)
        #expect(QuickLookKeys.selectionMove(keyCode: 125, modifiers: .shift) == nil)
        for keyCode: UInt16 in [123, 124, 49, 53] {
            #expect(QuickLookKeys.selectionMove(keyCode: keyCode, modifiers: []) == nil)
        }
    }

    @Test func closingTellsWhetherThePreviewHadTheKeyboard() {
        let (quickLook, panel) = makeController()
        var closes: [Bool] = []
        quickLook.didClose = { closes.append($0) }

        quickLook.show(source: card, urls: urls, index: 0)
        #expect(quickLook.close())
        #expect(closes == [false])
        #expect(quickLook.focusReturn == nil, "the card still has the keyboard")

        // The user clicked into the preview, then closed it there.
        quickLook.show(source: card, urls: urls, index: 0)
        panel.userClicks()
        #expect(quickLook.hasKeyboard)
        panel.userCloses()
        #expect(closes == [false, true])
        #expect(quickLook.focusReturn == .init(source: card, count: 1))
        #expect(!quickLook.isVisible)

        // Closed from Orbit while the preview had the keyboard.
        quickLook.show(source: otherCard, urls: urls, index: 0)
        panel.userClicks()
        quickLook.close()
        #expect(closes == [false, true, true])
        #expect(quickLook.focusReturn == .init(source: otherCard, count: 2))

        // A preview that never had the keyboard closes without taking it back.
        quickLook.show(source: card, urls: urls, index: 0)
        panel.userCloses()
        #expect(closes == [false, true, true, false])
        #expect(quickLook.focusReturn?.count == 2)
    }

    @Test func closingWithoutAPreviewDoesNothing() {
        let (quickLook, panel) = makeController()
        var closes = 0
        quickLook.didClose = { _ in closes += 1 }
        #expect(!quickLook.close())
        panel.userCloses()
        #expect(closes == 0)
        #expect(panel.closeCount == 0)
    }

    @Test func aPreviewThatClosedUnnoticedIsForgotten() {
        let (quickLook, panel) = makeController()
        quickLook.show(source: card, urls: urls, index: 0)
        panel.close()
        #expect(!quickLook.isVisible, "visibility comes from the panel")
        #expect(quickLook.preview != nil)
        #expect(!quickLook.close(), "Escape is not used up by a preview that is gone")
        #expect(quickLook.preview == nil)

        quickLook.show(source: card, urls: urls, index: 0)
        panel.close()
        quickLook.syncWithPanel()
        #expect(quickLook.preview == nil)
        quickLook.toggle(source: card, urls: urls, index: 1)
        #expect(quickLook.isVisible, "Space shows it again")
    }

    @Test func controlIsAcceptedOnlyWhilePreviewing() {
        let (quickLook, _) = makeController()
        #expect(!quickLook.acceptsPreviewPanelControl(nil))
        quickLook.show(source: card, urls: urls, index: 0)
        #expect(quickLook.acceptsPreviewPanelControl(nil))
        quickLook.beginPreviewPanelControl(nil)
        quickLook.endPreviewPanelControl(nil)
        #expect(quickLook.isVisible, "handing control over does not close the preview")
    }

    /// The panel's responder chain ends at OrbitPanel, which hands the preview over.
    @Test func theOrbitPanelHandsThePreviewToTheController() {
        let (quickLook, _) = makeController()
        // Never ordered front.
        let orbitPanel = OrbitPanel(rootView: EmptyView())
        #expect(!orbitPanel.acceptsPreviewPanelControl(nil), "without a controller")
        orbitPanel.quickLook = quickLook
        #expect(!orbitPanel.acceptsPreviewPanelControl(nil), "nothing to preview")
        quickLook.show(source: card, urls: urls, index: 0)
        #expect(orbitPanel.acceptsPreviewPanelControl(nil))
        orbitPanel.beginPreviewPanelControl(nil)
        orbitPanel.endPreviewPanelControl(nil)
        #expect(!orbitPanel.isVisible)
    }

    /// The preview goes to the screen of Orbit's panel: QLPreviewPanel
    /// remembers its last frame, which may be on another display.
    @Test func thePreviewAppearsOnTheScreenOfOrbitsPanel() {
        // A second display above the main one (AppKit coordinates), like in the E2E run.
        let main = CGRect(x: 0, y: 0, width: 1728, height: 1085)
        let above = CGRect(x: 1024, y: 1117, width: 2560, height: 1415)
        let remembered = CGRect(x: 0, y: 100, width: 800, height: 500)

        let moved = LiveQuickLookPanel.frame(for: remembered, onScreenWith: above)
        #expect(above.contains(moved))
        #expect(moved.size == remembered.size, "the size stays")
        #expect(abs(moved.midX - above.midX) <= 0.5 && abs(moved.midY - above.midY) <= 0.5, "centered there, on whole points")
        #expect(moved.origin.x == moved.origin.x.rounded() && moved.origin.y == moved.origin.y.rounded())

        // Where the user left it on that screen, it stays.
        #expect(LiveQuickLookPanel.frame(for: remembered, onScreenWith: main) == remembered)
        let placedByUser = CGRect(x: 1200, y: 1300, width: 900, height: 600)
        #expect(LiveQuickLookPanel.frame(for: placedByUser, onScreenWith: above) == placedByUser)

        // Too large for a small screen, or not sized yet.
        let small = CGRect(x: -1280, y: 0, width: 1280, height: 777)
        let fitted = LiveQuickLookPanel.frame(for: CGRect(x: 0, y: 0, width: 2000, height: 1500), onScreenWith: small)
        #expect(small.contains(fitted))
        #expect(fitted.width == 1280 - 2 * LiveQuickLookPanel.screenMargin)
        #expect(fitted.height == 777 - 2 * LiveQuickLookPanel.screenMargin)
        let unsized = LiveQuickLookPanel.frame(for: .zero, onScreenWith: above)
        #expect(unsized.size == LiveQuickLookPanel.defaultSize)
        #expect(above.contains(unsized))
    }

    @Test func thePreviewIsToldTheScreenOfOrbitsPanel() {
        let (quickLook, panel) = makeController()
        let screen = CGRect(x: 1024, y: 1117, width: 2560, height: 1415)
        quickLook.hostScreenFrame = { screen }
        quickLook.show(source: card, urls: urls, index: 0)
        #expect(panel.shownOnScreen == screen)
    }

    @Test func theLivePanelFloatsAboveOrbitAndIsCreatedOnlyForAPreview() {
        #expect(LiveQuickLookPanel.level.rawValue > NSWindow.Level.statusBar.rawValue)
        let live = LiveQuickLookPanel()
        #expect(!live.isVisible)
        #expect(!live.isKey)
        live.showItem(at: 1, reloadingItems: true)
        live.close()
        #expect(!QLPreviewPanel.sharedPreviewPanelExists(), "tests never create the system's preview panel")
    }
}
