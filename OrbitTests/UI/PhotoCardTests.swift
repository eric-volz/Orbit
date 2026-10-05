import Foundation
import Testing
@testable import Orbit

/// Photo cards: what a click or Return does (show in Photos, else open
/// Photos), what VoiceOver hears, the grid's columns and keyboard moves, that
/// the keyboard reaches the card, and old chats (the keyboard paths in the
/// real panel: `PhotoCardKeyboardTests`, gated). Nothing opens: the script
/// runner and the Photos opener are mocks.
@Suite("Photo cards")
@MainActor
struct PhotoCardTests {
    private let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = PhotoTest.berlin
        return calendar
    }()

    private let german = Locale(identifier: "de_DE")

    static let photo = PhotoItem(id: "P2/L0/001", creationDate: PhotoTest.date("2025-07-12T18:42"), mediaType: .image,
                                 isFavorite: true, duration: nil, pixelWidth: 4032, pixelHeight: 3024)
    static let video = PhotoItem(id: "P4/L0/001", creationDate: PhotoTest.date("2026-09-27T15:05"), mediaType: .video,
                                 isFavorite: false, duration: 75, pixelWidth: 1920, pixelHeight: 1080)

    private func actions(_ runner: MockAppleScriptRunner, opener: RecordingPhotosAppOpener = RecordingPhotosAppOpener())
        -> PhotoCardActions {
        PhotoCardActions(photos: PhotosService(runner: runner), opener: opener, thumbnails: MockPhotoThumbnails())
    }

    // MARK: Showing a photo

    @Test func aClickShowsThePhotoInPhotos() async {
        let runner = MockAppleScriptRunner(output: #"{"shown":true}"#)
        let opener = RecordingPhotosAppOpener()
        let actions = actions(runner, opener: opener)
        await actions.show(Self.photo).value
        #expect(runner.runs == [.init(script: "photos-show", arguments: ["P2/L0/001"])])
        #expect(opener.opened == 0, "Photos showed the photo itself")
        #expect(actions.failure == nil)
    }

    /// When Photos cannot show the photo, Photos opens instead and the note says why.
    @Test(arguments: [
        (AppleScriptError.notFound, PhotoCardActions.Failure.Reason.notFound),
        (AppleScriptError.timedOut, .notShown),
        (AppleScriptError.disabled, .notShown),
        (AppleScriptError.failed(number: -10000, message: "x"), .notShown),
    ])
    func whenPhotosCannotShowItPhotosOpens(error: AppleScriptError, reason: PhotoCardActions.Failure.Reason) async {
        let opener = RecordingPhotosAppOpener()
        let actions = actions(MockAppleScriptRunner { _, _ in throw error }, opener: opener)
        await actions.show(Self.photo).value
        #expect(opener.opened == 1)
        #expect(actions.failure == .init(reason: reason, count: 1))
    }

    @Test func aPhotoPhotosDoesNotKnowOpensPhotos() async {
        let opener = RecordingPhotosAppOpener()
        let actions = actions(MockAppleScriptRunner(output: #"{"error":"notFound"}"#), opener: opener)
        await actions.show(Self.photo).value
        #expect(opener.opened == 1)
        #expect(actions.failure == .init(reason: .notFound, count: 1))
        #expect(InputHint(photoFailure: actions.failure!).text
            == "Photos did not find the photo, so Orbit opened the Photos app instead.")
    }

    /// Without the permission nothing opens: the note says why and where to allow it.
    @Test func withoutThePermissionTheNoteExplainsIt() async {
        let opener = RecordingPhotosAppOpener()
        let actions = actions(MockAppleScriptRunner { _, _ in throw AppleScriptError.notAuthorized(.photos) }, opener: opener)
        await actions.show(Self.photo).value
        #expect(opener.opened == 0)
        #expect(actions.failure == .init(reason: .notPermitted, count: 1))
        #expect(InputHint(photoFailure: actions.failure!) == .photosNotPermitted)
        #expect(InputHint.photosNotPermitted.text
            == "Orbit is not allowed to control Photos, so it cannot show the photo. You can allow it in Orbit’s settings under “Permissions”.")
    }

    @Test func whenPhotosDoesNotOpenEitherTheNoteSaysSo() async {
        let opener = RecordingPhotosAppOpener()
        opener.failEverything()
        let actions = actions(MockAppleScriptRunner { _, _ in throw AppleScriptError.appUnavailable(.photos) }, opener: opener)
        await actions.show(Self.photo).value
        await actions.show(Self.video).value
        #expect(actions.failure == .init(reason: .photosNotOpened, count: 2))
        #expect(InputHint(photoFailure: actions.failure!).text == "The Photos app could not be opened.")
        #expect(InputHint.photoNotShown.text == "Photos could not show the photo, so Orbit opened the Photos app instead.")
    }

    @Test func aCancelledShowDoesNothingMore() async {
        let opener = RecordingPhotosAppOpener()
        let actions = actions(MockAppleScriptRunner { _, _ in throw CancellationError() }, opener: opener)
        await actions.show(Self.photo).value
        #expect(opener.opened == 0 && actions.failure == nil)
    }

    // MARK: VoiceOver

    @Test func voiceOverHearsTheKindDateAndState() {
        let now = PhotoTest.now
        var screenshot = Self.photo
        screenshot.isScreenshot = true
        screenshot.isFavorite = false
        var live = Self.photo
        live.mediaType = .livePhoto
        live.creationDate = nil
        GermanInterface.run {
            let photo = PhotoCardFormat.announcement(for: Self.photo, now: now, calendar: berlin, locale: german)
            #expect(photo.hasPrefix("Foto, Sa") && photo.contains("12. Juli 2025") && photo.contains("18:42"))
            #expect(photo.hasSuffix(", Favorit"))
            let video = PhotoCardFormat.announcement(for: Self.video, now: now, calendar: berlin, locale: german)
            #expect(video.hasPrefix("Video, 1 Minute") && video.contains("15 Sekunden, So"))
            #expect(video.contains("27. September") && video.contains("15:05"))
            #expect(!video.contains("2026"), "this year: no year")
            #expect(PhotoCardFormat.announcement(for: screenshot, thumbnail: .inCloud, now: now, calendar: berlin, locale: german)
                .hasPrefix("Bildschirmfoto, Sa., 12. Juli 2025"))
            #expect(PhotoCardFormat.announcement(for: screenshot, thumbnail: .inCloud, now: now, calendar: berlin, locale: german)
                .hasSuffix(", Nur in iCloud"))
            #expect(PhotoCardFormat.announcement(for: live, now: now, calendar: berlin, locale: german) == "Live Photo, Favorit")
            #expect(PhotoCardFormat.spokenDuration(42, locale: german) == "42 Sekunden")
            #expect(PhotoCardFormat.tooltip(for: live) == "In Fotos zeigen")
            #expect(PhotoCardFormat.tooltip(for: Self.photo, now: now, calendar: berlin, locale: german).hasSuffix(", In Fotos zeigen"))
        }
        let american = Locale(identifier: "en_US")
        let photo = PhotoCardFormat.announcement(for: Self.photo, now: now, calendar: berlin, locale: american)
        #expect(photo.hasPrefix("Photo, Sat") && photo.contains("July 12, 2025") && photo.hasSuffix(", Favorite"))
        #expect(PhotoCardFormat.announcement(for: screenshot, thumbnail: .inCloud, now: now, calendar: berlin, locale: american)
            .hasSuffix(", Only in iCloud"))
        #expect(PhotoCardFormat.announcement(for: live, now: now, calendar: berlin, locale: american) == "Live Photo, Favorite")
        #expect(PhotoCardFormat.tooltip(for: live) == "Show in Photos")
        #expect(PhotoCardFormat.tooltip(for: Self.photo, now: now, calendar: berlin, locale: american).hasSuffix(", Show in Photos"))
        #expect(PhotoCardFormat.systemImage(screenshot) == "camera.viewfinder")
        #expect(PhotoCardFormat.systemImage(Self.video) == "video")
    }

    // MARK: The grid

    @Test func theGridFitsAsManyColumnsAsTheWidthAllows() {
        #expect(PhotoGridLayout.columns(forWidth: 656) == 7, "a card in the panel")
        #expect(PhotoGridLayout.columns(forWidth: 78) == 1)
        #expect(PhotoGridLayout.columns(forWidth: 10) == 1)
        #expect(PhotoGridLayout.columns(forWidth: 0) == PhotoGridLayout.defaultColumns, "not measured yet")
        #expect(PhotoGridLayout.collapsedLimit(columns: 7) == 21, "three whole rows")
        #expect(PhotoGridLayout.thumbnailPixels >= 2 * 88, "sharp on Retina displays")
    }

    /// ←/→ move by a tile, ↑/↓ by a row; a shorter last row is reached at its
    /// last tile, and nothing wraps around (like Finder's icon view).
    @Test func arrowKeysMoveThroughTheGrid() {
        var selection = FileCardSelection(count: 17, collapsedLimit: 14)
        selection.moveVertically(by: 1, columns: 7)
        #expect(selection.index == 0, "the first tile when none was selected")
        selection.moveVertically(by: 1, columns: 7)
        #expect(selection.index == 7)
        selection.moveVertically(by: -1, columns: 7)
        selection.moveVertically(by: -1, columns: 7)
        #expect(selection.index == 0, "the first row stays")
        selection.select(12)
        selection.moveVertically(by: 1, columns: 7)
        #expect(selection.index == 16, "the shorter last row at its last tile")
        #expect(selection.isExpanded, "below the collapsed rows the card unfolds")
        selection.moveVertically(by: 1, columns: 7)
        #expect(selection.index == 16, "the last row stays")
        selection.select(15)
        selection.moveVertically(by: 1, columns: 7)
        #expect(selection.index == 15, "nothing below in the last row")
        selection.moveDown()
        #expect(selection.index == 16)
        selection.moveDown()
        #expect(selection.index == 16, "→ stops at the last tile")
        selection.select(7)
        selection.moveUp()
        #expect(selection.index == 6, "← goes to the end of the previous row")
    }

    @Test func anotherColumnCountKeepsWholeRowsAndTheSelection() {
        var selection = FileCardSelection(count: 30, index: 20, collapsedLimit: 21)
        #expect(!selection.isExpanded && selection.visibleCount == 21)
        selection.updateCollapsedLimit(18)
        #expect(selection.index == 20 && selection.isExpanded, "a selection it would hide unfolds the card")
        var other = FileCardSelection(count: 30, collapsedLimit: 21)
        other.updateCollapsedLimit(24)
        #expect(other.visibleCount == 24 && other.hiddenCount == 6)
        #expect(FileCardSelection(count: 3, collapsedLimit: 0).collapsedLimit == 1)
        #expect(FileCardSelection(count: 9).collapsedLimit == FileCardSelection.collapsedLimit, "rows of other cards as before")
    }

    @Test func theKeyboardReachesPhotoCards() {
        #expect(FileCardCoordinator.takesKeyboard(.photos([Self.photo])))
        #expect(!FileCardCoordinator.takesKeyboard(.photos([])))
        let photos = ChatItem(kind: .card(.photos([Self.photo, Self.video])))
        let contacts = ChatItem(kind: .card(.contacts([])))
        #expect(FileCardCoordinator.keyboardCardIDs(in: [photos, contacts]) == [photos.id])
    }

    // MARK: Old chats

    @Test func cardsOfOldAndNewChatsDecode() throws {
        let old = #"{"photos":{"_0":[{"id":"x/L0/001","mediaType":"image","isFavorite":false}]}}"#
        guard case .photos(let items) = try JSONDecoder().decode(ResultCard.self, from: Data(old.utf8)) else {
            Issue.record("photos")
            return
        }
        #expect(items.first?.isScreenshot == nil && items.first?.creationDate == nil)
        var screenshot = Self.photo
        screenshot.isScreenshot = true
        let card = ResultCard.photos([screenshot, Self.video])
        #expect(try JSONDecoder().decode(ResultCard.self, from: JSONEncoder().encode(card)) == card)
    }

    @Test func theDisclosureSaysOnlyDetailsWereSent() {
        #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .photos, count: 30)], providerName: "Claude")
            == "Details of 30 photos sent to Claude")
        #expect(DisclosurePhrase.phrase(for: .photos, count: 1) == "details of 1 photo")
    }
}
