import Foundation

/// Whether Orbit may read the user's Photos library.
enum PhotoAccess: Sendable, Hashable {
    case authorized
    /// The user shared only some photos with Orbit: a search finds only those.
    case limited
    /// The user has not decided yet.
    case notDetermined
    case denied
    /// A profile or Screen Time does not allow it.
    case restricted
    /// Not available in this session (a DEBUG session restricted with
    /// ORBIT_DEBUG_FILE_SCOPE but without fake personal data).
    case unavailable

    /// Whether the library may be read.
    var allowsReading: Bool {
        self == .authorized || self == .limited
    }
}

/// What `search_photos` can narrow the media type to.
enum PhotoMediaFilter: String, Sendable, Hashable, CaseIterable {
    /// Every photo (still images, Live Photos and screenshots).
    case image
    case video
    case livePhoto = "live_photo"
    case screenshot
}

/// One photo or video as the tools see it: metadata only, never its pixels,
/// its place or the people in it.
struct PhotoAsset: Sendable, Hashable {
    /// PhotoKit's localIdentifier ("UUID/L0/001").
    var identifier: String
    var creationDate: Date?
    var mediaType: PhotoItem.MediaType
    var isScreenshot = false
    var isFavorite = false
    /// Seconds, for videos.
    var duration: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?
}

/// The standard smart albums of Photos that `search_photos` finds by name.
/// Photos shows them with localized titles; the English name is accepted too.
enum PhotoSmartAlbum: String, Sendable, Hashable, CaseIterable {
    case favorites
    /// "Recents" / the whole library.
    case library
    case recentlyAdded
    case videos
    case livePhotos
    case screenshots
    case selfies
    case portraits
    case panoramas
    case timeLapses
    case sloMo
    case bursts
    case longExposures
    case animated
    case raw
    case cinematic

    /// The name in English; Photos' localized title is the album's `title`.
    var englishName: String {
        switch self {
        case .favorites: "Favorites"
        case .library: "Recents"
        case .recentlyAdded: "Recently Added"
        case .videos: "Videos"
        case .livePhotos: "Live Photos"
        case .screenshots: "Screenshots"
        case .selfies: "Selfies"
        case .portraits: "Portrait"
        case .panoramas: "Panoramas"
        case .timeLapses: "Time-lapse"
        case .sloMo: "Slo-mo"
        case .bursts: "Bursts"
        case .longExposures: "Long Exposure"
        case .animated: "Animated"
        case .raw: "RAW"
        case .cinematic: "Cinematic"
        }
    }
}

/// An album as the tools see it: one the user made, or a standard smart album.
/// The hidden album and "Recently Deleted" are never among them.
struct PhotoAlbum: Sendable, Hashable {
    enum Kind: Sendable, Hashable {
        case user
        case smart(PhotoSmartAlbum)
    }

    /// PhotoKit's localIdentifier of the collection.
    var identifier: String
    /// As Photos shows it (localized for smart albums).
    var title: String
    var kind: Kind

    /// The names the album is found by: its title, and for smart albums the English name.
    var names: [String] {
        switch kind {
        case .user: [title]
        case .smart(let album): title == album.englishName ? [title] : [title, album.englishName]
        }
    }
}

/// A search of the library: created in `start..<end` (either may be open),
/// optionally only favorites, only items in some albums and of one media
/// type; the newest `limit` items. Hidden items are never found.
struct PhotoQuery: Sendable, Hashable {
    /// Created at or after this instant; nil = no lower bound.
    var start: Date?
    /// Created before this instant; nil = no upper bound.
    var end: Date?
    var favoritesOnly = false
    /// Only items in one of these albums (localIdentifiers); nil = the whole library.
    var albumIDs: [String]?
    var mediaType: PhotoMediaFilter?
    /// Items returned at most (newest first).
    var limit: Int
}

/// What a search found.
struct PhotoSearchResult: Sendable, Hashable {
    /// Newest first, at most the query's limit.
    var assets: [PhotoAsset]
    /// How many items match in all (also those beyond the limit), at least
    /// this many when `isTotalExact` is false (the search stopped counting).
    var total: Int
    var isTotalExact = true
}

/// Why the library could not answer.
enum PhotoLibraryError: Error, Sendable, Hashable {
    /// Orbit may not read the library (any more).
    case notAuthorized
    /// An album of the query does not exist any more.
    case albumNotFound
    /// The library cannot be used in this session (see `PhotoAccess.unavailable`).
    case unavailable
}

/// The user's Photos library for `search_photos`, metadata only. Live:
/// `LivePhotoLibrary` (PhotoKit); tests and the DEBUG fake-data mode search
/// invented photos in memory. Reading the authorization never asks;
/// `requestAccess` is only for requests the user made (a tool call).
protocol PhotoLibrary: Sendable {
    /// The current authorization. Cheap; never asks the user.
    func access() -> PhotoAccess
    /// Asks macOS for access when the user has not decided yet (the system
    /// prompt appears) and returns the access afterwards.
    func requestAccess() async -> PhotoAccess
    /// The user's albums and the standard smart albums.
    func albums() async throws -> [PhotoAlbum]
    /// The items that match, newest first.
    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult
}

/// No library (a DEBUG session restricted with ORBIT_DEBUG_FILE_SCOPE but
/// without fake personal data must not reach the user's photos; also the
/// default of `AppServices`).
struct UnavailablePhotoLibrary: PhotoLibrary {
    func access() -> PhotoAccess { .unavailable }
    func requestAccess() async -> PhotoAccess { .unavailable }
    func albums() async throws -> [PhotoAlbum] { throw PhotoLibraryError.unavailable }
    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult { throw PhotoLibraryError.unavailable }
}

// MARK: - Matching in memory (pure)

