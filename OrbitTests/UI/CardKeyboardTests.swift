import AppKit
import SwiftUI
import Testing
@testable import Orbit

extension UIWindowTests {
    /// A11Y-1: mail and note cards and a reply card's buttons in the real
    /// RootView, driven with key events in an offscreen panel, like file
    /// cards. Opening messages and notes, showing the reply window and the
    /// clipboard are fakes: no app is reached and nothing appears.
    ///
    ///     ORBIT_UI_TESTS=1 Scripts/swiftpm.sh test --filter CardKeyboard
    @MainActor
    @Suite("CardKeyboard", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_UI_TESTS"] == "1"))
    struct CardKeyboardTests {
        private final class Counter {
            var value = 0
        }

        struct Harness {
            let environment: AppEnvironment
            let panel: OffscreenKeyPanel
            let runner: MockAppleScriptRunner
            let opener: MailCardActionsTests.Opener
            let pasteboard: RecordingPasteboard
            let announcer: RecordingAnnouncer
            let fileCard: UUID
            let mailCard: UUID
            let noteCard: UUID
            let replyCard: UUID
            let closeCount: () -> Int
        }

        static let file = FileItem(path: "/Users/orbit-test/Documents/Rechnungen/Rechnung-Telekom-2026-09.pdf",
                                   name: "Rechnung-Telekom-2026-09.pdf", contentType: "com.adobe.pdf",
                                   modified: Date().addingTimeInterval(-3 * 86_400), size: 48_000)

        /// Seven messages (five shown until the card expands); the second has no link.
        static let mails: [MailItem] = (1...7).map(mail)

        private nonisolated static func mail(_ number: Int) -> MailItem {
            let messageID: String? = number == 2 ? nil : "orbit-test-\(number)@example.com"
            let date = Date().addingTimeInterval(Double(-number) * 7_200)
            return MailItem(id: "mail:\(100 + number)::INBOX", messageID: messageID, sender: "Absender \(number)",
                            subject: "Betreff \(number)", date: date, isRead: number != 1)
        }

        static let notes = [
            NoteItem(id: "x-coredata://ORBIT-TEST/ICNote/p1", title: "Umzug", excerpt: "Kartons bestellen", folder: "Privat"),
            NoteItem(id: "x-coredata://ORBIT-TEST/ICNote/p2", title: "Einkauf", excerpt: "Milch, Brot", folder: "Privat"),
        ]

        static let reply = MailDraftItem(to: ["Lisa Beispiel <lisa.beispiel@example.com>"], cc: [], subject: "Re: Projekt Orbit",
                                         body: "Hallo Lisa,\n\nDonnerstag passt.\n\nErika", isOpenInMail: true, draftID: 8,
                                         reply: MailReplyInfo(toAll: false, isTextOnClipboard: true))

        /// The panel shows the input; then a chat with a file, a mail, a note
        /// and a reply card arrives (restored like after a relaunch). The panel
        /// is tall enough to show the whole chat: offscreen, SwiftUI does not
        /// build lazy rows that scrolling brings into view.
        static func makeHarness(draftShown: Bool = true) async throws -> Harness {
            _ = NSApplication.shared
            let runner = MockAppleScriptRunner { script, _ in
                switch script.name {
                case NotesService.openScript.name: return MailTest.json(OpenedNote(opened: true, name: "Einkauf"))
                case MailService.showDraftScript.name: return MailTest.json(ShownMailDraft(shown: draftShown))
                default: throw AppleScriptError.disabled
                }
            }
            let opener = MailCardActionsTests.Opener()
            let pasteboard = RecordingPasteboard()
            let announcer = RecordingAnnouncer()
            var services = AppServices.fake(announcer: announcer, appleScripts: runner, pasteboard: pasteboard)
            services.messageLinks = opener
            let environment = SnapshotEnvironment.make(services: services)
            environment.panelState.maximumContentHeight = 2_300
            let closes = Counter()
            environment.panelState.closePanel = { closes.value += 1 }
            let panel = OffscreenKeyPanel(size: CGSize(width: Theme.panelWidth, height: 2_400))
            panel.contentView = NSHostingView(rootView: RootView(environment: environment)
                .background(Color(nsColor: .windowBackgroundColor)))
            panel.makeKeyAndOrderFront(nil)
            try #require(panel.isOffscreen, "nothing may appear on the screen")
            await SnapshotRenderer.settle(0.4)

            let files = ChatItem(kind: .card(.files([file])))
            let mails = ChatItem(kind: .card(.mails(mails)))
            let notes = ChatItem(kind: .card(.notes(notes)))
            let reply = ChatItem(kind: .card(.mailDraft(reply)))
            let conversation = Conversation(title: "Lisa", items: [
                ChatItem(kind: .user(text: "Finde die Telekom-Rechnung", attachments: [])),
                files,
                ChatItem(kind: .user(text: "Was hat mir Lisa geschrieben, und was steht in meinen Notizen?", attachments: [])),
                mails,
                notes,
                ChatItem(kind: .user(text: "Sag ihr, Donnerstag passt", attachments: [])),
                reply,
            ])
            try await environment.conversationStore.save(conversation)
            await environment.agentLoop.restoreMostRecentConversation()
            try #require(environment.agentLoop.items.map(\.id).contains(reply.id), "the chat with the cards was restored")
            try #require(!environment.chatParking.isParked, "shown, not parked")
            await SnapshotRenderer.settle(0.5)
            return Harness(environment: environment, panel: panel, runner: runner, opener: opener, pasteboard: pasteboard,
                           announcer: announcer, fileCard: files.id, mailCard: mails.id, noteCard: notes.id,
                           replyCard: reply.id, closeCount: { closes.value })
        }

        enum Key {
            case tab, backTab, up, down, left, right, space, returnKey, escape

            var event: (keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) {
                switch self {
                case .tab: (48, "\t", [])
                case .backTab: (48, "\u{19}", .shift)
                case .up: (126, "\u{F700}", [.function, .numericPad])
                case .down: (125, "\u{F701}", [.function, .numericPad])
                case .left: (123, "\u{F702}", [.function, .numericPad])
                case .right: (124, "\u{F703}", [.function, .numericPad])
                case .space: (49, " ", [])
                case .returnKey: (36, "\r", [])
                case .escape: (53, "\u{1B}", [])
                }
            }
        }

        static func press(_ harness: Harness, _ key: Key, times: Int = 1) async {
            await press(harness.panel, key, times: times)
        }

        /// Sends `key` to the offscreen panel `times` times (also for other card suites).
        static func press(_ panel: NSWindow, _ key: Key, times: Int = 1) async {
            for _ in 0..<times {
                let (keyCode, characters, modifiers) = key.event
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: panel.windowNumber, context: nil,
                                                       characters: characters, charactersIgnoringModifiers: characters,
                                                       isARepeat: false, keyCode: keyCode) else { continue }
                    NSApp.sendEvent(event)
                }
                await SnapshotRenderer.settle(0.12)
            }
        }

