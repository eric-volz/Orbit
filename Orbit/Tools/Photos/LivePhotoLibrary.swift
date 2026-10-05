import Foundation
import Photos
import os

/// The user's Photos library through PhotoKit, with `LivePhotoThumbnails`
/// the only place Orbit touches PhotoKit's data.
///
/// Nothing is fetched without access: PhotoKit asks the user on the first
/// fetch, and only `requestAccess` (a request the user made) may ask. All
/// fetches run on one serial queue, never on the main thread, and PhotoKit's
/// objects become value types there. Searches read metadata only (date,
/// media type, favorite, duration, pixel size), never locations, people or
/// pixels; hidden items are never fetched. The fetch options use only what
/// PhotoKit documents for predicates (creation date, media type) and
/// collections for the rest (`PhotoFetchPlan`). Logs record counts and
/// durations, never album names.
struct LivePhotoLibrary: PhotoLibrary {
    /// Items a search looks at at most when it must check them one by one;
    /// beyond that the total is "at least".
    static let maxScanned = 50_000
    /// Album titles longer than this are cut when they are read.
    static let maxTitleCharacters = 200
    private static let queue = DispatchQueue(label: "io.github.eric-volz.Orbit.photo-library", qos: .userInitiated)

    init() {}

    // MARK: Access

