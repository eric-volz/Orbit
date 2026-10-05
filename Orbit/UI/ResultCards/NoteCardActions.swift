import Foundation
import Observation

/// Opens notes from note cards in Notes, the user's own action, through the
/// same script as `open_note` (so the same permission). A note that cannot be
/// opened becomes `openFailure`, which RootView explains under the input.
/// RootView creates it; cards without one (snapshots of single views) are not
/// clickable.
@MainActor
@Observable
final class NoteCardActions {
    /// A note the user wanted to open that Orbit could not show.
    struct OpenFailure: Equatable, Sendable {
        enum Reason: Sendable {
            /// Deleted (or moved to another account) since the card was made.
            case notFound
            /// macOS does not let Orbit control Notes.
            case notPermitted
            case failed
        }

        var title: String
        var reason: Reason
        /// Tells failures for the same note apart.
        var count: Int
    }

    /// The latest note that could not be opened.
    private(set) var openFailure: OpenFailure?

    @ObservationIgnored private let notes: NotesService

    init(notes: NotesService) {
        self.notes = notes
    }

    /// Shows the note in Notes (off the main actor) and brings Notes to the front.
    @discardableResult
    func open(_ item: NoteItem) -> Task<Void, Never> {
        let notes = notes
        let title = item.title
        return Task {
            do {
                try await notes.open(id: item.id)
            } catch NotesFailure.noteNotFound, AppleScriptError.notFound {
                report(title, .notFound)
            } catch AppleScriptError.notAuthorized {
                report(title, .notPermitted)
            } catch is CancellationError {
                return
            } catch {
                Log.panel.error("Opening a note from a card failed: \(String(describing: type(of: error)), privacy: .public)")
                report(title, .failed)
            }
        }
    }

    private func report(_ title: String, _ reason: OpenFailure.Reason) {
        openFailure = OpenFailure(title: title, reason: reason, count: (openFailure?.count ?? 0) + 1)
    }
}
