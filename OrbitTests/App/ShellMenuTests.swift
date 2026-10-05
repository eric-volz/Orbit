import AppKit
import KeyboardShortcuts
import Testing
@testable import Orbit

@MainActor
private final class RecordingActions: AppActions {
    var calls: [String] = []

    func showPanel() { calls.append("showPanel") }
    func hidePanel() { calls.append("hidePanel") }
    func togglePanel() { calls.append("togglePanel") }
    func startNewChat() { calls.append("startNewChat") }
    func showSettings() { calls.append("showSettings") }
    func showOnboarding() { calls.append("showOnboarding") }
    func closeKeyWindow() { calls.append("closeKeyWindow") }
    func showAboutPanel() { calls.append("showAboutPanel") }
}

@Suite("Main menu")
@MainActor
struct MainMenuTests {
    private func item(_ menu: NSMenu, key: String, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem? {
        menu.items.compactMap(\.submenu).flatMap(\.items).first {
            $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers
        }
    }

    @Test func editMenuSendsStandardSelectorsToTheFirstResponder() throws {
        let menu = MainMenu(actions: RecordingActions()).menu
        let expected: [(String, NSEvent.ModifierFlags, String)] = [
            ("z", .command, "undo:"), ("z", [.command, .shift], "redo:"), ("x", .command, "cut:"),
            ("c", .command, "copy:"), ("v", .command, "paste:"), ("a", .command, "selectAll:"),
        ]
        for (key, modifiers, selector) in expected {
            let menuItem = try #require(item(menu, key: key, modifiers: modifiers))
            #expect(menuItem.action == Selector((selector)))
            #expect(menuItem.target == nil)
        }
    }

    @Test func appAndChatCommandsReachTheActions() throws {
        let actions = RecordingActions()
        let mainMenu = MainMenu(actions: actions)
        for key in [",", "n", "w"] {
            let menuItem = try #require(item(mainMenu.menu, key: key))
            let target = try #require(menuItem.target)
            _ = target.perform(menuItem.action, with: menuItem)
        }
        #expect(actions.calls == ["showSettings", "startNewChat", "closeKeyWindow"])
        #expect(item(mainMenu.menu, key: "q")?.action == #selector(NSApplication.terminate(_:)))
        #expect(item(mainMenu.menu, key: "h")?.action == #selector(NSApplication.hide(_:)))
    }

    @Test func titlesAreGerman() {
        let menu = MainMenu(actions: RecordingActions()).menu
        #expect(menu.items.map(\.title) == ["Orbit", "Edit", "Chat"])
        let titles = menu.items.compactMap(\.submenu).flatMap(\.items).map(\.title)
        for title in ["About Orbit", "Settings…", "Quit Orbit", "Paste", "New Chat", "Close Window"] {
            #expect(titles.contains(title))
        }
    }
}

@Suite("Menu bar menu")
@MainActor
struct MenuBarMenuTests {
    @Test func itemsInOrder() {
        let menu = MenuBarMenu(actions: RecordingActions()).menu
        #expect(menu.items.map(\.isSeparatorItem) == [false, false, true, false, false, true, false])
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title)
            == ["Open Orbit", "New Chat", "Settings…", "Setup…", "Quit Orbit"])
        #expect(menu.items.first { $0.title == "Settings…" }?.keyEquivalent == ",")
        #expect(menu.items.last?.action == #selector(NSApplication.terminate(_:)))
    }

    @Test func itemsReachTheActions() throws {
        let actions = RecordingActions()
        let menuBarMenu = MenuBarMenu(actions: actions)
        for title in ["Setup…", "Settings…", "New Chat", "Open Orbit"] {
            let item = try #require(menuBarMenu.menu.items.first { $0.title == title })
            let target = try #require(item.target)
            _ = target.perform(item.action, with: item)
        }
        #expect(actions.calls == ["showOnboarding", "showSettings", "startNewChat", "showPanel", "showPanel"])
    }
}

@Suite("Hotkey and status icon")
@MainActor
struct HotkeyAndIconTests {
    @Test func defaultHotkeyIsOptionSpace() {
        #expect(HotkeyManager.defaultShortcut.key == .space)
        #expect(HotkeyManager.defaultShortcut.modifiers == .option)
    }

    @Test func statusIconIsADrawnTemplateImage() throws {
        let image = OrbitStatusIcon.image()
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var inked = 0
        for x in 0..<36 {
            for y in 0..<36 where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
                inked += 1
            }
        }
        // Planet, satellite and orbit cover roughly 15 to 35% of the canvas.
        #expect(inked > 36 * 36 / 10)
        #expect(inked < 36 * 36 / 2)
    }
}
