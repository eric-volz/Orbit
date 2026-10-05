import AppKit
import SwiftUI
import Testing
@testable import Orbit

extension UIWindowTests {
    /// Drives file cards in the real RootView with key events in an offscreen
    /// panel: Tab from the input, ↑/↓, Space (Quick Look), Return and Escape.
    /// Quick Look and opening files are fakes, so no window or app appears; the
    /// files do not exist.
    ///
    ///     ORBIT_UI_TESTS=1 Scripts/swiftpm.sh test --filter FileCardKeyboard
    @MainActor
    @Suite("FileCardKeyboard", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_UI_TESTS"] == "1"))
    struct FileCardKeyboardTests {
        private final class Counter {
            var value = 0
        }

        struct Harness {
            let environment: AppEnvironment
            let panel: OffscreenKeyPanel
            let quickLook: FakeQuickLookPanel
            let workspace: MockWorkspace
            let announcer: RecordingAnnouncer
            let olderCard: UUID
            let latestCard: UUID
            let closeCount: () -> Int
        }

        static let olderFiles = [
            FileItem(path: "/Users/orbit-test/Documents/Rechnungen/Rechnung-Telekom-2026-08.pdf", name: "Rechnung-Telekom-2026-08.pdf",
                     contentType: "com.adobe.pdf", modified: Date().addingTimeInterval(-40 * 86_400), size: 48_000),
            FileItem(path: "/Users/orbit-test/Documents/Rechnungen", name: "Rechnungen", modified: Date().addingTimeInterval(-9 * 86_400),
                     isDirectory: true),
        ]

        static let latestFiles = (1...7).map { number in
            FileItem(path: "/Users/orbit-test/Documents/Scans/Beleg-\(number).pdf", name: "Beleg-\(number).pdf",
                     contentType: "com.adobe.pdf", modified: Date().addingTimeInterval(Double(-number) * 3_600), size: Int64(number) * 120_000)
        }

        /// The panel shows the input; then a chat with two file cards arrives
        /// (restored like after a relaunch).
        ///
        /// The chat stays shorter than the panel: offscreen, SwiftUI does not
        /// build lazy rows that scrolling brings into view.
        static func makeHarness() async throws -> Harness {
            _ = NSApplication.shared
            let quickLook = FakeQuickLookPanel()
            let workspace = MockWorkspace()
            let announcer = RecordingAnnouncer()
            let environment = SnapshotEnvironment.make(services: .fake(workspace: workspace, quickLookPanel: quickLook,
                                                                       announcer: announcer))
            let closes = Counter()
            environment.panelState.closePanel = { closes.value += 1 }
            let panel = OffscreenKeyPanel(size: CGSize(width: Theme.panelWidth, height: 700))
            // The real panel's material stands behind the content; snapshots need an opaque background.
            panel.contentView = NSHostingView(rootView: RootView(environment: environment)
                .background(Color(nsColor: .windowBackgroundColor)))
            panel.makeKeyAndOrderFront(nil)
            try #require(panel.isOffscreen, "nothing may appear on the screen")
            await SnapshotRenderer.settle(0.4)

            let older = ChatItem(kind: .card(.files(olderFiles)))
            let latest = ChatItem(kind: .card(.files(latestFiles)))
            let conversation = Conversation(title: "Belege", items: [
                ChatItem(kind: .user(text: "Finde die Telekom-Rechnung", attachments: [])),
                older,
                ChatItem(kind: .assistant(text: "Die Rechnung vom August liegt in „Rechnungen“.", isStreaming: false)),
                ChatItem(kind: .user(text: "Und die gescannten Belege?", attachments: [])),
                latest,
            ])
            try await environment.conversationStore.save(conversation)
            await environment.agentLoop.restoreMostRecentConversation()
            try #require(environment.agentLoop.items.map(\.id).contains(latest.id), "the chat with the cards was restored")
            try #require(!environment.chatParking.isParked, "shown, not parked")
            await SnapshotRenderer.settle(0.4)
            return Harness(environment: environment, panel: panel, quickLook: quickLook, workspace: workspace,
                           announcer: announcer, olderCard: older.id, latestCard: latest.id, closeCount: { closes.value })
        }

        enum Key {
            case tab, backTab, up, down, space, returnKey, escape
            /// ⇧⌘R: "Show in Finder".
            case revealInFinder

            var event: (keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) {
                switch self {
                case .tab: (48, "\t", [])
                case .backTab: (48, "\u{19}", .shift)
                case .up: (126, "\u{F700}", [.function, .numericPad])
                case .down: (125, "\u{F701}", [.function, .numericPad])
                case .space: (49, " ", [])
                case .returnKey: (36, "\r", [])
                case .escape: (53, "\u{1B}", [])
                case .revealInFinder: (15, "R", [.command, .shift])
                }
            }
        }

        static func press(_ harness: Harness, _ key: Key, times: Int = 1) async {
            for _ in 0..<times {
                let (keyCode, characters, modifiers) = key.event
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: harness.panel.windowNumber, context: nil,
                                                       characters: characters, charactersIgnoringModifiers: characters,
                                                       isARepeat: false, keyCode: keyCode) else { continue }
                    NSApp.sendEvent(event)
                }
                await SnapshotRenderer.settle(0.1)
            }
        }

