import Foundation
import Observation

/// What photo cards do, the user's own actions: a click (or Return) on a
/// tile shows the photo in Photos through `photos-show.applescript` (macOS
/// asks once whether Orbit may control Photos); when Photos cannot show it,
/// Photos opens instead. The cards' thumbnails come from here too. Something
/// that did not work becomes `failure`, which RootView explains under the
/// input. RootView creates it; cards without one (snapshots of single views)
/// show placeholders and are not clickable.
@MainActor
@Observable
final class PhotoCardActions {
    /// Something the user wanted that did not happen as asked.
    struct Failure: Equatable, Sendable {
        enum Reason: Sendable {
            /// macOS does not let Orbit control Photos (nothing was opened).
            case notPermitted
            /// Photos does not have the photo (any more); Photos opened instead.
            case notFound
            /// Photos could not show the photo; Photos opened instead.
            case notShown
            /// Photos did not open either.
            case photosNotOpened
        }

        var reason: Reason
        /// Tells repeated failures apart.
        var count: Int
    }

    /// The latest failure.
    private(set) var failure: Failure?

    /// Thumbnails for the tiles.
    @ObservationIgnored let thumbnails: any PhotoThumbnailProviding
    @ObservationIgnored private let photos: PhotosService
    @ObservationIgnored private let opener: any PhotosAppOpening

    init(photos: PhotosService, opener: any PhotosAppOpening, thumbnails: any PhotoThumbnailProviding) {
        self.photos = photos
        self.opener = opener
        self.thumbnails = thumbnails
    }

    /// Shows the photo in Photos (off the main actor). When Orbit may not
    /// control Photos, nothing opens and the note says why; when Photos
    /// cannot show the photo, Photos opens instead.
    @discardableResult
    func show(_ item: PhotoItem) -> Task<Void, Never> {
        let photos = photos
        let opener = opener
        let identifier = item.id
        return Task {
            let reason: Failure.Reason
            do {
                try await photos.show(id: identifier)
                return
            } catch is CancellationError {
                return
            } catch AppleScriptError.notAuthorized {
                report(.notPermitted)
                return
            } catch PhotosFailure.itemNotFound, AppleScriptError.notFound {
                reason = .notFound
            } catch {
                Log.panel.error("Showing a photo from a card failed: \(Self.logName(error), privacy: .public)")
                reason = .notShown
            }
            do {
                try await opener.openPhotos()
                report(reason)
            } catch is CancellationError {
                return
            } catch {
                Log.panel.error("Opening Photos from a card failed: \(String(describing: type(of: error)), privacy: .public)")
                report(.photosNotOpened)
            }
        }
    }

    private func report(_ reason: Failure.Reason) {
        failure = Failure(reason: reason, count: (failure?.count ?? 0) + 1)
    }

    /// An error kind for logs (never a message: it may echo user content).
    private nonisolated static func logName(_ error: any Error) -> String {
        (error as? AppleScriptError)?.logName ?? String(describing: type(of: error))
    }
}
