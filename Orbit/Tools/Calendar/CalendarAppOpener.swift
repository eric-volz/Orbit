import AppKit

/// Shows events in Calendar and reminders in Reminders: the user's click on
/// a card ("Show in Calendar", "Show in Reminders"). Live: NSWorkspace
/// on the main actor; restricted debug sessions cannot, the DEBUG fake-data
/// mode only records, and tests use a recorder.
protocol CalendarAppOpening: Sendable {
    /// Shows the event (EventKit's eventIdentifier) in Calendar, or opens
    /// Calendar when it cannot be shown. Throws when nothing opened.
    func showEvent(identifier: String?) async throws
    /// Shows the reminder (EventKit's calendarItemIdentifier) in Reminders,
    /// or opens Reminders. Throws when nothing opened.
    func showReminder(identifier: String?) async throws
}

/// The links that show an item in Calendar or Reminders. Both formats are the
/// ones macOS itself builds; Calendar, its notifications and Spotlight show
/// an event with `ical://ekevent/<id>?method=show&options=more`, Spotlight a
/// reminder with `x-apple-reminderkit://REMCDReminder/<id>` (found in the
/// system's frameworks; that they show the item is a live check, and Orbit
/// opens the app when no app takes the link).
enum CalendarLinks {
    static let calendarBundleID = "com.apple.iCal"
    static let remindersBundleID = "com.apple.reminders"

    /// Characters that stay as they are in an identifier; everything else is
    /// percent-encoded (also "/", so an identifier stays one path component).
    private static let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:@")

    static func event(identifier: String) -> URL? {
        guard let encoded = encoded(identifier) else { return nil }
        return URL(string: "ical://ekevent/\(encoded)?method=show&options=more")
    }

    static func reminder(identifier: String) -> URL? {
        guard let encoded = encoded(identifier) else { return nil }
        return URL(string: "x-apple-reminderkit://REMCDReminder/\(encoded)")
    }

    private static func encoded(_ identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512 else { return nil }
        return trimmed.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}

struct LiveCalendarAppOpener: CalendarAppOpening {
    func showEvent(identifier: String?) async throws {
        try await show(identifier.flatMap(CalendarLinks.event(identifier:)), app: CalendarLinks.calendarBundleID)
    }

    func showReminder(identifier: String?) async throws {
        try await show(identifier.flatMap(CalendarLinks.reminder(identifier:)), app: CalendarLinks.remindersBundleID)
    }

    /// The link, or (when there is none or no app takes it) the app itself.
    private func show(_ link: URL?, app bundleID: String) async throws {
        if let link {
            do {
                try await Self.open(link)
                return
            } catch {
                Log.panel.error("A calendar link could not be opened: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        try await Self.openApplication(bundleID)
    }

    private static func open(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Task { @MainActor in
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                    continuation.resume(with: error.map { .failure($0) } ?? .success(()))
                }
            }
        }
    }

    private static func openApplication(_ bundleID: String) async throws {
        struct NotInstalled: Error {}
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Task { @MainActor in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                    continuation.resume(throwing: NotInstalled())
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                    continuation.resume(with: error.map { .failure($0) } ?? .success(()))
                }
            }
        }
    }
}

/// Opens nothing (DEBUG sessions restricted with ORBIT_DEBUG_FILE_SCOPE, and
/// the default of `AppServices`): Calendar and Reminders are never reached.
struct DisabledCalendarAppOpener: CalendarAppOpening {
    struct Disabled: Error {}

    func showEvent(identifier: String?) async throws {
        throw Disabled()
    }

    func showReminder(identifier: String?) async throws {
        throw Disabled()
    }
}
