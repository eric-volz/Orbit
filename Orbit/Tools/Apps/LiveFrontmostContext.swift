import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The frontmost app as NSWorkspace knows it (read on the main actor). Orbit's
/// panel does not activate Orbit, so while it is open this is still the app
/// the user came from.
struct LiveFrontmostApps: FrontmostAppProviding {
    func frontmostApp() async -> FrontmostApp? {
        await MainActor.run {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return FrontmostApp(name: app.localizedName ?? app.bundleIdentifier ?? "", bundleID: app.bundleIdentifier,
                                processID: app.processIdentifier)
        }
    }
}

/// The Accessibility API on another app, only once Orbit is trusted
/// (`AXIsProcessTrusted`, which never asks), on a background queue, with a
/// short messaging timeout per element, so an app that does not answer delays
/// the read by a quarter of a second at most per question. Reads attributes
/// only: it never sets one, performs an action or observes the app.
struct LiveAccessibilityReader: AccessibilityReading {
    /// Seconds an app gets to answer one question.
    static let messagingTimeout: Float = 0.25

    func isSecureInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    func read<Value: Sendable>(_ processID: pid_t,
                               _ body: @escaping @Sendable (any AccessibilityElement) -> Value) async -> Value? {
        await Background.run { () -> Value? in
            guard AXIsProcessTrusted() else { return nil }
            return body(LiveAXElement(AXUIElementCreateApplication(processID)))
        }
    }
}

/// An AXUIElement of another app, read with the short messaging timeout.
private struct LiveAXElement: AccessibilityElement {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
        AXUIElementSetMessagingTimeout(element, LiveAccessibilityReader.messagingTimeout)
    }

    func string(_ attribute: String) -> String? {
        copy(attribute) as? String
    }

    func element(_ attribute: String) -> (any AccessibilityElement)? {
        guard let value = copy(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return LiveAXElement(unsafeDowncast(value, to: AXUIElement.self))
    }

    func range(_ attribute: String) -> NSRange? {
        guard let value = copy(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    func string(in range: NSRange) -> String? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForRange" as CFString, parameter, &result) == .success
        else { return nil }
        return result as? String
    }

    private func copy(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