        private func press(_ harness: Harness, _ key: Key, times: Int = 1) async {
            await Self.press(harness, key, times: times)
        }

        private func inputHasFocus(_ harness: Harness) -> Bool {
            harness.panel.firstResponder is NSTextView
        }

        // MARK: Tests

        /// Tab from the input reaches the latest card of any kind (here the
        /// reply's buttons), Shift-Tab the older cards: notes, mails, files.
        @Test func tabReachesTheLatestCardOfAnyKindAndShiftTabTheOlderOnes() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            let announcer = harness.announcer
            #expect(inputHasFocus(harness), "cards that arrive do not take the keyboard")

            // The reply card: "Copy Text", then "Show in Mail".
            await press(harness, .tab)
            #expect(!inputHasFocus(harness))
            #expect(announcer.announcements.last == "Copy Text")
            #expect(announcer.priorities.last == .medium, "after VoiceOver named the card")
            await press(harness, .returnKey)
            #expect(await SearchTestSupport.eventually { harness.pasteboard.texts == [Self.reply.body] })
            await press(harness, .right)
            #expect(announcer.announcements.last == "Show in Mail")
            #expect(announcer.priorities.last == .high)
            await press(harness, .space)
            #expect(await SearchTestSupport.eventually {
                harness.runner.runs == [.init(script: MailService.showDraftScript.name, arguments: ["8"])]
            })
            await press(harness, .left)
            #expect(announcer.announcements.last == "Copy Text")

            // The note card: ↓ selects the second note, Return opens it in Notes.
            await press(harness, .backTab)
            #expect(announcer.announcements.last?.hasPrefix("Umzug, Privat") == true)
            await press(harness, .down)
            #expect(announcer.announcements.last?.hasPrefix("Einkauf, Privat") == true)
            await press(harness, .returnKey)
            #expect(await SearchTestSupport.eventually {
                harness.runner.runs.last == .init(script: NotesService.openScript.name, arguments: [Self.notes[1].id])
            })

            // The mail card: Return opens the first message through its link.
            await press(harness, .backTab)
            #expect(announcer.announcements.last?.hasPrefix("Absender 1, Betreff 1, ") == true)
            #expect(announcer.announcements.last?.hasSuffix(", Unread") == true)
            await press(harness, .returnKey)
            #expect(await SearchTestSupport.eventually {
                harness.opener.urls == [URL(string: "message://%3Corbit-test-1@example.com%3E")!]
            })

            // The file card: its own keys work there (Space: Quick Look).
            await press(harness, .backTab)
            await press(harness, .space)
            #expect(harness.environment.quickLook.preview?.source == harness.fileCard)
            harness.environment.quickLook.close()

            #expect(harness.environment.panelState.inputText.isEmpty, "the keys never reached the input")
            #expect(harness.closeCount() == 0)
        }

        @Test func movingPastTheCollapsedMessagesExpandsTheCard() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            let accessibility = UIWindowTests.FileCardKeyboardTests.AccessibilityTree()
            defer { accessibility.end() }
            #expect(!labels(in: harness).contains { $0.hasPrefix("Absender 7") }, "collapsed to five messages")
            await press(harness, .tab)
            await press(harness, .backTab, times: 2)
            await press(harness, .down, times: 6)
            #expect(labels(in: harness).contains { $0.hasPrefix("Absender 7") }, "expanded")
            #expect(harness.announcer.announcements.last?.hasPrefix("Absender 7, Betreff 7") == true)
            await press(harness, .returnKey)
            #expect(await SearchTestSupport.eventually {
                harness.opener.urls == [URL(string: "message://%3Corbit-test-7@example.com%3E")!]
            })
        }

        /// A message Mail named no Message-ID for cannot be opened: Return does nothing.
        @Test func aMessageWithoutALinkIsNotOpened() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            await press(harness, .tab)
            await press(harness, .backTab, times: 2)
            await press(harness, .down)
            #expect(harness.announcer.announcements.last?.hasPrefix("Absender 2, Betreff 2") == true)
            await press(harness, .returnKey)
            await SnapshotRenderer.settle(0.2)
            #expect(harness.opener.urls.isEmpty)
            #expect(harness.closeCount() == 0)
        }

        /// Tab in the last card goes back to the input; Escape on a card does
        /// what it does anywhere in the panel: it stops a running answer,
        /// otherwise closes the panel (here: no answer runs, so the panel
        /// closes), as on file cards, and does not lead back to the input.
        @Test func tabGoesBackToTheInputAndEscapeActsAsInThePanel() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            await press(harness, .tab)
            #expect(!inputHasFocus(harness))
            await press(harness, .tab)
            #expect(inputHasFocus(harness), "Tab in the last card goes back to the input")
            await press(harness, .tab)
            await press(harness, .backTab)
            #expect(!inputHasFocus(harness))
            await press(harness, .escape)
            #expect(harness.closeCount() == 1)
        }

        /// UX-2: what could not be done is said under the input, and read out.
        @Test func aReplyWindowThatIsClosedIsExplainedAndReadOut() async throws {
            let harness = try await Self.makeHarness(draftShown: false)
            defer { harness.panel.orderOut(nil) }
            let accessibility = UIWindowTests.FileCardKeyboardTests.AccessibilityTree()
            defer { accessibility.end() }
            await press(harness, .tab)
            await press(harness, .right)
            await press(harness, .returnKey)
            let hint = "The draft is no longer open in Mail. If you saved it, you’ll find it in “Drafts”."
            #expect(await SearchTestSupport.eventually { harness.announcer.announcements.last == hint })
            #expect(harness.announcer.priorities.last == .high)
            #expect(labels(in: harness).contains(hint))
        }

        // MARK: Accessibility tree

        private func labels(in harness: Harness) -> [String] {
            var labels: [String] = []
            var queue: [NSObject] = harness.panel.contentView.map { [$0] } ?? []
            var visited = 0
            while !queue.isEmpty, visited < 8_000 {
                let element = queue.removeFirst()
                visited += 1
                for key in ["accessibilityLabel", "accessibilityValue"] {
                    if let text = element.value(forKey: key) as? String, !text.isEmpty { labels.append(text) }
                }
                queue.append(contentsOf: element.value(forKey: "accessibilityChildren") as? [NSObject] ?? [])
            }
            return labels
        }
    }
}
