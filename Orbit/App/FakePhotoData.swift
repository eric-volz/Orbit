#if DEBUG
import CoreGraphics
import Foundation
import os

/// DEBUG only: invented photos for the fake-data mode (`FakePersonalData`,
/// ORBIT_DEBUG_FAKE_PERSONAL_DATA). `FakePhotoLibrary` answers `search_photos`
/// from `photos.json` like PhotoKit would (newest first, hidden photos never,
/// nothing without access), `FakePhotoThumbnails` draws invented placeholder
/// pictures for the cards (never a real photo; a photo marked `inCloud` has
/// none, like one that is only in iCloud), and what a card would show in
/// Photos (the photos-show script) or the "open Photos" fallback are only
/// recorded. PhotoKit and Photos are never touched; `orbitctl state` reports
/// what Orbit did.
///
/// Dates are relative to the launch day, so "this week" always has photos:
/// `day` (0 = today, -1 = yesterday) and a local time "HH:mm" in the current
/// time zone, or an ISO 8601 `date`.
///
/// `photos.json` (every key optional):
/// `{"access": "authorized" | "limited" | "notDetermined" | "denied" | "restricted",
///   "automation": "granted" | "denied",
///   "albums": [{"id": "…", "title": "Wochenende am See"}],
///   "photos": [{"id": "ORBIT-FAKE-0001/L0/001", "day": -7, "time": "10:12", "date": "2025-07-12T18:42",
///     "type": "photo" | "livePhoto" | "video" | "screenshot", "favorite": true, "duration": 42,
///     "width": 4032, "height": 3024, "albums": ["Wochenende am See"], "hidden": false, "inCloud": false,
///     "color": "#F4A261"}]}`
/// A photo's `albums` names albums by title (unknown titles become albums).
/// The standard albums Favoriten, Videos, Live Photos, Bildschirmfotos and
/// Mediathek follow from the photos.
final class FakePhotoData: Sendable {
    static let file = "photos.json"

    struct Photo: Sendable, Hashable {
        var asset: PhotoAsset
        var isHidden = false
        /// Only in iCloud: no thumbnail.
        var isInCloud = false
        /// "#RRGGBB" the placeholder is drawn in (else one from the identifier).
        var color: String?
        /// The user albums it is in (identifiers).
        var albumIDs: Set<String> = []
    }

    private struct State: Sendable {
        var access: PhotoAccess
        var accessRequests = 0
        var shownPhotos: [String] = []
        var openedPhotosApp = 0
        var thumbnails = 0
    }

    /// Every photo in the file, hidden ones included.
    let photos: [Photo]
    /// The user's albums, then the standard ones.
    let albums: [PhotoAlbum]
    let automationDenied: Bool
    /// Album identifier → the photos in it (hidden ones never).
    private let members: [String: Set<String>]
    private let state: OSAllocatedUnfairLock<State>

