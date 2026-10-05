import AppKit
import SwiftUI
import Testing
@testable import Orbit

extension UIWindowTests {
    /// Photo cards in the real RootView, driven with key events in an
    /// offscreen panel, like the other cards: Tab from the input reaches the
    /// latest card, Shift-Tab the older one, ←/→ select a tile and ↑/↓ a row
    /// (VoiceOver hears it; past the third row the card unfolds), Return shows
    /// the photo in Photos. Thumbnails, the Photos script and opening Photos
    /// are fakes: PhotoKit and Photos are never reached and nothing appears.
    ///
    ///     ORBIT_UI_TESTS=1 Scripts/swiftpm.sh test --filter PhotoCardKeyboard
    @MainActor
    @Suite("PhotoCardKeyboard", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_UI_TESTS"] == "1"))
    struct PhotoCardKeyboardTests {
        struct Harness {
            let environment: AppEnvironment
            let panel: OffscreenKeyPanel
            let runner: MockAppleScriptRunner
            let opener: RecordingPhotosAppOpener
            let thumbnails: MockPhotoThumbnails
            let announcer: RecordingAnnouncer
            let olderCard: UUID
            let latestCard: UUID
        }

        /// 24 photos (three rows of seven shown, three behind "Show 3 More"); the third is a video.
        static let older: [PhotoItem] = (1...24).map(olderItem)

        /// Three photos; the second is a Live Photo.
        static let latest: [PhotoItem] = (1...3).map(latestItem)

        private nonisolated static func olderItem(_ number: Int) -> PhotoItem {
            let isVideo = number == 3
            let date = Date().addingTimeInterval(Double(-number) * 3_600)
            return PhotoItem(id: "OLD-\(number)/L0/001", creationDate: date, mediaType: isVideo ? .video : .image,
                             isFavorite: number == 2, duration: isVideo ? 42 : nil, pixelWidth: 4032, pixelHeight: 3024)
        }

        private nonisolated static func latestItem(_ number: Int) -> PhotoItem {
            let date = Date().addingTimeInterval(Double(-number) * 600)
            return PhotoItem(id: "NEW-\(number)/L0/001", creationDate: date, mediaType: number == 2 ? .livePhoto : .image,
                             isFavorite: false, duration: nil, pixelWidth: 4032, pixelHeight: 3024)
        }

        static func makeHarness(thumbnails: MockPhotoThumbnails = MockPhotoThumbnails()) async throws -> Harness {
            _ = NSApplication.shared
            let runner = MockAppleScriptRunner { script, _ in
                guard script.name == PhotosService.showScript.name else { throw AppleScriptError.disabled }
                return #"{"shown":true}"#
            }
            let opener = RecordingPhotosAppOpener()
            let announcer = RecordingAnnouncer()
            let environment = SnapshotEnvironment.make(services: AppServices.fake(
                announcer: announcer, appleScripts: runner, photoThumbnails: thumbnails, photosApp: opener))
            environment.panelState.maximumContentHeight = 2_300
            let panel = OffscreenKeyPanel(size: CGSize(width: Theme.panelWidth, height: 2_400))
            panel.contentView = NSHostingView(rootView: RootView(environment: environment)
                .background(Color(nsColor: .windowBackgroundColor)))
            panel.makeKeyAndOrderFront(nil)
            try #require(panel.isOffscreen, "nothing may appear on the screen")
            await SnapshotRenderer.settle(0.4)

            let olderCard = ChatItem(kind: .card(.photos(older)))
            let latestCard = ChatItem(kind: .card(.photos(latest)))
            let conversation = Conversation(title: "Fotos", items: [
                ChatItem(kind: .user(text: "Zeig mir die Fotos von heute", attachments: [])),
                olderCard,
                ChatItem(kind: .user(text: "Und die letzten drei?", attachments: [])),
                latestCard,
            ])
            try await environment.conversationStore.save(conversation)
            await environment.agentLoop.restoreMostRecentConversation()
            try #require(environment.agentLoop.items.map(\.id).contains(latestCard.id), "the chat with the cards was restored")
            try #require(!environment.chatParking.isParked, "shown, not parked")
            await SnapshotRenderer.settle(0.5)
            return Harness(environment: environment, panel: panel, runner: runner, opener: opener, thumbnails: thumbnails,
                           announcer: announcer, olderCard: olderCard.id, latestCard: latestCard.id)
        }

        static func press(_ harness: Harness, _ key: CardKeyboardTests.Key, times: Int = 1) async {
            await CardKeyboardTests.press(harness.panel, key, times: times)
        }

        private func inputHasFocus(_ harness: Harness) -> Bool {
            harness.panel.firstResponder is NSTextView
        }

        @Test func tabReachesTheGridAndTheArrowKeysMoveThroughIt() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            let announcer = harness.announcer
            #expect(inputHasFocus(harness), "cards that arrive do not take the keyboard")
            // Thumbnails of the tiles shown, prepared for every photo of a card.
            #expect(await SearchTestSupport.eventually { Set(harness.thumbnails.requests).count == 24 }, "21 + 3 tiles")
            #expect(harness.thumbnails.prepared.contains(Self.older.map(\.id)))

            // The latest card: → selects the Live Photo, Return shows it in Photos.
            await Self.press(harness, .tab)
            #expect(!inputHasFocus(harness))
            #expect(announcer.announcements.last == PhotoCardFormat.announcement(for: Self.latest[0]))
            await Self.press(harness, .right)
            #expect(announcer.announcements.last == PhotoCardFormat.announcement(for: Self.latest[1]))
            #expect(announcer.announcements.last?.hasPrefix("Live Photo, ") == true)
            await Self.press(harness, .returnKey)
            #expect(await SearchTestSupport.eventually { harness.runner.runs.count == 1 })
            #expect(harness.runner.runs.first == .init(script: "photos-show", arguments: ["NEW-2/L0/001"]))

            // The older card: ↓ moves a row of seven; below the third row the card unfolds.
            await Self.press(harness, .backTab)
            #expect(announcer.announcements.last == PhotoCardFormat.announcement(for: Self.older[0]))
            await Self.press(harness, .right, times: 2)
            #expect(announcer.announcements.last?.hasPrefix("Video, ") == true)
            await Self.press(harness, .down)
            #expect(announcer.announcements.last == PhotoCardFormat.announcement(for: Self.older[9]))
            await Self.press(harness, .down)
            await Self.press(harness, .right, times: 3)
            #expect(announcer.announcements.last == PhotoCardFormat.announcement(for: Self.older[19]))
            await Self.press(harness, .down)
            #expect(announcer.announcements.last == PhotoCardFormat.announcement(for: Self.older[23]),
                    "the shorter last row at its last tile")
            #expect(await SearchTestSupport.eventually { Set(harness.thumbnails.requests).count == 27 }, "the unfolded tiles load")
            await Self.press(harness, .up)
            #expect(announcer.announcements.last == PhotoCardFormat.announcement(for: Self.older[16]))
            await Self.press(harness, .left)
            #expect(announcer.announcements.last == PhotoCardFormat.announcement(for: Self.older[15]))

            // Shift-Tab past the first card leads back to the input.
            await Self.press(harness, .backTab)
            #expect(inputHasFocus(harness))
            #expect(harness.runner.runs.count == 1 && harness.opener.opened == 0, "only what Return chose")
        }

        /// Tiles that go away (here the whole chat, after ⌘N) cancel the
        /// thumbnails they still wait for, and the cards release what they
        /// prepared.
        @Test func tilesThatGoAwayCancelTheirThumbnails() async throws {
            let thumbnails = MockPhotoThumbnails()
            thumbnails.holdRequests()
            let harness = try await Self.makeHarness(thumbnails: thumbnails)
            defer { harness.panel.orderOut(nil) }
            #expect(await SearchTestSupport.eventually { Set(thumbnails.requests).count == 24 })
            #expect(thumbnails.cancelled.isEmpty)
            harness.environment.startNewChat()
            #expect(await SearchTestSupport.eventually { Set(thumbnails.cancelled).count == 24 },
                    "every waiting request was cancelled")
            #expect(await SearchTestSupport.eventually {
                thumbnails.released.contains(Self.older.map(\.id)) && thumbnails.released.contains(Self.latest.map(\.id))
            })
        }
    }
}