        private func inputHasFocus(_ harness: Harness) -> Bool {
            harness.panel.firstResponder is NSTextView
        }

        private func press(_ harness: Harness, _ key: Key, times: Int = 1) async {
            await Self.press(harness, key, times: times)
        }

        // MARK: Tests

        @Test func tabMovesTheKeyboardFromTheInputToTheLatestCard() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            let quickLook = harness.environment.quickLook
            #expect(inputHasFocus(harness), "a card that arrives does not take the keyboard")

            await press(harness, .tab)
            #expect(!inputHasFocus(harness))
            await press(harness, .space)
            #expect(harness.quickLook.isVisible)
            #expect(quickLook.preview?.source == harness.latestCard)
            #expect(quickLook.preview?.index == 0, "the first row is selected")
            #expect(quickLook.preview?.urls == Self.latestFiles.map(\.url))
            await press(harness, .space)
            #expect(!harness.quickLook.isVisible, "Space toggles")

            await press(harness, .returnKey)
            #expect(await SearchTestSupport.eventually { harness.workspace.opened == [Self.latestFiles[0].url] })
            #expect(harness.environment.panelState.inputText.isEmpty, "the keys never reached the input")
            #expect(harness.closeCount() == 0)
        }

        /// ⇧⌘R shows the selected file in Finder, without the mouse or VoiceOver. (⌥⌘C, which copies
        /// its path, would write the real clipboard here; `AccessibilityDisplayTests` checks it.)
        @Test func shiftCommandRShowsTheSelectedFileInFinder() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            await press(harness, .tab)
            await press(harness, .down)
            await press(harness, .revealInFinder)
            #expect(await SearchTestSupport.eventually { harness.workspace.revealed == [Self.latestFiles[1].url] })
            #expect(harness.workspace.opened.isEmpty)
            #expect(harness.environment.panelState.inputText.isEmpty, "the key never reached the input")
        }

        @Test func shiftTabInTheInputAlsoReachesTheLatestCard() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            await press(harness, .backTab)
            await press(harness, .space)
            #expect(harness.environment.quickLook.preview?.source == harness.latestCard)
        }

        @Test func arrowsMoveTheSelectionAndThePreviewFollows() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            await press(harness, .tab)
            await press(harness, .space)
            await press(harness, .down, times: 2)
            #expect(harness.environment.quickLook.preview?.index == 2)
            #expect(harness.quickLook.shownIndex == 2)
            await press(harness, .up)
            #expect(harness.quickLook.shownIndex == 1)
            await press(harness, .returnKey)
            #expect(await SearchTestSupport.eventually { harness.workspace.opened == [Self.latestFiles[1].url] })
        }

        @Test func movingPastTheCollapsedRowsExpandsTheCard() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            let accessibility = AccessibilityTree()
            defer { accessibility.end() }
            #expect(rowNames(in: harness).contains("Beleg-5.pdf"))
            #expect(!rowNames(in: harness).contains("Beleg-6.pdf"), "collapsed to five rows")

            await press(harness, .tab)
            await press(harness, .down, times: 6)
            #expect(rowNames(in: harness).contains("Beleg-7.pdf"), "expanded")
            await press(harness, .down)
            await press(harness, .space)
            #expect(harness.environment.quickLook.preview?.index == 6, "the last row; arrows stop there")
            await press(harness, .returnKey)
            #expect(await SearchTestSupport.eventually { harness.workspace.opened == [Self.latestFiles[6].url] })
        }

        @Test func escapeClosesThePreviewBeforeThePanel() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            await press(harness, .tab)
            await press(harness, .space)
            #expect(harness.quickLook.isVisible)
            await press(harness, .escape)
            #expect(!harness.quickLook.isVisible)
            #expect(harness.closeCount() == 0)
            await press(harness, .escape)
            #expect(harness.closeCount() == 1, "then Escape closes the panel as usual")
        }

        @Test func tabLeavesTheCardAndEscapeInTheInputClosesThePreviewFirst() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            await press(harness, .tab)
            await press(harness, .space)
            await press(harness, .tab)
            #expect(inputHasFocus(harness), "Tab in the last card goes back to the input")
            #expect(harness.quickLook.isVisible, "the preview stays")
            await press(harness, .escape)
            #expect(!harness.quickLook.isVisible)
            #expect(harness.closeCount() == 0)
            await press(harness, .escape)
            #expect(harness.closeCount() == 1)
        }

        @Test func shiftTabMovesToTheOlderCard() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            await press(harness, .tab)
            await press(harness, .backTab)
            #expect(!inputHasFocus(harness))
            await press(harness, .space)
            #expect(harness.environment.quickLook.preview?.source == harness.olderCard)
            #expect(harness.environment.quickLook.preview?.urls == Self.olderFiles.map(\.url))
            // Another card's Space shows its own files.
            await press(harness, .tab)
            await press(harness, .space)
            #expect(harness.environment.quickLook.preview?.source == harness.latestCard)
        }

        @Test func navigatingInThePreviewMovesTheCardsSelection() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            let accessibility = AccessibilityTree()
            defer { accessibility.end() }
            await press(harness, .tab)
            await press(harness, .space)
            harness.quickLook.userShows(3)
            await SnapshotRenderer.settle(0.1)
            await press(harness, .returnKey)
            #expect(await SearchTestSupport.eventually { harness.workspace.opened == [Self.latestFiles[3].url] })

            // ↑/↓ while the preview has the keyboard.
            harness.quickLook.userClicks()
            harness.quickLook.userMoves(by: 3)
            await SnapshotRenderer.settle(0.1)
            #expect(rowNames(in: harness).contains("Beleg-7.pdf"), "the card expanded to show the selection")
            await press(harness, .returnKey)
            #expect(await SearchTestSupport.eventually { harness.workspace.opened.last == Self.latestFiles[6].url })
        }

        @Test func theCardTakesTheKeyboardBackWhenThePreviewCloses() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            await press(harness, .tab)
            await press(harness, .down)
            await press(harness, .space)
            // The user clicked into the preview; meanwhile the input got the keyboard.
            harness.quickLook.userClicks()
            await press(harness, .tab)
            #expect(inputHasFocus(harness))
            harness.quickLook.userCloses()
            await SnapshotRenderer.settle(0.2)
            #expect(!inputHasFocus(harness), "focus returned to the card")
            await press(harness, .space)
            #expect(harness.environment.quickLook.preview?.source == harness.latestCard)
            #expect(harness.environment.quickLook.preview?.index == 1, "with its selection")
        }

        @Test func closingThePreviewFromOrbitLeavesTheKeyboardWhereItIs() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            await press(harness, .tab)
            await press(harness, .space)
            await press(harness, .tab)
            #expect(inputHasFocus(harness))
            harness.environment.quickLook.close()
            await SnapshotRenderer.settle(0.2)
            #expect(inputHasFocus(harness))
        }

        @Test func aNewChatClosesThePreviewAndTabStaysInTheInput() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            await press(harness, .tab)
            await press(harness, .space)
            harness.environment.startNewChat()
            await SnapshotRenderer.settle(0.3)
            #expect(!harness.quickLook.isVisible)
            #expect(inputHasFocus(harness))
            await press(harness, .tab)
            await press(harness, .space)
            #expect(!harness.quickLook.isVisible, "no card, no preview")
        }

        // MARK: Opening a file that is gone

        /// UX-2: a card may be hours old; a file moved or deleted since is
        /// explained under the input instead of failing silently.
        @Test func aFileThatIsGoneIsExplainedUnderTheInput() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            let accessibility = AccessibilityTree()
            defer { accessibility.end() }
            harness.workspace.remove(Self.latestFiles[0].url)
            await press(harness, .tab)
            await press(harness, .returnKey)
            await SnapshotRenderer.settle(0.2)
            #expect(harness.workspace.opened.isEmpty)
            #expect(harness.closeCount() == 0)
            let hint = "“Beleg-1.pdf” was not found. It may have been moved or deleted."
            #expect(accessibilityElement(in: harness) { label(of: $0) == hint || $0.value(forKey: "accessibilityValue") as? String == hint } != nil)

            // The next one opens.
            await press(harness, .down)
            await press(harness, .returnKey)
            #expect(await SearchTestSupport.eventually { harness.workspace.opened == [Self.latestFiles[1].url] })
        }

        // MARK: VoiceOver

        /// A11Y-1: the keyboard stays on the card, so VoiceOver hears the row
        /// Tab and the arrow keys select, not the preview's own navigation.
        @Test func voiceOverHearsTheSelectedFile() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            let announcer = harness.announcer
            await press(harness, .tab)
            #expect(announcer.announcements.count == 1)
            #expect(announcer.announcements.last?.hasPrefix("Beleg-1.pdf, ") == true)
            #expect(announcer.priorities.last == .medium, "after VoiceOver named the card")

            await press(harness, .down)
            #expect(announcer.announcements.last?.hasPrefix("Beleg-2.pdf, ") == true)
            #expect(announcer.priorities.last == .high)
            await press(harness, .up, times: 2)
            #expect(announcer.announcements.suffix(2).map { $0.components(separatedBy: ",").first } == ["Beleg-1.pdf", "Beleg-1.pdf"],
                    "at the first row it says where the keyboard stays")
            let expected = FileCardFormat.announcement(for: Self.latestFiles[0])
            #expect(announcer.announcements.last == expected)

            let heard = announcer.announcements.count
            await press(harness, .space)
            harness.quickLook.userShows(3)
            await SnapshotRenderer.settle(0.2)
            #expect(announcer.announcements.count == heard, "the preview speaks for itself")
        }

        @Test func rowsOfferLabelValueHintAndActions() async throws {
            let harness = try await Self.makeHarness()
            defer { harness.panel.orderOut(nil) }
            let accessibility = AccessibilityTree()
            defer { accessibility.end() }
            let row = try #require(accessibilityElement(in: harness) { label(of: $0) == "Rechnungen" })
            #expect((row.value(forKey: "accessibilityValue") as? String)?.hasPrefix("~/Documents") == true
                    || (row.value(forKey: "accessibilityValue") as? String)?.hasPrefix("/Users/orbit-test/Documents") == true)
            #expect(row.value(forKey: "accessibilityHelp") as? String == "Opens the folder")
            let actions = (row.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction]) ?? []
            #expect(actions.map(\.name) == ["Open", "Quick Look", "Show in Finder", "Copy Path"])

            let reveal = try #require(actions.first { $0.name == "Show in Finder" })
            perform(reveal)
            #expect(await SearchTestSupport.eventually { harness.workspace.revealed == [Self.olderFiles[1].url] })
            let quickLook = try #require(actions.first { $0.name == "Quick Look" })
            perform(quickLook)
            await SnapshotRenderer.settle(0.1)
            #expect(harness.environment.quickLook.preview?.source == harness.olderCard)
            #expect(harness.environment.quickLook.preview?.index == 1)

            let file = try #require(accessibilityElement(in: harness) { label(of: $0) == "Beleg-2.pdf" })
            #expect(file.value(forKey: "accessibilityHelp") as? String == "Opens the file")
            #expect((file.value(forKey: "accessibilityValue") as? String)?.hasSuffix("240 kB") == true
                    || (file.value(forKey: "accessibilityValue") as? String)?.hasSuffix("240 KB") == true)
        }

        // MARK: Accessibility tree

        /// SwiftUI builds its accessibility tree only for an assistive client; the
        /// app's own "enhanced user interface" attribute asks for it in-process.
        @MainActor
        final class AccessibilityTree {
            init() {
                NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
            }

            func end() {
                NSApp.setValue(false, forKey: "accessibilityEnhancedUserInterface")
            }
        }

        /// What VoiceOver does for a named action.
        private func perform(_ action: NSAccessibilityCustomAction) {
            if let handler = action.handler {
                _ = handler()
            } else if let target = action.target as? NSObject, let selector = action.selector {
                _ = target.perform(selector, with: action)
            }
        }

        private func label(of element: NSObject) -> String? {
            element.value(forKey: "accessibilityLabel") as? String
        }

        private func accessibilityElement(in harness: Harness, where matches: (NSObject) -> Bool) -> NSObject? {
            var queue: [NSObject] = harness.panel.contentView.map { [$0] } ?? []
            var visited = 0
            while !queue.isEmpty, visited < 5_000 {
                let element = queue.removeFirst()
                visited += 1
                if matches(element) { return element }
                let children = element.value(forKey: "accessibilityChildren") as? [NSObject] ?? []
                queue.append(contentsOf: children)
            }
            return nil
        }

        private func rowNames(in harness: Harness) -> Set<String> {
            var names: Set<String> = []
            var queue: [NSObject] = harness.panel.contentView.map { [$0] } ?? []
            var visited = 0
            while !queue.isEmpty, visited < 5_000 {
                let element = queue.removeFirst()
                visited += 1
                if let label = label(of: element), label.hasPrefix("Beleg-") { names.insert(label) }
                queue.append(contentsOf: element.value(forKey: "accessibilityChildren") as? [NSObject] ?? [])
            }
            return names
        }
    }
}
