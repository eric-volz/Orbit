import AppKit

/// `NSApp.mainMenu`. Orbit is an LSUIElement app, so the menu bar never shows it, but AppKit
/// still resolves key equivalents through it, also while the panel is key and Orbit is not
/// active. Without the Edit menu, ⌘C/⌘V/⌘X/⌘A/⌘Z would do nothing in the panel's text field.
@MainActor
final class MainMenu: NSObject {
    let menu = NSMenu()
    private weak var actions: (any AppActions)?

    init(actions: any AppActions) {
        self.actions = actions
        super.init()
        menu.addItem(submenuItem(makeAppMenu()))
        menu.addItem(submenuItem(makeEditMenu()))
        menu.addItem(submenuItem(makeChatMenu()))
    }

    // MARK: Menus

    private func makeAppMenu() -> NSMenu {
        let appMenu = NSMenu(title: "Orbit")
        appMenu.addItem(item(String(localized: "About Orbit"), action: #selector(showAbout(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item(String(localized: "Settings…"), action: #selector(showSettings(_:)), key: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(responderItem(String(localized: "Hide Orbit"), action: #selector(NSApplication.hide(_:)), key: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(responderItem(String(localized: "Quit Orbit"), action: #selector(NSApplication.terminate(_:)), key: "q"))
        return appMenu
    }

    private func makeEditMenu() -> NSMenu {
        let editMenu = NSMenu(title: String(localized: "Edit"))
        editMenu.addItem(responderItem(String(localized: "Undo"), action: Selector(("undo:")), key: "z"))
        editMenu.addItem(responderItem(String(localized: "Redo"), action: Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(responderItem(String(localized: "Cut"), action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(responderItem(String(localized: "Copy"), action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(responderItem(String(localized: "Paste"), action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(responderItem(String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), key: "a"))
        return editMenu
    }

    private func makeChatMenu() -> NSMenu {
        let chatMenu = NSMenu(title: String(localized: "Chat"))
        chatMenu.addItem(item(String(localized: "New Chat"), action: #selector(newChat(_:)), key: "n"))
        chatMenu.addItem(item(String(localized: "Close Window"), action: #selector(closeWindow(_:)), key: "w"))
        return chatMenu
    }

    // MARK: Actions

    @objc private func showAbout(_ sender: Any?) {
        actions?.showAboutPanel()
    }

    @objc private func showSettings(_ sender: Any?) {
        actions?.showSettings()
    }

    @objc private func newChat(_ sender: Any?) {
        actions?.startNewChat()
    }

    @objc private func closeWindow(_ sender: Any?) {
        actions?.closeKeyWindow()
    }

    // MARK: Helpers

    private func submenuItem(_ submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    /// An item handled by this object.
    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : .command
        item.target = self
        return item
    }

    /// An item sent up the responder chain (nil target): the field editor handles the Edit
    /// actions, NSApp handles hide/terminate.
    private func responderItem(
        _ title: String,
        action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }
}
