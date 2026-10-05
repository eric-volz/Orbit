import AppKit
import SwiftUI
import Testing
@testable import Orbit

extension UIWindowTests {
    /// Event and reminder cards in the real RootView, driven with key events in
    /// an offscreen panel, like mail and note cards: Tab from the input
    /// reaches the latest card, Shift-Tab the older one, ↑/↓ select a row
    /// (VoiceOver hears it), Return shows it in Calendar or Reminders. Showing
    /// is a recorder: no app is reached and nothing appears.
    ///
    ///     ORBIT_UI_TESTS=1 Scripts/swiftpm.sh test --filter CalendarCardKeyboard
    @MainActor
    @Suite("CalendarCardKeyboard", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_UI_TESTS"] == "1"))
    struct CalendarCardKeyboardTests {
        struct Harness {
            let environment: AppEnvironment
            let panel: OffscreenKeyPanel
            let opener: RecordingCalendarAppOpener
            let announcer: RecordingAnnouncer
            let eventCard: UUID
            let reminderCard: UUID
        }

        /// The panel with a chat that has an event card (six events: the sixth
        /// behind "Show 1 More") and then a reminder card.
        static func makeHarness() async throws -> Harness {
            _ = NSApplication.shared
            let opener = RecordingCalendarAppOpener()
            let announcer = RecordingAnnouncer()
            let environment = SnapshotEnvironment.make(services: AppServices.fake(announcer: announcer, calendarApps: opener))
            environment.panelState.maximumContentHeight = 2_300
            let panel = OffscreenKeyPanel(size: CGSize(width: Theme.panelWidth, height: 2_400))
            panel.contentView = NSHostingView(rootView: RootView(environment: environment)
                .background(Color(nsColor: .windowBackgroundColor)))
            panel.makeKeyAndOrderFront(nil)
            try #require(panel.isOffscreen, "nothing may appear on the screen")
            await SnapshotRenderer.settle(0.4)

            let events = ChatItem(kind: .card(.events(SampleData.calendarEvents)))
            let reminders = ChatItem(kind: .card(.reminders(SampleData.calendarReminders)))
            let conversation = Conversation(title: "Kalender", items: [
                ChatItem(kind: .user(text: "Was habe ich morgen?", attachments: [])),
                events,
                ChatItem(kind: .user(text: "Und was muss ich noch erledigen?", attachments: [])),
                reminders,
            ])
            try await environment.conversationStore.save(conversation)
            await environment.agentLoop.restoreMostRecentConversation()
            try #require(environment.agentLoop.items.map(\.id).contains(reminders.id), "the chat with the cards was restored")
            try #require(!environment.chatParking.isParked, "shown, not parked")
            await SnapshotRenderer.settle(0.5)
            return Harness(environment: environment, panel: panel, opener: opener, announcer: announcer,
                           eventCard: events.id, reminderCard: reminders.id)
        }

        static func press(_ harness: Harness, _ key: CardKeyboardTests.Key, times: Int = 1) async {
            await CardKeyboardTests.press(harness.panel, key, times: times)
        }

        private func inputHasFocus(_ harness: Harness) -> Bool {
            harness.panel.firstResponder is NSTextView
        }

        @Test func tabReachesTheCardsAndReturnShowsTheSelectedItem() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            let announcer = harness.announcer
            #expect(inputHasFocus(harness), "cards that arrive do not take the keyboard")

            // The reminder card (the latest): ↓ selects the overdue bill, Return shows it in Reminders.
            await Self.press(harness, .tab)
            #expect(!inputHasFocus(harness))
            #expect(announcer.announcements.last?.hasPrefix("Lisa anrufen, ") == true)
            await Self.press(harness, .down)
            #expect(announcer.announcements.last?.hasPrefix("Rechnung Telekom bezahlen, ") == true)
            #expect(announcer.announcements.last?.hasSuffix(", Erinnerungen, Overdue") == true)
            await Self.press(harness, .returnKey)
            #expect(await SearchTestSupport.eventually { harness.opener.shownReminders == ["r2"] })

            // The event card: the recurring meeting, then past the fifth row into the hidden sixth.
            await Self.press(harness, .backTab)
            #expect(announcer.announcements.last?.hasPrefix("Geburtstag Lisa, ") == true)
            await Self.press(harness, .down, times: 2)
            #expect(announcer.announcements.last?.hasPrefix("Team-Meeting, ") == true)
            #expect(announcer.announcements.last?.contains("Repeats") == true)
            await Self.press(harness, .returnKey)
            #expect(await SearchTestSupport.eventually { harness.opener.shownEvents == ["e3"] })
            await Self.press(harness, .down)
            #expect(announcer.announcements.last?.hasSuffix(", Declined") == true)
            await Self.press(harness, .down, times: 2)
            #expect(announcer.announcements.last?.hasPrefix("Herbstferien, ") == true, "the card unfolds")

            // Shift-Tab past the first card leads back to the input.
            await Self.press(harness, .backTab)
            #expect(inputHasFocus(harness))
            #expect(harness.opener.shownEvents == ["e3"] && harness.opener.shownReminders == ["r2"], "only what Return chose")
        }
    }
}