/// The meaning of a query, applied to photos in memory, by the DEBUG
/// fake-data mode and the tests' library, so both answer like PhotoKit does
/// (`PhotoFetchPlan` is how the live library gets the same answer).
enum PhotoMatching {
    /// Whether `asset` matches the query's dates, favorites and media type
    /// (albums are checked by the caller).
    static func matches(_ asset: PhotoAsset, _ query: PhotoQuery) -> Bool {
        if query.start != nil || query.end != nil {
            guard let date = asset.creationDate else { return false }
            if let start = query.start, date < start { return false }
            if let end = query.end, date >= end { return false }
        }
        if query.favoritesOnly, !asset.isFavorite { return false }
        guard let type = query.mediaType else { return true }
        return matches(asset, type)
    }

    static func matches(_ asset: PhotoAsset, _ type: PhotoMediaFilter) -> Bool {
        switch type {
        case .image: asset.mediaType == .image || asset.mediaType == .livePhoto
        case .video: asset.mediaType == .video
        case .livePhoto: asset.mediaType == .livePhoto
        case .screenshot: asset.isScreenshot
        }
    }

    /// Newest first; items without a date last; then by identifier, so the
    /// order is stable.
    static func newestFirst(_ lhs: PhotoAsset, _ rhs: PhotoAsset) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (left?, right?) where left != right: left > right
        case (.some, nil): true
        case (nil, .some): false
        default: lhs.identifier < rhs.identifier
        }
    }

    /// Searches `assets` (hidden items already left out): `albumMembers`
    /// gives the identifiers in an album, nil for an album that does not
    /// exist (→ `PhotoLibraryError.albumNotFound`).
    static func search(_ assets: [PhotoAsset], query: PhotoQuery,
                       albumMembers: (String) -> Set<String>?) throws -> PhotoSearchResult {
        var allowed: Set<String>?
        if let albumIDs = query.albumIDs {
            var members = Set<String>()
            for id in albumIDs {
                guard let inAlbum = albumMembers(id) else { throw PhotoLibraryError.albumNotFound }
                members.formUnion(inAlbum)
            }
            allowed = members
        }
        var seen = Set<String>()
        let found = assets.filter { asset in
            (allowed?.contains(asset.identifier) ?? true) && matches(asset, query) && seen.insert(asset.identifier).inserted
        }.sorted(by: newestFirst)
        return PhotoSearchResult(assets: Array(found.prefix(max(0, query.limit))), total: found.count)
    }
}

// MARK: - How PhotoKit answers a query (pure)

/// How `LivePhotoLibrary` answers a query with PhotoKit using only fetch
/// options it is sure of: the creation date and the media type (image or
/// video) as the predicate, and collections (an album, or the smart albums
/// Favorites, Live Photos and Screenshots) for the rest. What one fetch
/// cannot express (favorites in an album, Live Photos among favorites, several
/// albums) is checked on each item while the fetch results are scanned.
struct PhotoFetchPlan: Sendable, Hashable {
    /// Where the items come from.
    enum Source: Sendable, Hashable {
        /// The whole library (the user's own photos, not those of shared albums).
        case library
        /// An album by its localIdentifier (also a smart album the user named).
        case album(String)
        case smartAlbum(PhotoSmartAlbum)
    }

    /// A media type the fetch predicate can express.
    enum MediaType: Sendable, Hashable {
        case image
        case video
    }

    /// A condition checked on each item.
    enum Check: Sendable, Hashable {
        case favorite
        case livePhoto
        case screenshot
    }

    var sources: [Source]
    var mediaType: MediaType?
    var checks: [Check]

    /// Whether the fetch results must be scanned: several sources, or checks
    /// one fetch cannot express. Otherwise one fetch counts and returns the
    /// items itself.
    var needsScan: Bool {
        sources.count > 1 || !checks.isEmpty
    }

    /// The plan for `query`; `available` are the smart albums the library has
    /// (without one, the whole library is scanned with a check instead).
    static func make(_ query: PhotoQuery, available: Set<PhotoSmartAlbum>) -> PhotoFetchPlan {
        let mediaType: MediaType? = switch query.mediaType {
        case nil: nil
        case .video: .video
        case .image, .livePhoto, .screenshot: .image
        }
        var checks: [Check] = []
        let typeCheck: Check? = switch query.mediaType {
        case .livePhoto: .livePhoto
        case .screenshot: .screenshot
        default: nil
        }
        if let albumIDs = query.albumIDs {
            // Only these albums (none: nothing).
            var seen = Set<String>()
            if query.favoritesOnly { checks.append(.favorite) }
            if let typeCheck { checks.append(typeCheck) }
            return PhotoFetchPlan(sources: albumIDs.filter { seen.insert($0).inserted }.map(Source.album),
                                  mediaType: mediaType, checks: checks)
        }
        // One smart album holds what the strongest filter asks for; the others become checks.
        var source = Source.library
        if query.favoritesOnly {
            if available.contains(.favorites) {
                source = .smartAlbum(.favorites)
            } else {
                checks.append(.favorite)
            }
            if let typeCheck { checks.append(typeCheck) }
        } else if let typeCheck {
            let album: PhotoSmartAlbum = typeCheck == .livePhoto ? .livePhotos : .screenshots
            if available.contains(album) {
                source = .smartAlbum(album)
            } else {
                checks.append(typeCheck)
            }
        }
        return PhotoFetchPlan(sources: [source], mediaType: mediaType, checks: checks)
    }

    /// Whether an item passes the checks.
    func passes(isFavorite: Bool, isLivePhoto: Bool, isScreenshot: Bool) -> Bool {
        checks.allSatisfy { check in
            switch check {
            case .favorite: isFavorite
            case .livePhoto: isLivePhoto
            case .screenshot: isScreenshot
            }
        }
    }
}
