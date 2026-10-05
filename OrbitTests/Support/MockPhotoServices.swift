import CoreGraphics
import Foundation
import os
@testable import Orbit

/// Photos in memory (never PhotoKit). Answers like the live library (the
/// newest matching items, nothing without access: `PhotoMatching`) and
/// records every query, album lookup and access request. Asking for access
/// turns `.notDetermined` into `grantOnRequest ? .authorized : .denied`.
final class MockPhotoLibrary: PhotoLibrary, Sendable {
    private struct State: Sendable {
        var assets: [PhotoAsset]
        var albums: [PhotoAlbum]
        var members: [String: Set<String>]
        var access: PhotoAccess
        var grantOnRequest: Bool
        var accessRequests = 0
        var albumLookups = 0
        var queries: [PhotoQuery] = []
        var failure: PhotoLibraryError?
        var holdsSearches = false
    }

    private let state: OSAllocatedUnfairLock<State>

    init(assets: [PhotoAsset] = [], albums: [PhotoAlbum] = PhotoTest.albums, members: [String: Set<String>] = [:],
         access: PhotoAccess = .authorized, grantOnRequest: Bool = true) {
        state = OSAllocatedUnfairLock(initialState: State(assets: assets, albums: albums, members: members, access: access,
                                                          grantOnRequest: grantOnRequest))
    }

    var accessRequests: Int { state.withLock { $0.accessRequests } }
    var albumLookups: Int { state.withLock { $0.albumLookups } }
    var queries: [PhotoQuery] { state.withLock { $0.queries } }

    func setAccess(_ access: PhotoAccess) {
        state.withLock { $0.access = access }
    }

    /// Every following call fails with `error`.
    func fail(with error: PhotoLibraryError?) {
        state.withLock { $0.failure = error }
    }

    /// Searches wait until they are cancelled (to test the tool's cancellation).
    func holdSearches() {
        state.withLock { $0.holdsSearches = true }
    }

    // MARK: PhotoLibrary

    func access() -> PhotoAccess {
        state.withLock { $0.access }
    }

    func requestAccess() async -> PhotoAccess {
        state.withLock { state in
            state.accessRequests += 1
            if state.access == .notDetermined { state.access = state.grantOnRequest ? .authorized : .denied }
            return state.access
        }
    }

    func albums() async throws -> [PhotoAlbum] {
        try state.withLock { state in
            state.albumLookups += 1
            try Self.check(state)
            return state.albums
        }
    }

    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult {
        let (assets, members, holds) = try state.withLock { state in
            state.queries.append(query)
            try Self.check(state)
            return (state.assets, state.members, state.holdsSearches)
        }
        if holds {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        return try PhotoMatching.search(assets, query: query) { members[$0] }
    }

    private static func check(_ state: State) throws {
        if let failure = state.failure { throw failure }
        switch state.access {
        case .authorized, .limited: return
        case .unavailable: throw PhotoLibraryError.unavailable
        case .notDetermined, .denied, .restricted: throw PhotoLibraryError.notAuthorized
        }
    }
}

/// Thumbnails for tests: a tiny image (or what the test sets per photo),
/// every request, preparation and release recorded. `holdRequests()` makes
/// requests wait until their task is cancelled; then they answer
/// `.unavailable` and count as cancelled.
final class MockPhotoThumbnails: PhotoThumbnailProviding, Sendable {
    private struct State: Sendable {
        var results: [String: PhotoThumbnail] = [:]
        var cached: [String: PhotoThumbnail] = [:]
        var requests: [String] = []
        var cancelled: [String] = []
        var prepared: [[String]] = []
        var released: [[String]] = []
        var holds = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var requests: [String] { state.withLock { $0.requests } }
    var cancelled: [String] { state.withLock { $0.cancelled } }
    var prepared: [[String]] { state.withLock { $0.prepared } }
    var released: [[String]] { state.withLock { $0.released } }

    func set(_ thumbnail: PhotoThumbnail, for identifier: String) {
        state.withLock { $0.results[identifier] = thumbnail }
    }

    func setCached(_ thumbnail: PhotoThumbnail, for identifier: String) {
        state.withLock { $0.cached[identifier] = thumbnail }
    }

    func holdRequests() {
        state.withLock { $0.holds = true }
    }

    func thumbnail(for identifier: String, pixels: Int) async -> PhotoThumbnail {
        let (result, holds) = state.withLock { state in
            state.requests.append(identifier)
            return (state.results[identifier], state.holds)
        }
        if holds {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(2)) }
            state.withLock { $0.cancelled.append(identifier) }
            return .unavailable
        }
        return result ?? PhotoTest.thumbnail
    }

    func cachedThumbnail(for identifier: String, pixels: Int) -> PhotoThumbnail? {
        state.withLock { $0.cached[identifier] }
    }

    func prepare(_ identifiers: [String], pixels: Int) {
        state.withLock { $0.prepared.append(identifiers) }
    }

