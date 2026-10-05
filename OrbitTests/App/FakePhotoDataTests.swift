#if DEBUG
import CoreGraphics
import Foundation
import Testing
@testable import Orbit

/// The DEBUG fake-data mode's photos (photos.json in
/// OrbitTests/Fixtures/PersonalData): relative dates, albums, the standard
/// albums, hidden and iCloud-only photos, the invented thumbnails and what
/// Orbit did, as `orbitctl state` shows it. PhotoKit and Photos are never
/// touched.
@Suite("Fake photo data (DEBUG)")
struct FakePhotoDataTests {
    typealias T = PhotoTest

    /// Launched on Sunday 2026-10-04 at 20:00 in Berlin.
    static func data(folder: URL = FakePersonalDataTests.fixtures, now: Date = T.now) -> (FakePhotoData, [String]) {
        var errors: [String] = []
        let data = FakePhotoData(folder: folder, now: now, timeZone: T.berlin, errors: &errors)
        return (data, errors)
    }

    static func tool(_ data: FakePhotoData) -> SearchPhotosTool {
        SearchPhotosTool(context: PhotoToolContext(library: FakePhotoLibrary(data: data), now: { T.now }, timeZone: T.berlin))
    }

    @Test func loadsTheInventedPhotos() throws {
        let (data, errors) = Self.data()
        #expect(errors.isEmpty)
        #expect(data.photos.count == 28 && data.visibleCount == 27, "one hidden photo")
        #expect(data.albums.map(\.title) == ["Wochenende am See", "Sommerurlaub 2025", "Familie", "Familienfeier 2024", "Rezepte",
                                             "Mediathek", "Favoriten", "Videos", "Live Photos", "Bildschirmfotos"])
        #expect(data.access() == .authorized && !data.automationDenied)
        let state = data.stateSummary()
        #expect(state["photos"] == 27 && state["photoAlbums"] == 10)
        #expect(state["photosAccess"] == "authorized" && state["shownPhotos"] == .array([]))
        #expect(state["openedPhotosApp"] == 0 && state["photoThumbnails"] == 0)
    }

    /// The acceptance flow on the fixtures: photos from a time range as a grid.
    @Test func julyTwentyTwentyFiveIsTheSummerHoliday() async throws {
        let (data, _) = Self.data()
        let result = try await Self.tool(data).run(arguments: ToolArguments(["from": "2025-07-01", "to": "2025-07-31"]))
        #expect(T.items(result).map(\.id) == (20...26).reversed().map { String(format: "ORBIT-FAKE-%04d/L0/001", $0) })
        #expect(result.summary == "Found 7 photos")
        #expect(result.text.contains("\n5. Sun 2025-07-13 11:05 | live photo | 4032x3024\n"))
        #expect(result.text.contains("\n4. Sun 2025-07-13 20:15 | video 1:35 | 1920x1080\n"))
        #expect(result.text.contains("\n1. Fri 2025-07-18 12:00 | photo | 4032x3024\n"), "in July, though not in the album")
        #expect(result.text.contains("| photo | favorite | 8000x2000"))
    }

    @Test func relativeDaysFollowTheLaunchDay() async throws {
        let (data, _) = Self.data()
        let tool = Self.tool(data)
        let today = try await tool.run(arguments: ToolArguments(["from": "2026-10-04", "to": "2026-10-04"]))
        #expect(T.items(today).map(\.id) == ["ORBIT-FAKE-0002/L0/001", "ORBIT-FAKE-0001/L0/001", "ORBIT-FAKE-0003/L0/001"])
        let screenshots = try await tool.run(arguments: ToolArguments(["media_type": "screenshot"]))
        #expect(T.items(screenshots).map(\.isScreenshot) == [true, true])
        let lake = try await tool.run(arguments: ToolArguments(["album": "Wochenende am See"]))
        #expect(T.items(lake).count == 8)
        #expect(T.items(lake).first?.creationDate == T.date("2026-09-28T16:20"), "six days before the launch day")
        let lakeVideos = try await tool.run(arguments: ToolArguments(["album": "wochenende", "media_type": "video"]))
        #expect(lakeVideos.summary == "Found 2 videos")
        // Launched another day, "today" moves along.
        let (later, _) = Self.data(now: T.date("2026-12-24T09:00"))
        let christmas = try await Self.tool(later).run(arguments: ToolArguments(["from": "2026-12-24", "to": "2026-12-24"]))
        #expect(T.items(christmas).count == 3)
    }

    @Test func theStandardAlbumsFollowFromThePhotos() async throws {
        let (data, _) = Self.data()
        let tool = Self.tool(data)
        let favorites = try await tool.run(arguments: ToolArguments(["album": "Favorites"]))
        #expect(T.items(favorites).count == 7 && T.items(favorites).allSatisfy { $0.isFavorite })
        let favoritesFilter = try await tool.run(arguments: ToolArguments(["favorites_only": true]))
        #expect(T.items(favoritesFilter).map(\.id) == T.items(favorites).map(\.id))
        let videos = try await tool.run(arguments: ToolArguments(["album": "Videos"]))
        #expect(T.items(videos).count == 5)
        let live = try await tool.run(arguments: ToolArguments(["media_type": "live_photo"]))
        #expect(T.items(live).count == 3)
        let everything = try await tool.run(arguments: ToolArguments(["limit": 100]))
        #expect(T.items(everything).count == 27)
        #expect(!T.items(everything).contains { $0.id == "ORBIT-FAKE-0006/L0/001" }, "hidden photos never appear")
        await #expect(throws: ToolError.self) { try await tool.run(arguments: ToolArguments(["album": "Fami"])) }
    }

    @Test func placeholderThumbnailsAreInvented() async throws {
        let (data, _) = Self.data()
        let thumbnails = FakePhotoThumbnails(data: data)
        guard case .image(let wide) = await thumbnails.thumbnail(for: "ORBIT-FAKE-0014/L0/001", pixels: 200) else {
            Issue.record("a picture")
            return
        }
        #expect(wide.width == 800 && wide.height == 200, "a panorama at 4:1 at most, the shorter side as asked")
        guard case .image(let tall) = await thumbnails.thumbnail(for: "ORBIT-FAKE-0008/L0/001", pixels: 200),
              case .image(let screenshot) = await thumbnails.thumbnail(for: "ORBIT-FAKE-0001/L0/001", pixels: 200) else {
            Issue.record("pictures")
            return
        }
        #expect(tall.width == 200 && tall.height == 267)
        #expect(screenshot.width == 308 && screenshot.height == 200)
        #expect(await thumbnails.thumbnail(for: "ORBIT-FAKE-0019/L0/001", pixels: 200) == .inCloud, "only in iCloud: none")
        #expect(await thumbnails.thumbnail(for: "ORBIT-FAKE-0006/L0/001", pixels: 200) == .unavailable, "hidden")
        #expect(await thumbnails.thumbnail(for: "unknown", pixels: 200) == .unavailable)
        #expect(data.stateSummary()["photoThumbnails"] == 6)
        // The same picture for the same photo, every time.
        let again = PlaceholderPhoto.image(seed: "x", color: "#336699", mediaType: .image, isScreenshot: false, width: 20, height: 10)
        let other = PlaceholderPhoto.image(seed: "x", color: "#336699", mediaType: .image, isScreenshot: false, width: 20, height: 10)
        #expect(again?.dataProvider?.data as Data? == other?.dataProvider?.data as Data?)
        #expect(PlaceholderPhoto.stableHash("ORBIT") == PlaceholderPhoto.stableHash("ORBIT"))
        #expect(PlaceholderPhoto.size(width: nil, height: nil, shorterSide: 200) == (200, 200))
        #expect(PlaceholderPhoto.image(seed: "x", color: nil, mediaType: .video, isScreenshot: false, width: 0, height: 10) == nil)
    }

    @Test func showingAPhotoIsRecorded() async throws {
        let fake = FakePersonalData(directory: FakePersonalDataTests.fixtures.path)
        let service = PhotosService(runner: FakeAppleScriptRunner(data: fake))
        try await service.show(id: "ORBIT-FAKE-0004/L0/001")
        await #expect(throws: PhotosFailure.itemNotFound) { try await service.show(id: "ORBIT-FAKE-0006/L0/001") }
        try await FakePhotosAppOpener(data: fake.photos).openPhotos()
        let state = fake.stateSummary()
        #expect(state["shownPhotos"] == ["ORBIT-FAKE-0004/L0/001", "ORBIT-FAKE-0006/L0/001"])
        #expect(state["openedPhotosApp"] == 1)
        #expect(state["scriptRuns"] == ["photos-show", "photos-show"])
    }

    @Test func accessAndAutomationComeFromTheFile() async throws {
        let folder = try TemporaryFolder("fake-photos")
        defer { folder.remove() }
        try folder.write("photos.json", #"{"access": "notDetermined", "automation": "denied", "photos": [{"day": 0}]}"#)
        let fake = FakePersonalData(directory: folder.path)
        #expect(fake.errors.isEmpty)
        let access = FakePermissionAccess(data: fake)
        #expect(access.status(of: .photos) == .notDetermined)
        #expect(access.status(of: .automationPhotos) == .denied)
        let tool = SearchPhotosTool(context: PhotoToolContext(library: FakePhotoLibrary(data: fake.photos)))
        let result = try await tool.run(arguments: ToolArguments([:]))
        #expect(T.items(result).count == 1, "the fake user allows access when asked")
        #expect(T.items(result).first?.id == "ORBIT-FAKE-0001/L0/001")
        #expect(access.status(of: .photos) == .granted)
        let service = PhotosService(runner: FakeAppleScriptRunner(data: fake))
        await #expect(throws: AppleScriptError.notAuthorized(.photos)) { try await service.show(id: "ORBIT-FAKE-0001/L0/001") }
        #expect(await access.request(.photos) == .granted)
        let state = fake.stateSummary()
        #expect(state["photosAccessRequests"] == 2, "the tool's request and the click on Erlauben")
        #expect(state["photosAutomation"] == "denied")
        #expect(state["permissionRequests"] == ["photos"])

        try folder.write("photos.json", #"{"access": "denied"}"#)
        let denied = FakePersonalData(directory: folder.path)
        let deniedTool = SearchPhotosTool(context: PhotoToolContext(library: FakePhotoLibrary(data: denied.photos)))
        await #expect(throws: ToolError.permissionDenied(.photos)) { try await deniedTool.run(arguments: ToolArguments([:])) }
        #expect(await FakePhotoThumbnails(data: denied.photos).thumbnail(for: "ORBIT-FAKE-0001/L0/001", pixels: 200) == .unavailable)
    }

    @Test func mistakesInTheFileAreReported() throws {
        let folder = try TemporaryFolder("fake-photos")
        defer { folder.remove() }
        try folder.write("photos.json", #"{"access": "sometimes", "photos": [{"type": "gif"}, {"time": "25:00"}, {"date": "gestern"}, {"albums": ["Neu"]}]}"#)
        let (data, errors) = Self.data(folder: folder.url)
        #expect(errors == ["'gif' is no photo type (photo, livePhoto, video or screenshot).", "'25:00' is not a time (\"HH:mm\").",
                           "'gestern' is not an ISO 8601 date.",
                           "'sometimes' is no access (authorized, limited, notDetermined, denied or restricted)."])
        #expect(data.photos.count == 1)
        #expect(data.albums.first?.title == "Neu", "an album a photo names is made")
        try folder.write("photos.json", "{ kaputt")
        let (broken, brokenErrors) = Self.data(folder: folder.url)
        #expect(broken.photos.isEmpty && brokenErrors.first?.hasPrefix("photos.json could not be read") == true)
    }

    @Test func theAppUsesTheFakePhotosEndToEnd() async throws {
        let services = AppServices.live(environment: [FakePersonalData.variable: FakePersonalDataTests.fixtures.path],
                                        orbitDataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("orbit-fake-data"))
        #expect(services.photoLibrary is FakePhotoLibrary)
        #expect(services.photoThumbnails is FakePhotoThumbnails)
        #expect(services.photosApp is FakePhotosAppOpener)
        let tools = AppEnvironment.makeTools(services: services)
        let search = try #require(tools.first { $0.name == "search_photos" })
        let result = try await search.run(arguments: ToolArguments(["album": "Sommerurlaub 2025"]))
        #expect(result.summary == "Found 6 photos")
        let state = try #require(services.debugPersonalDataState?())
        #expect(state["photos"] == 27)
        let restricted = AppServices.live(environment: ["ORBIT_DEBUG_FILE_SCOPE": NSTemporaryDirectory()],
                                          orbitDataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("orbit-fake-data"))
        #expect(restricted.photoLibrary is UnavailablePhotoLibrary, "a restricted session never reaches the photos")
        #expect(restricted.photoThumbnails is UnavailablePhotoThumbnails)
        #expect(restricted.photosApp is DisabledPhotosAppOpener)
    }
}
#endif