    init(folder: URL?, now launch: Date, timeZone: TimeZone = .current, errors: inout [String]) {
        let dates = CalendarDates(timeZone: timeZone)
        let today = dates.startOfDay(launch)
        let file = folder.flatMap { Self.decode($0.appendingPathComponent(Self.file), errors: &errors) } ?? PhotosFile()

        var userAlbums = (file.albums ?? []).enumerated().map { index, entry in
            PhotoAlbum(identifier: entry.id ?? "orbit-fake-album-\(index + 1)", title: entry.title, kind: .user)
        }
        var photos: [Photo] = []
        for (index, entry) in (file.photos ?? []).enumerated() {
            guard let photo = Self.photo(entry, number: index + 1, albums: &userAlbums, today: today, dates: dates,
                                         errors: &errors) else { continue }
            photos.append(photo)
        }
        let visible = photos.filter { !$0.isHidden }
        var members: [String: Set<String>] = [:]
        for album in userAlbums {
            members[album.identifier] = Set(visible.filter { $0.albumIDs.contains(album.identifier) }.map(\.asset.identifier))
        }
        let standard: [(PhotoSmartAlbum, String, (PhotoAsset) -> Bool)] = [
            (.library, "Mediathek", { _ in true }),
            (.favorites, "Favoriten", { $0.isFavorite }),
            (.videos, "Videos", { $0.mediaType == .video }),
            (.livePhotos, "Live Photos", { $0.mediaType == .livePhoto }),
            (.screenshots, "Bildschirmfotos", { $0.isScreenshot }),
        ]
        var smartAlbums: [PhotoAlbum] = []
        for (album, title, includes) in standard {
            let identifier = "orbit-fake-smart-\(album.rawValue)"
            smartAlbums.append(PhotoAlbum(identifier: identifier, title: title, kind: .smart(album)))
            members[identifier] = Set(visible.map(\.asset).filter(includes).map(\.identifier))
        }
        self.photos = photos
        albums = userAlbums + smartAlbums
        self.members = members
        automationDenied = file.automation?.lowercased() == "denied"
        state = OSAllocatedUnfairLock(initialState: State(access: Self.access(file.access, errors: &errors)))
    }

    /// Photos in the file that a search can find (not hidden).
    var visibleCount: Int {
        photos.filter { !$0.isHidden }.count
    }

    // MARK: Access

    func access() -> PhotoAccess {
        state.withLock { $0.access }
    }

    /// Asking for access: recorded; the fake user agrees when undecided (like a click on Allow).
    func requestAccess() -> PhotoAccess {
        state.withLock { state in
            state.accessRequests += 1
            if state.access == .notDetermined { state.access = .authorized }
            return state.access
        }
    }

    // MARK: Library

    func albumList() throws -> [PhotoAlbum] {
        guard access().allowsReading else { throw PhotoLibraryError.notAuthorized }
        return albums
    }

    func search(_ query: PhotoQuery) throws -> PhotoSearchResult {
        guard access().allowsReading else { throw PhotoLibraryError.notAuthorized }
        let visible = photos.filter { !$0.isHidden }.map(\.asset)
        return try PhotoMatching.search(visible, query: query) { members[$0] }
    }

    // MARK: Cards

    /// A placeholder thumbnail, invented, drawn here.
    func thumbnail(for identifier: String, pixels: Int) -> PhotoThumbnail {
        state.withLock { $0.thumbnails += 1 }
        guard access().allowsReading, let photo = photos.first(where: { $0.asset.identifier == identifier && !$0.isHidden }) else {
            return .unavailable
        }
        if photo.isInCloud { return .inCloud }
        let size = PlaceholderPhoto.size(width: photo.asset.pixelWidth, height: photo.asset.pixelHeight, shorterSide: pixels)
        return PlaceholderPhoto.image(seed: identifier, color: photo.color, mediaType: photo.asset.mediaType,
                                      isScreenshot: photo.asset.isScreenshot, width: size.width, height: size.height)
            .map(PhotoThumbnail.image) ?? .unavailable
    }

    /// Answers the photos-show script like the real one would; nil for other scripts.
    func runScript(_ name: String, arguments: [String]) throws -> String? {
        guard name == PhotosService.showScript.name else { return nil }
        if automationDenied { throw AppleScriptError.notAuthorized(.photos) }
        guard let identifier = arguments.first else {
            throw AppleScriptError.failed(number: 1000, message: "photos-show expects 1 argument")
        }
        state.withLock { $0.shownPhotos.append(identifier) }
        let known = photos.contains { $0.asset.identifier == identifier && !$0.isHidden }
        return try FakePersonalData.encode(known ? PhotosService.ShowAnswer(shown: true) : PhotosService.ShowAnswer(error: "notFound"))
    }

    func recordOpenedPhotosApp() {
        state.withLock { $0.openedPhotosApp += 1 }
    }

    // MARK: State