    func release(_ identifiers: [String], pixels: Int) {
        state.withLock { $0.released.append(identifiers) }
    }
}

/// Records the "open Photos" fallback of photo cards; nothing opens.
/// `failEverything()` makes every call throw.
final class RecordingPhotosAppOpener: PhotosAppOpening, Sendable {
    struct Failure: Error {}

    private let state = OSAllocatedUnfairLock(initialState: (opened: 0, failing: false))

    var opened: Int { state.withLock { $0.opened } }

    func failEverything() {
        state.withLock { $0.failing = true }
    }

    func openPhotos() async throws {
        let failing = state.withLock { state in
            if !state.failing { state.opened += 1 }
            return state.failing
        }
        if failing { throw Failure() }
    }
}

/// Invented photos and albums for tests, in Berlin.
enum PhotoTest {
    static let berlin = CalendarTest.berlin
    static let dates = CalendarTest.dates
    /// Sunday, 2026-10-04 20:00 in Berlin (CEST).
    static let now = CalendarTest.now

    static let urlaub = PhotoAlbum(identifier: "album-urlaub", title: "Urlaub 2025", kind: .user)
    static let urlaubAlt = PhotoAlbum(identifier: "album-urlaub-alt", title: "Urlaub 2024", kind: .user)
    static let familie = PhotoAlbum(identifier: "album-familie", title: "Familie", kind: .user)
    static let familieZwei = PhotoAlbum(identifier: "album-familie-2", title: "Familie", kind: .user)
    static let favoriten = PhotoAlbum(identifier: "smart-favorites", title: "Favoriten", kind: .smart(.favorites))
    static let bildschirmfotos = PhotoAlbum(identifier: "smart-screenshots", title: "Bildschirmfotos", kind: .smart(.screenshots))
    static let albums = [urlaub, urlaubAlt, familie, favoriten, bildschirmfotos]

    /// A 2×2 picture.
    static let thumbnail: PhotoThumbnail = {
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        return .image(context.makeImage()!)
    }()

    /// A date in Berlin ("2025-07-12T18:42" or "2025-07-12").
    static func date(_ text: String) -> Date {
        CalendarTest.date(text)
    }

    static func photo(_ id: String, _ date: String?, type: PhotoItem.MediaType = .image, screenshot: Bool = false,
                      favorite: Bool = false, duration: Double? = nil, width: Int? = 4032, height: Int? = 3024) -> PhotoAsset {
        PhotoAsset(identifier: id, creationDate: date.map(Self.date), mediaType: type, isScreenshot: screenshot,
                   isFavorite: favorite, duration: duration, pixelWidth: width, pixelHeight: height)
    }

    /// A summer holiday in July 2025, a family afternoon in September 2026 and today's screenshots.
    static let assets: [PhotoAsset] = [
        photo("P1/L0/001", "2025-07-12T09:40"),
        photo("P2/L0/001", "2025-07-12T18:42", favorite: true),
        photo("P3/L0/001", "2025-07-13T11:05", type: .livePhoto),
        photo("P4/L0/001", "2025-07-13T20:15", type: .video, duration: 95, width: 1920, height: 1080),
        photo("P5/L0/001", "2025-07-31T23:30"),
        photo("P6/L0/001", "2025-08-01T00:10"),
        photo("P7/L0/001", "2026-09-27T15:00", favorite: true),
        photo("P8/L0/001", "2026-09-27T15:05", type: .video, favorite: true, duration: 12, width: 1080, height: 1920),
        photo("P9/L0/001", "2026-10-04T09:14", screenshot: true, width: 2940, height: 1912),
        photo("P10/L0/001", nil),
    ]

    /// Album members of `assets`.
    static let members: [String: Set<String>] = [
        urlaub.identifier: ["P1/L0/001", "P2/L0/001", "P3/L0/001", "P4/L0/001"],
        urlaubAlt.identifier: [],
        familie.identifier: ["P7/L0/001", "P8/L0/001"],
        familieZwei.identifier: ["P2/L0/001"],
        favoriten.identifier: ["P2/L0/001", "P7/L0/001", "P8/L0/001"],
        bildschirmfotos.identifier: ["P9/L0/001"],
    ]

    static func library(access: PhotoAccess = .authorized, albums: [PhotoAlbum] = albums,
                        grantOnRequest: Bool = true) -> MockPhotoLibrary {
        MockPhotoLibrary(assets: assets, albums: albums, members: members, access: access, grantOnRequest: grantOnRequest)
    }

    static func context(_ library: MockPhotoLibrary, now: Date = now) -> PhotoToolContext {
        PhotoToolContext(library: library, now: { now }, timeZone: berlin)
    }

    static func tool(_ library: MockPhotoLibrary, now: Date = now) -> SearchPhotosTool {
        SearchPhotosTool(context: context(library, now: now))
    }

    /// The card's tiles of a result.
    static func items(_ result: ToolResult) -> [PhotoItem] {
        guard case .photos(let items)? = result.card else { return [] }
        return items
    }
}
