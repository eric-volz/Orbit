import AppKit
import KeyboardShortcuts

/// The menu bar item (Orbit has no Dock icon) with `MenuBarMenu`.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menuBarMenu: MenuBarMenu

    init(actions: any AppActions) {
        menuBarMenu = MenuBarMenu(actions: actions)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.autosaveName = "OrbitStatusItem"
        if let button = statusItem.button {
            button.image = OrbitStatusIcon.image()
            button.setAccessibilityLabel(String(localized: "Orbit"))
            button.toolTip = String(localized: "Orbit")
        }
        statusItem.menu = menuBarMenu.menu
    }
}

/// The menu of the menu bar item: Open Orbit, New Chat, Settings…,
/// Setup… (the onboarding), Quit Orbit. Separate from the status item,
/// so it can be built without one.
@MainActor
final class MenuBarMenu: NSObject {
    let menu = NSMenu()
    private weak var actions: (any AppActions)?

    init(actions: any AppActions) {
        self.actions = actions
        super.init()
        let open = item(String(localized: "Open Orbit"), action: #selector(openPanel(_:)))
        // Shows the current global hotkey and follows changes made in Settings.
        open.setShortcut(for: .togglePanel)
        menu.addItem(open)
        menu.addItem(item(String(localized: "New Chat"), action: #selector(newChat(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Settings…"), action: #selector(openSettings(_:)), key: ","))
        menu.addItem(item(String(localized: "Setup…"), action: #selector(openOnboarding(_:))))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: String(localized: "Quit Orbit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openPanel(_ sender: Any?) {
        actions?.showPanel()
    }

    @objc private func newChat(_ sender: Any?) {
        actions?.startNewChat()
        actions?.showPanel()
    }

    @objc private func openSettings(_ sender: Any?) {
        actions?.showSettings()
    }

    @objc private func openOnboarding(_ sender: Any?) {
        actions?.showOnboarding()
    }
}

/// The menu bar icon: a planet with a tilted orbit and a satellite, drawn as a template image
/// so it adapts to light/dark menu bars and the selection highlight.
enum OrbitStatusIcon {
    static func image() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            draw(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "Orbit")
        return image
    }

    private static func draw(in rect: NSRect) {
        let scale = min(rect.width, rect.height) / 18
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radiusX = 8.3 * scale
        let radiusY = 3.7 * scale
        let tilt: CGFloat = 25
        let satelliteAngle: CGFloat = 40
        // Half the gap the orbit leaves around the satellite, in degrees of the ellipse parameter.
        let gap: CGFloat = 27

        let toOrbit = NSAffineTransform()
        toOrbit.translateX(by: center.x, yBy: center.y)
        toOrbit.rotate(byDegrees: tilt)
        toOrbit.scaleX(by: radiusX, yBy: radiusY)

        let ring = NSBezierPath()
        ring.appendArc(withCenter: .zero, radius: 1,
                       startAngle: satelliteAngle + gap, endAngle: satelliteAngle - gap + 360)
        ring.transform(using: toOrbit as AffineTransform)
        ring.lineWidth = 1.2 * scale
        ring.lineCapStyle = .round
        NSColor.black.setStroke()
        ring.stroke()

        NSColor.black.setFill()
        let angle = satelliteAngle * .pi / 180
        let satellite = toOrbit.transform(NSPoint(x: cos(angle), y: sin(angle)))
        let satelliteRadius = 1.8 * scale
        NSBezierPath(ovalIn: NSRect(x: satellite.x - satelliteRadius, y: satellite.y - satelliteRadius,
                                    width: 2 * satelliteRadius, height: 2 * satelliteRadius)).fill()
        let planetRadius = 2.5 * scale
        NSBezierPath(ovalIn: NSRect(x: center.x - planetRadius, y: center.y - planetRadius,
                                    width: 2 * planetRadius, height: 2 * planetRadius)).fill()
    }
}
