import CoreGraphics
import Foundation

/// A thumbnail for a photo card's tile.
enum PhotoThumbnail: Sendable, Hashable {
    case image(CGImage)
    /// The photo is only in iCloud: Orbit never downloads it, the tile shows a placeholder.
    case inCloud
    /// Not available: deleted meanwhile, no access, cancelled or an error.
    case unavailable
}

/// Thumbnails for photo cards. Live: `LivePhotoThumbnails` (PhotoKit, never
/// over the network, memory-bounded); the DEBUG fake-data mode renders
/// invented placeholder images; tests use a recorder. Nothing here ever asks
/// for a permission: without access every thumbnail is `.unavailable`.
protocol PhotoThumbnailProviding: Sendable {
    /// A thumbnail at least `pixels` pixels on its shorter side (it may be
    /// smaller when only a smaller one is on the Mac). Cancelling the calling
    /// task (the tile went away) stops the request.
    func thumbnail(for identifier: String, pixels: Int) async -> PhotoThumbnail
    /// The thumbnail when it is in memory already (no work, any thread), so a
    /// tile shown again needs no placeholder.
    func cachedThumbnail(for identifier: String, pixels: Int) -> PhotoThumbnail?
    /// A card with these photos appeared: their thumbnails may be prepared
    /// ahead (also those behind "Show N More").
    func prepare(_ identifiers: [String], pixels: Int)
    /// The card went away: what `prepare` started can be dropped.
    func release(_ identifiers: [String], pixels: Int)
}

extension PhotoThumbnailProviding {
    func cachedThumbnail(for identifier: String, pixels: Int) -> PhotoThumbnail? { nil }
    func prepare(_ identifiers: [String], pixels: Int) {}
    func release(_ identifiers: [String], pixels: Int) {}
}

/// No thumbnails (a DEBUG session restricted with ORBIT_DEBUG_FILE_SCOPE, and
/// the default of `AppServices`): tiles show their placeholders.
struct UnavailablePhotoThumbnails: PhotoThumbnailProviding {
    func thumbnail(for identifier: String, pixels: Int) async -> PhotoThumbnail { .unavailable }
}