    /// For `orbitctl state`: counts, access and what Orbit did.
    func stateSummary() -> [String: JSONValue] {
        let snapshot = state.withLock { $0 }
        return [
            "photos": .number(Double(visibleCount)),
            "photoAlbums": .number(Double(albums.count)),
            "photosAccess": .string(Self.name(of: snapshot.access)),
            "photosAccessRequests": .number(Double(snapshot.accessRequests)),
            "photosAutomation": .string(automationDenied ? "denied" : "granted"),
            "shownPhotos": .array(snapshot.shownPhotos.map(JSONValue.string)),
            "openedPhotosApp": .number(Double(snapshot.openedPhotosApp)),
            "photoThumbnails": .number(Double(snapshot.thumbnails)),
        ]
    }

    static func name(of access: PhotoAccess) -> String {
        switch access {
        case .authorized: "authorized"
        case .limited: "limited"
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .unavailable: "unavailable"
        }
    }

    // MARK: File

    private struct PhotosFile: Decodable {
        struct Album: Decodable {
            var id: String?
            var title: String
        }

        struct Entry: Decodable {
            var id: String?
            var day: Int?
            var time: String?
            var date: String?
            var type: String?
            var favorite: Bool?
            var duration: Double?
            var width: Int?
            var height: Int?
            var albums: [String]?
            var hidden: Bool?
            var inCloud: Bool?
            var color: String?
        }

        var access: String?
        var automation: String?
        var albums: [Album]?
        var photos: [Entry]?
    }

    private static func decode(_ url: URL, errors: inout [String]) -> PhotosFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(PhotosFile.self, from: Data(contentsOf: url))
        } catch {
            errors.append("\(url.lastPathComponent) could not be read: \(error)")
            return nil
        }
    }

    private static func photo(_ entry: PhotosFile.Entry, number: Int, albums: inout [PhotoAlbum], today: Date,
                              dates: CalendarDates, errors: inout [String]) -> Photo? {
        guard let date = date(entry, today: today, dates: dates, errors: &errors) else { return nil }
        let type: PhotoItem.MediaType
        var isScreenshot = false
        switch entry.type?.lowercased() {
        case nil, "photo", "image": type = .image
        case "livephoto", "live_photo": type = .livePhoto
        case "video": type = .video
        case "screenshot":
            type = .image
            isScreenshot = true
        case let other?:
            errors.append("'\(other)' is no photo type (photo, livePhoto, video or screenshot).")
            return nil
        }
        var albumIDs = Set<String>()
        for title in entry.albums ?? [] {
            if let album = albums.first(where: { $0.title == title || $0.identifier == title }) {
                albumIDs.insert(album.identifier)
            } else {
                let album = PhotoAlbum(identifier: "orbit-fake-album-\(albums.count + 1)", title: title, kind: .user)
                albums.append(album)
                albumIDs.insert(album.identifier)
            }
        }
        let asset = PhotoAsset(identifier: entry.id ?? String(format: "ORBIT-FAKE-%04d/L0/001", number), creationDate: date,
                               mediaType: type, isScreenshot: isScreenshot, isFavorite: entry.favorite ?? false,
                               duration: type == .video ? (entry.duration ?? 10) : nil,
                               pixelWidth: entry.width ?? (type == .video ? 1920 : 4032),
                               pixelHeight: entry.height ?? (type == .video ? 1080 : 3024))
        return Photo(asset: asset, isHidden: entry.hidden ?? false, isInCloud: entry.inCloud ?? false, color: entry.color,
                     albumIDs: albumIDs)
    }

    /// `date` (ISO 8601), or `day` with "HH:mm" (default 12:00) in the zone.
    private static func date(_ entry: PhotosFile.Entry, today: Date, dates: CalendarDates, errors: inout [String]) -> Date? {
        if let text = entry.date {
            guard let parsed = FlexibleDate.parse(text, timeZone: dates.timeZone) else {
                errors.append("'\(text)' is not an ISO 8601 date.")
                return nil
            }
            return parsed.date
        }
        let day = dates.day(entry.day ?? 0, after: today)
        let time = entry.time ?? "12:00"
        let parts = time.split(separator: ":")
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0...23).contains(hour),
              (0...59).contains(minute),
              let date = dates.calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else {
            errors.append("'\(time)' is not a time (\"HH:mm\").")
            return nil
        }
        return date
    }

    private static func access(_ text: String?, errors: inout [String]) -> PhotoAccess {
        switch text?.lowercased() {
        case nil, "authorized", "granted", "fullaccess": return .authorized
        case "limited": return .limited
        case "notdetermined": return .notDetermined
        case "denied": return .denied
        case "restricted": return .restricted
        case let other?:
            errors.append("'\(other)' is no access (authorized, limited, notDetermined, denied or restricted).")
            return .authorized
        }
    }
}

