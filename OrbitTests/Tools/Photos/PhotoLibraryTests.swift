import Foundation
import Photos
import Testing
@testable import Orbit

/// The photo library's pure parts: what a query means in memory, how the live
/// library answers it with PhotoKit (`PhotoFetchPlan`, only the plan, PhotoKit
/// itself never runs in tests), PhotoKit's statuses and smart albums as Orbit
/// sees them, and that PhotoKit's data APIs stay in the Live* files.
@Suite("Photo library")
struct PhotoLibraryTests {
    typealias T = PhotoTest

    private func query(start: String? = nil, end: String? = nil, favorites: Bool = false, albums: [String]? = nil,
                       type: PhotoMediaFilter? = nil, limit: Int = 100) -> PhotoQuery {
        PhotoQuery(start: start.map(T.date), end: end.map(T.date), favoritesOnly: favorites, albumIDs: albums, mediaType: type,
                   limit: limit)
    }

    private func search(_ query: PhotoQuery) throws -> [String] {
        try PhotoMatching.search(T.assets, query: query) { T.members[$0] }.assets.map(\.identifier)
    }

    // MARK: In memory

    @Test func aQueryMeansTheSameEverywhere() throws {
        #expect(try search(query(start: "2025-07-12T18:42", end: "2025-07-13T11:05")) == ["P2/L0/001"],
                "the start is included, the end is not")
        #expect(try search(query(favorites: true)) == ["P8/L0/001", "P7/L0/001", "P2/L0/001"])
        #expect(try search(query(type: .video)) == ["P8/L0/001", "P4/L0/001"])
        #expect(try search(query(type: .livePhoto)) == ["P3/L0/001"])
        #expect(try search(query(type: .screenshot)) == ["P9/L0/001"])
        #expect(try search(query(albums: ["album-urlaub", "album-familie-2"], type: .image))
            == ["P3/L0/001", "P2/L0/001", "P1/L0/001"], "several albums, each item once")
        #expect(throws: PhotoLibraryError.albumNotFound) { try search(query(albums: ["album-gone"])) }
        let limited = try PhotoMatching.search(T.assets, query: query(limit: 2)) { T.members[$0] }
        #expect(limited.assets.map(\.identifier) == ["P9/L0/001", "P8/L0/001"])
        #expect(limited.total == 10 && limited.isTotalExact)
    }

    @Test func newestFirstWithUndatedItemsLast() {
        let undated = T.photo("B", nil)
        let alsoUndated = T.photo("A", nil)
        let same = [T.photo("Y", "2025-07-12T10:00"), T.photo("X", "2025-07-12T10:00")]
        let sorted = ([undated, alsoUndated] + same + [T.photo("Z", "2026-01-01")]).sorted(by: PhotoMatching.newestFirst)
        #expect(sorted.map(\.identifier) == ["Z", "X", "Y", "A", "B"], "same time: by identifier, stable")
    }

    // MARK: The live library's plan

    @Test func oneFetchWhereThePredicateAndOneCollectionSuffice() {
        let all = Set(PhotoSmartAlbum.allCases)
        let plain = PhotoFetchPlan.make(query(start: "2025-07-01"), available: all)
        #expect(plain == PhotoFetchPlan(sources: [.library], mediaType: nil, checks: []))
        #expect(!plain.needsScan)
        #expect(PhotoFetchPlan.make(query(type: .video), available: all)
            == PhotoFetchPlan(sources: [.library], mediaType: .video, checks: []))
        #expect(PhotoFetchPlan.make(query(type: .image), available: all)
            == PhotoFetchPlan(sources: [.library], mediaType: .image, checks: []))
        #expect(PhotoFetchPlan.make(query(type: .livePhoto), available: all)
            == PhotoFetchPlan(sources: [.smartAlbum(.livePhotos)], mediaType: .image, checks: []))
        #expect(PhotoFetchPlan.make(query(type: .screenshot), available: all)
            == PhotoFetchPlan(sources: [.smartAlbum(.screenshots)], mediaType: .image, checks: []))
        #expect(PhotoFetchPlan.make(query(favorites: true, type: .video), available: all)
            == PhotoFetchPlan(sources: [.smartAlbum(.favorites)], mediaType: .video, checks: []))
        #expect(PhotoFetchPlan.make(query(albums: ["a"], type: .video), available: all)
            == PhotoFetchPlan(sources: [.album("a")], mediaType: .video, checks: []))
    }

    @Test func whatOneFetchCannotSayIsCheckedPerItem() throws {
        let all = Set(PhotoSmartAlbum.allCases)
        let favoriteLive = PhotoFetchPlan.make(query(favorites: true, type: .livePhoto), available: all)
        #expect(favoriteLive == PhotoFetchPlan(sources: [.smartAlbum(.favorites)], mediaType: .image, checks: [.livePhoto]))
        #expect(favoriteLive.needsScan)
        #expect(PhotoFetchPlan.make(query(favorites: true, albums: ["a"], type: .screenshot), available: all)
            == PhotoFetchPlan(sources: [.album("a")], mediaType: .image, checks: [.favorite, .screenshot]))
        let none = PhotoFetchPlan.make(query(albums: []), available: all)
        #expect(none.sources.isEmpty, "no album: nothing, like in memory")
        #expect(try search(query(albums: [])).isEmpty)
        let several = PhotoFetchPlan.make(query(albums: ["a", "b", "a"]), available: all)
        #expect(several.sources == [.album("a"), .album("b")])
        #expect(several.needsScan, "several albums are merged item by item")
        // Without the smart album the whole library is checked.
        #expect(PhotoFetchPlan.make(query(favorites: true), available: [])
            == PhotoFetchPlan(sources: [.library], mediaType: nil, checks: [.favorite]))
        #expect(PhotoFetchPlan.make(query(type: .livePhoto), available: [.favorites])
            == PhotoFetchPlan(sources: [.library], mediaType: .image, checks: [.livePhoto]))
        #expect(PhotoFetchPlan.make(query(favorites: true, type: .screenshot), available: [.screenshots])
            == PhotoFetchPlan(sources: [.library], mediaType: .image, checks: [.favorite, .screenshot]))
    }

    @Test func checksPassOnlyWhatTheyAskFor() {
        let plan = PhotoFetchPlan(sources: [.library], mediaType: nil, checks: [.favorite, .livePhoto])
        #expect(plan.passes(isFavorite: true, isLivePhoto: true, isScreenshot: false))
        #expect(!plan.passes(isFavorite: true, isLivePhoto: false, isScreenshot: false))
        #expect(!plan.passes(isFavorite: false, isLivePhoto: true, isScreenshot: true))
        #expect(PhotoFetchPlan(sources: [.library], mediaType: nil, checks: []).passes(isFavorite: false, isLivePhoto: false,
                                                                                      isScreenshot: false))
    }

    /// Every query the tool can make gives the same items through the plan
    /// as through `PhotoMatching`, checked by running the plan over the same
    /// photos in memory, as the live library runs it over PhotoKit's.
    @Test func thePlanFindsWhatTheQueryMeans() throws {
        let smart: [PhotoSmartAlbum: Set<String>] = [
            .favorites: Set(T.assets.filter(\.isFavorite).map(\.identifier)),
            .livePhotos: Set(T.assets.filter { $0.mediaType == .livePhoto }.map(\.identifier)),
            .screenshots: Set(T.assets.filter(\.isScreenshot).map(\.identifier)),
        ]
        for available in [Set(PhotoSmartAlbum.allCases), []] {
            for favorites in [false, true] {
                for type in [nil] + PhotoMediaFilter.allCases.map(Optional.some) {
                    for albums in [nil, ["album-urlaub"], ["album-familie", "album-urlaub"]] {
                        let query = query(start: "2025-07-01", favorites: favorites, albums: albums, type: type)
                        let plan = PhotoFetchPlan.make(query, available: available)
                        var found = Set<String>()
                        for source in plan.sources {
                            let inSource: Set<String>? = switch source {
                            case .library: nil
                            case .album(let id): T.members[id]
                            case .smartAlbum(let album): smart[album]
                            }
                            for asset in T.assets where inSource?.contains(asset.identifier) ?? true {
                                guard let date = asset.creationDate, date >= T.date("2025-07-01") else { continue }
                                let typeMatches = switch plan.mediaType {
                                case nil: true
                                case .image?: asset.mediaType == .image || asset.mediaType == .livePhoto
                                case .video?: asset.mediaType == .video
                                }
                                if typeMatches, plan.passes(isFavorite: asset.isFavorite, isLivePhoto: asset.mediaType == .livePhoto,
                                                            isScreenshot: asset.isScreenshot) {
                                    found.insert(asset.identifier)
                                }
                            }
                        }
                        #expect(found == Set(try search(query)), "\(favorites) \(String(describing: type)) \(String(describing: albums))")
                    }
                }
            }
        }
    }

    // MARK: PhotoKit as Orbit sees it (no PhotoKit call: values only)

    @Test func photoKitStatuses() {
        #expect(LivePhotoLibrary.access(.authorized) == .authorized)
        #expect(LivePhotoLibrary.access(.limited) == .limited)
        #expect(LivePhotoLibrary.access(.notDetermined) == .notDetermined)
        #expect(LivePhotoLibrary.access(.denied) == .denied)
        #expect(LivePhotoLibrary.access(.restricted) == .restricted)
        #expect(PhotoAccess.limited.allowsReading && PhotoAccess.authorized.allowsReading)
        #expect(!PhotoAccess.notDetermined.allowsReading && !PhotoAccess.unavailable.allowsReading)
        #expect(LivePermissionAccess.status(PhotoAccess.limited) == .granted, "the shared photos are enough for the tools")
        #expect(LivePermissionAccess.status(PhotoAccess.unavailable) == .restricted)
        #expect(LivePermissionAccess.status(PhotoAccess.notDetermined) == .notDetermined)
    }

    @Test func standardSmartAlbumsNeverIncludeHiddenOrDeletedItems() {
        let subtypes = PhotoSmartAlbum.allCases.map(LivePhotoLibrary.subtype)
        #expect(Set(subtypes.map(\.rawValue)).count == PhotoSmartAlbum.allCases.count, "one collection each")
        #expect(!subtypes.contains(.smartAlbumAllHidden))
        #expect(subtypes.allSatisfy { $0.rawValue >= 200 && $0.rawValue < 300 }, "public smart album subtypes only")
        #expect(LivePhotoLibrary.subtype(.favorites) == .smartAlbumFavorites)
        #expect(LivePhotoLibrary.subtype(.screenshots) == .smartAlbumScreenshots)
        #expect(LivePhotoLibrary.subtype(.livePhotos) == .smartAlbumLivePhotos)
    }

    @Test func smartAlbumsAreFoundByTheirEnglishNameToo() {
        let favorites = PhotoAlbum(identifier: "f", title: "Favoriten", kind: .smart(.favorites))
        #expect(favorites.names == ["Favoriten", "Favorites"])
        #expect(PhotoAlbum(identifier: "s", title: "Screenshots", kind: .smart(.screenshots)).names == ["Screenshots"])
        #expect(PhotoAlbum(identifier: "u", title: "Favoriten", kind: .user).names == ["Favoriten"])
        #expect(PhotoAlbumMatching.resolve("FAVORITES", in: [favorites]) == .found([favorites]))
        #expect(PhotoAlbumMatching.resolve("  ", in: [favorites]) == .notFound)
        let cafe = PhotoAlbum(identifier: "c", title: "Café Paris", kind: .user)
        #expect(PhotoAlbumMatching.resolve("cafe", in: [cafe, favorites]) == .found([cafe]), "accents and case ignored")
    }

    @Test func liveServicesAreOnlyConstructed() {
        // Constructing touches nothing: PhotoKit is used only by a tool call or a card.
        let library = LivePhotoLibrary()
        _ = library
        let thumbnails = LivePhotoThumbnails()
        #expect(thumbnails.cachedThumbnail(for: "P1/L0/001", pixels: 200) == nil)
        #expect(LivePhotoThumbnails.key("P1/L0/001", 200) == "200:P1/L0/001")
        #expect(LivePhotoThumbnails.size(200) == CGSize(width: 200, height: 200))
    }

    @Test func theThumbnailCacheIsBounded() {
        let cache = ThumbnailCache(costLimit: 1_000_000, countLimit: 2)
        guard case .image(let image) = T.thumbnail else {
            Issue.record("a picture")
            return
        }
        cache.insert(image, for: "a")
        #expect(cache.image(for: "a") != nil)
        cache.removeAll()
        #expect(cache.image(for: "a") == nil)
    }

    /// PhotoKit's data APIs (fetches, image requests, asking for access) live
    /// only in the Live* implementations; tests and the rest of Orbit go
    /// through the protocols.
    @Test func photoKitStaysInTheLiveImplementations() throws {
        let sources = PhotosScriptTests.repository.appendingPathComponent("Orbit")
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var importers: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let source = try String(contentsOf: url, encoding: .utf8)
            if source.contains("import Photos\n") { importers.append(url.lastPathComponent) }
            if !["LivePhotoLibrary.swift", "LivePhotoThumbnails.swift"].contains(url.lastPathComponent) {
                for api in ["PHAsset.fetch", "PHAssetCollection.fetch", "PHCachingImageManager", "PHImageManager", "requestImage("] {
                    #expect(!source.contains(api), "\(url.lastPathComponent) uses \(api)")
                }
            }
        }
        #expect(importers.sorted() == ["LivePermissionAccess.swift", "LivePhotoLibrary.swift", "LivePhotoThumbnails.swift"])
    }
}