    func access() -> PhotoAccess {
        Self.access(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAccess() async -> PhotoAccess {
        guard access() == .notDetermined else { return access() }
        Log.permissions.info("Asking for access to Photos")
        return Self.access(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    // MARK: Reading

    func albums() async throws -> [PhotoAlbum] {
        let albums = try await perform { _ in
            var albums: [PhotoAlbum] = []
            let user = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            for index in 0..<user.count {
                let collection = user.object(at: index)
                guard let title = Self.title(of: collection) else { continue }
                albums.append(PhotoAlbum(identifier: collection.localIdentifier, title: title, kind: .user))
            }
            for album in PhotoSmartAlbum.allCases {
                guard let collection = Self.smartAlbum(album) else { continue }
                albums.append(PhotoAlbum(identifier: collection.localIdentifier, title: Self.title(of: collection) ?? album.englishName,
                                         kind: .smart(album)))
            }
            return albums
        }
        Log.tools.info("Photos: \(albums.count) albums read")
        return albums
    }

    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult {
        let begin = ContinuousClock.now
        let result = try await perform { isCancelled in
            try Self.run(query, isCancelled: isCancelled)
        }
        let milliseconds = Int((ContinuousClock.now - begin) / .milliseconds(1))
        Log.tools.info("Photos: \(result.total) found\(result.isTotalExact ? "" : " at least", privacy: .public), \(result.assets.count) returned in \(milliseconds) ms")
        return result
    }

    /// Runs a query on the queue.
    private static func run(_ query: PhotoQuery, isCancelled: () -> Bool) throws -> PhotoSearchResult {
        var smartAlbums: [PhotoSmartAlbum: PHAssetCollection] = [:]
        var wanted: [PhotoSmartAlbum] = []
        if query.albumIDs == nil {
            if query.favoritesOnly { wanted.append(.favorites) }
            if query.mediaType == .livePhoto { wanted.append(.livePhotos) }
            if query.mediaType == .screenshot { wanted.append(.screenshots) }
        }
        for album in wanted {
            smartAlbums[album] = smartAlbum(album)
        }
        let plan = PhotoFetchPlan.make(query, available: Set(smartAlbums.keys))

        var albums: [String: PHAssetCollection] = [:]
        let albumIDs = plan.sources.compactMap { source -> String? in
            if case .album(let id) = source { return id }
            return nil
        }
        if !albumIDs.isEmpty {
            let fetched = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: albumIDs, options: nil)
            for index in 0..<fetched.count {
                let collection = fetched.object(at: index)
                albums[collection.localIdentifier] = collection
            }
            guard albumIDs.allSatisfy({ albums[$0] != nil }) else { throw PhotoLibraryError.albumNotFound }
        }

        /// nil only for a collection that could not be resolved (an album missing throws before).
        func fetch(_ source: PhotoFetchPlan.Source) -> PHFetchResult<PHAsset>? {
            let options = fetchOptions(query, plan: plan, source: source)
            switch source {
            case .library: return PHAsset.fetchAssets(with: options)
            case .album(let id): return albums[id].map { PHAsset.fetchAssets(in: $0, options: options) }
            case .smartAlbum(let album): return smartAlbums[album].map { PHAsset.fetchAssets(in: $0, options: options) }
            }
        }

        let limit = max(0, query.limit)
        if !plan.needsScan, let source = plan.sources.first {
            // One fetch counts and orders them all.
            guard let result = fetch(source) else { return PhotoSearchResult(assets: [], total: 0) }
            let count = min(limit, result.count)
            let assets = count > 0 ? result.objects(at: IndexSet(integersIn: 0..<count)).map(asset) : []
            return PhotoSearchResult(assets: assets, total: result.count)
        }

        var seen = Set<String>()
        var found: [PhotoAsset] = []
        var scanned = 0
        var isExact = true
        scan: for source in plan.sources {
            guard let result = fetch(source) else { continue }
            for index in 0..<result.count {
                if scanned >= maxScanned {
                    isExact = false
                    break scan
                }
                if scanned.isMultiple(of: 500), isCancelled() { throw CancellationError() }
                scanned += 1
                let item = result.object(at: index)
                let subtypes = item.mediaSubtypes
                guard !item.isHidden,
                      plan.passes(isFavorite: item.isFavorite, isLivePhoto: subtypes.contains(.photoLive),
                                  isScreenshot: subtypes.contains(.photoScreenshot)),
                      seen.insert(item.localIdentifier).inserted else { continue }
                found.append(asset(item))
            }
        }
        found.sort(by: PhotoMatching.newestFirst)
        return PhotoSearchResult(assets: Array(found.prefix(limit)), total: found.count, isTotalExact: isExact)
    }

    /// Newest first, never hidden items or every shot of a burst; the creation
    /// date and the media type as the predicate. The whole library and the
    /// smart albums hold the user's own photos (not those of shared albums,
    /// which only an album the user names includes).
    private static func fetchOptions(_ query: PhotoQuery, plan: PhotoFetchPlan,
                                     source: PhotoFetchPlan.Source) -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        if case .album = source {} else {
            options.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        }
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var parts: [NSPredicate] = []
        if let start = query.start {
            parts.append(NSPredicate(format: "creationDate >= %@", argumentArray: [start as NSDate]))
        }
        if let end = query.end {
            parts.append(NSPredicate(format: "creationDate < %@", argumentArray: [end as NSDate]))
        }
        if let type = plan.mediaType {
            let value = type == .video ? PHAssetMediaType.video.rawValue : PHAssetMediaType.image.rawValue
            parts.append(NSPredicate(format: "mediaType == %@", argumentArray: [NSNumber(value: value)]))
        }
        if !parts.isEmpty {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: parts)
        }
        return options
    }

    // MARK: The queue

    /// Runs `work` on the queue after checking that Orbit may read the
    /// library (a fetch without access would make PhotoKit ask the user).
    /// Cancelling the calling task makes a long scan stop early.
    private func perform<T: Sendable>(_ work: @escaping @Sendable (_ isCancelled: () -> Bool) throws -> T) async throws -> T {
        try Task.checkCancellation()
        switch access() {
        case .authorized, .limited: break
        case .unavailable: throw PhotoLibraryError.unavailable
        case .notDetermined, .denied, .restricted: throw PhotoLibraryError.notAuthorized
        }
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    guard !cancelled.withLock({ $0 }) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(with: Result { try work { cancelled.withLock { $0 } } })
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }

    // MARK: Conversion (on the queue)

    private static func asset(_ asset: PHAsset) -> PhotoAsset {
        let subtypes = asset.mediaSubtypes
        let type: PhotoItem.MediaType = switch asset.mediaType {
        case .image: subtypes.contains(.photoLive) ? .livePhoto : .image
        case .video: .video
        default: .other
        }
        return PhotoAsset(identifier: asset.localIdentifier, creationDate: asset.creationDate, mediaType: type,
                          isScreenshot: subtypes.contains(.photoScreenshot), isFavorite: asset.isFavorite,
                          duration: asset.mediaType == .video ? asset.duration : nil,
                          pixelWidth: asset.pixelWidth > 0 ? asset.pixelWidth : nil,
                          pixelHeight: asset.pixelHeight > 0 ? asset.pixelHeight : nil)
    }

    private static func title(of collection: PHAssetCollection) -> String? {
        guard let title = collection.localizedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        return Truncation.prefix(title, maxCharacters: maxTitleCharacters)
    }

    private static func smartAlbum(_ album: PhotoSmartAlbum) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: subtype(album), options: nil).firstObject
    }

    // MARK: Mapping (pure)

    /// PhotoKit's authorization as Orbit sees it.
    static func access(_ status: PHAuthorizationStatus) -> PhotoAccess {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }

    /// The collection subtype of a standard smart album.
    static func subtype(_ album: PhotoSmartAlbum) -> PHAssetCollectionSubtype {
        switch album {
        case .favorites: .smartAlbumFavorites
        case .library: .smartAlbumUserLibrary
        case .recentlyAdded: .smartAlbumRecentlyAdded
        case .videos: .smartAlbumVideos
        case .livePhotos: .smartAlbumLivePhotos
        case .screenshots: .smartAlbumScreenshots
        case .selfies: .smartAlbumSelfPortraits
        case .portraits: .smartAlbumDepthEffect
        case .panoramas: .smartAlbumPanoramas
        case .timeLapses: .smartAlbumTimelapses
        case .sloMo: .smartAlbumSlomoVideos
        case .bursts: .smartAlbumBursts
        case .longExposures: .smartAlbumLongExposures
        case .animated: .smartAlbumAnimated
        case .raw: .smartAlbumRAW
        case .cinematic: .smartAlbumCinematic
        }
    }
}