/// The invented photos as the Photos library (DEBUG fake-data mode).
struct FakePhotoLibrary: PhotoLibrary {
    let data: FakePhotoData

    func access() -> PhotoAccess { data.access() }
    func requestAccess() async -> PhotoAccess { data.requestAccess() }
    func albums() async throws -> [PhotoAlbum] { try data.albumList() }

    func search(_ query: PhotoQuery) async throws -> PhotoSearchResult {
        try Task.checkCancellation()
        return try data.search(query)
    }
}

/// Placeholder thumbnails for the invented photos (DEBUG fake-data mode).
struct FakePhotoThumbnails: PhotoThumbnailProviding {
    let data: FakePhotoData

    func thumbnail(for identifier: String, pixels: Int) async -> PhotoThumbnail {
        guard !Task.isCancelled else { return .unavailable }
        return data.thumbnail(for: identifier, pixels: pixels)
    }
}

/// The "open Photos" fallback in the DEBUG fake-data mode: recorded, Photos never opens.
struct FakePhotosAppOpener: PhotosAppOpening {
    let data: FakePhotoData

    func openPhotos() async throws {
        data.recordOpenedPhotosApp()
    }
}

/// Invented pictures that stand in for photos (DEBUG fake-data mode, tests):
/// a sky, a sun and hills, or for a screenshot a window with lines of "text",
/// in colors from the photo's `color` or its identifier. Drawn with Core
/// Graphics, the same for the same identifier; never a real photo.
enum PlaceholderPhoto {
    /// The size of a thumbnail with the photo's aspect ratio whose shorter side is `shorterSide`.
    static func size(width: Int?, height: Int?, shorterSide: Int) -> (width: Int, height: Int) {
        let side = max(1, shorterSide)
        guard let width, let height, width > 0, height > 0 else { return (side, side) }
        // Very wide or tall pictures (panoramas) are capped at 4:1, like a tile shows them.
        let ratio = min(max(Double(width) / Double(height), 0.25), 4)
        return ratio >= 1 ? (Int((Double(side) * ratio).rounded()), side) : (side, Int((Double(side) / ratio).rounded()))
    }

    static func image(seed: String, color: String?, mediaType: PhotoItem.MediaType, isScreenshot: Bool,
                      width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, width <= 4_096, height <= 4_096,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let hash = stableHash(seed)
        let base = color.flatMap(Theme.rgbComponents(fromHex:)) ?? hue(Double(hash % 360) / 360)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if isScreenshot {
            drawScreenshot(in: context, bounds: bounds, accent: base, hash: hash)
        } else {
            drawLandscape(in: context, bounds: bounds, base: base, hash: hash, dark: mediaType == .video)
        }
        return context.makeImage()
    }

    private typealias RGB = (red: Double, green: Double, blue: Double)

