import Foundation
import Observation

/// What event and reminder cards do on a click (or Return): the user's own
/// action: an event shows in Calendar, a reminder in Reminders (the app opens
/// when the item cannot be shown). Something that does not open becomes
/// `failure`, which RootView explains under the input. RootView creates it;
/// cards without one (snapshots of single views) are not clickable.
@MainActor
@Observable
final class CalendarCardActions {
    /// Something the user wanted that did not happen.
    struct Failure: Equatable, Sendable {
        enum Reason: Sendable {
            /// Calendar did not open.
            case calendarNotOpened
            /// Reminders did not open.
            case remindersNotOpened
        }

        var reason: Reason
        /// Tells repeated failures apart.
        var count: Int
    }

    /// The latest failure.
    private(set) var failure: Failure?

    @ObservationIgnored private let opener: any CalendarAppOpening

    init(opener: any CalendarAppOpening) {
        self.opener = opener
    }

    /// Shows the event in Calendar (off the main actor).
    @discardableResult
    func showEvent(_ item: EventItem) -> Task<Void, Never> {
        let opener = opener
        let identifier = item.eventIdentifier
        return Task {
            do {
                try await opener.showEvent(identifier: identifier)
            } catch is CancellationError {
                return
            } catch {
                Log.panel.error("Showing an event from a card failed: \(String(describing: type(of: error)), privacy: .public)")
                report(.calendarNotOpened)
            }
        }
    }

    /// Shows the reminder in Reminders (off the main actor).
    @discardableResult
    func showReminder(_ item: ReminderItem) -> Task<Void, Never> {
        let opener = opener
        let identifier = item.id
        return Task {
            do {
                try await opener.showReminder(identifier: identifier)
            } catch is CancellationError {
                return
            } catch {
                Log.panel.error("Showing a reminder from a card failed: \(String(describing: type(of: error)), privacy: .public)")
                report(.remindersNotOpened)
            }
        }
    }

    private func report(_ reason: Failure.Reason) {
        failure = Failure(reason: reason, count: (failure?.count ?? 0) + 1)
    }
}
