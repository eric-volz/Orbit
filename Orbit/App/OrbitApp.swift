import AppKit

/// Entry point. Orbit is an AppKit menu bar app (LSUIElement, no Dock icon);
/// SwiftUI renders the panel, settings and onboarding content.
@main
enum OrbitApp {
    @MainActor
    static func main() {
        // Before anything loads localized resources: drop the German default older
        // versions set for Orbit, so macOS decides (English unless German comes first).
        AppLanguage.removeLegacyGermanDefault()
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