    private static func drawLandscape(in context: CGContext, bounds: CGRect, base: RGB, hash: UInt64, dark: Bool) {
        let shade = dark ? 0.55 : 1.0
        let sky = [mix(base, white: 0.55, shade: shade), mix(base, white: 0.15, shade: shade)]
        let colors = sky.map { CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) } as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: bounds.maxY), end: CGPoint(x: 0, y: 0), options: [])
        }
        // The sun.
        let radius = min(bounds.width, bounds.height) * 0.12
        let sunX = bounds.width * (0.2 + Double(hash % 60) / 100)
        context.setFillColor(CGColor(srgbRed: 1, green: 0.93 * shade, blue: 0.6 * shade, alpha: 0.95))
        context.fillEllipse(in: CGRect(x: sunX - radius, y: bounds.height * 0.68 - radius, width: radius * 2, height: radius * 2))
        // Two hills.
        for (index, lightness) in [0.35, 0.15].enumerated() {
            let peak = bounds.width * (index == 0 ? 0.3 + Double((hash >> 8) % 20) / 100 : 0.7 - Double((hash >> 16) % 20) / 100)
            let top = bounds.height * (index == 0 ? 0.55 : 0.42)
            let hill = mix(base, white: -lightness, shade: shade)
            context.setFillColor(CGColor(srgbRed: hill.red, green: hill.green, blue: hill.blue, alpha: 1))
            context.beginPath()
            context.move(to: CGPoint(x: peak - bounds.width * 0.75, y: 0))
            context.addLine(to: CGPoint(x: peak, y: top))
            context.addLine(to: CGPoint(x: peak + bounds.width * 0.75, y: 0))
            context.closePath()
            context.fillPath()
        }
    }

    private static func drawScreenshot(in context: CGContext, bounds: CGRect, accent: RGB, hash: UInt64) {
        context.setFillColor(CGColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1))
        context.fill(bounds)
        let window = bounds.insetBy(dx: bounds.width * 0.08, dy: bounds.height * 0.1)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(window)
        let bar = CGRect(x: window.minX, y: window.maxY - window.height * 0.14, width: window.width, height: window.height * 0.14)
        context.setFillColor(CGColor(srgbRed: accent.red, green: accent.green, blue: accent.blue, alpha: 1))
        context.fill(bar)
        context.setFillColor(CGColor(srgbRed: 0.78, green: 0.8, blue: 0.84, alpha: 1))
        let lineHeight = window.height * 0.06
        var y = bar.minY - lineHeight * 2
        var line = 0
        while y > window.minY + lineHeight {
            let length = 0.45 + Double((hash >> UInt64(line % 32)) % 45) / 100
            context.fill(CGRect(x: window.minX + window.width * 0.08, y: y, width: window.width * 0.84 * length, height: lineHeight))
            y -= lineHeight * 2
            line += 1
        }
    }

    /// Lighter (`white` > 0) or darker (< 0), then dimmed by `shade`.
    private static func mix(_ color: RGB, white: Double, shade: Double) -> RGB {
        func channel(_ value: Double) -> Double {
            let mixed = white >= 0 ? value + (1 - value) * white : value * (1 + white)
            return min(max(mixed * shade, 0), 1)
        }
        return (channel(color.red), channel(color.green), channel(color.blue))
    }

    private static func hue(_ hue: Double) -> RGB {
        let sector = hue * 6
        let fraction = sector - sector.rounded(.down)
        switch Int(sector) % 6 {
        case 0: return (0.85, 0.35 + 0.5 * fraction, 0.35)
        case 1: return (0.85 - 0.5 * fraction, 0.85, 0.35)
        case 2: return (0.35, 0.85, 0.35 + 0.5 * fraction)
        case 3: return (0.35, 0.85 - 0.5 * fraction, 0.85)
        case 4: return (0.35 + 0.5 * fraction, 0.35, 0.85)
        default: return (0.85, 0.35, 0.85 - 0.5 * fraction)
        }
    }

    /// FNV-1a: the same for the same text in every run (unlike `hashValue`).
    static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
#endif
