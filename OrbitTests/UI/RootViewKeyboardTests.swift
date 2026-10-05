import AppKit
import SwiftUI
import Testing
@testable import Orbit

extension UIWindowTests {
    /// Drives the real RootView with synthesized key events in an offscreen panel
    /// (verifies focus, Return, ⌘Return, arrows, ⌘1 to ⌘9, ⌘N and Escape wiring, the
    /// parked chat after a pause and what VoiceOver hears).
    /// Requests fail fast against a closed local port (see SnapshotEnvironment);
    /// instant search runs on fakes (no apps unless a test adds some).
    ///
    ///     ORBIT_UI_TESTS=1 Scripts/swiftpm.sh test --filter RootViewKeyboard
    @MainActor
    @Suite("RootViewKeyboard", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_UI_TESTS"] == "1"))
    struct RootViewKeyboardTests {
        private struct Harness {
            let environment: AppEnvironment
            let panel: NSPanel
            let closeCount: () -> Int
        }

        private final class Counter {
            var value = 0
        }

        private func makeHarness(services: AppServices = .fake()) async -> Harness {
            _ = NSApplication.shared
            let environment = SnapshotEnvironment.make(services: services)
            let closes = Counter()
            environment.panelState.closePanel = { closes.value += 1 }
            let panel = OffscreenKeyPanel(size: CGSize(width: Theme.panelWidth, height: 400))
            panel.contentView = NSHostingView(rootView: RootView(environment: environment))
            panel.makeKeyAndOrderFront(nil)
            #expect(panel.isOffscreen, "nothing may appear on the screen")
            await SnapshotRenderer.settle(0.4)
            return Harness(environment: environment, panel: panel, closeCount: { closes.value })
        }

        private func press(_ harness: Harness, keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = []) async {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: harness.panel.windowNumber, context: nil,
                                                   characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: keyCode) else { continue }
                // Key equivalents (⌘-shortcuts of buttons) go through performKeyEquivalent first, like in a key window.
                if type == .keyDown, modifiers.contains(.command), harness.panel.performKeyEquivalent(with: event) {
                    continue
                }
                NSApp.sendEvent(event)
            }
            await SnapshotRenderer.settle(0.1)
        }

        private func type(_ harness: Harness, _ text: String) async {
            for character in text {
                await press(harness, keyCode: 0, characters: String(character))
            }
        }

        /// Waits until a request has finished (offline it fails after the provider's retries, about 4 s).
        private func waitUntilIdle(_ harness: Harness) async {
            await harness.environment.agentLoop.waitUntilIdle()
            await SnapshotRenderer.settle(0.1)
        }

        private func userMessages(_ harness: Harness) -> [String] {
            harness.environment.agentLoop.items.compactMap { item in
                if case .user(let text, _) = item.kind { return text }
                return nil
            }
        }

        private func inputHasFocus(_ harness: Harness) -> Bool {
            harness.panel.firstResponder is NSTextView
        }

        private func mode(_ harness: Harness) -> PanelMode {
            let environment = harness.environment
            return PanelMode.resolve(hasConversation: environment.agentLoop.hasConversation,
                                     isChatParked: environment.chatParking.isParked,
                                     inputText: environment.panelState.inputText)
        }

        /// The panel is hidden for `seconds` and shown again, as PanelController does it.
        private func reopen(_ harness: Harness, after seconds: TimeInterval) async {
            let parking = harness.environment.chatParking
            let hidden = Date()
            parking.now = { hidden }
            parking.panelDidHide()
            parking.now = { hidden.addingTimeInterval(seconds) }
            parking.panelWillAppear()
            harness.environment.panelState.showCount += 1
            await SnapshotRenderer.settle(0.3)
        }

        /// A chat with one question (the request fails fast offline).
        private func startChat(_ harness: Harness, _ text: String) async {
            await type(harness, text)
            await press(harness, keyCode: 36, characters: "\r")
            await waitUntilIdle(harness)
            #expect(mode(harness) == .chat)
        }

        /// The accessibility element with `label` (or with it as its value, like static text).
        private func accessibilityElement(in harness: Harness, labeled label: String) -> NSObject? {
            accessibilityElement(in: harness) { element in
                element.value(forKey: "accessibilityLabel") as? String == label
                    || element.value(forKey: "accessibilityValue") as? String == label
            }
        }

        private func accessibilityElement(in harness: Harness, where matches: (NSObject) -> Bool) -> NSObject? {
            var queue: [NSObject] = harness.panel.contentView.map { [$0] } ?? []
            var visited = 0
            while !queue.isEmpty, visited < 5_000 {
                let element = queue.removeFirst()
                visited += 1
                if matches(element) { return element }
                queue.append(contentsOf: element.value(forKey: "accessibilityChildren") as? [NSObject] ?? [])
            }
            return nil
        }

        /// Every button VoiceOver reads as `label`, in the order of the accessibility tree.
        private func accessibilityButtons(in harness: Harness, labeled label: String) -> [NSObject] {
            var queue: [NSObject] = harness.panel.contentView.map { [$0] } ?? []
            var found: [NSObject] = []
            var visited = 0
            while !queue.isEmpty, visited < 5_000 {
                let element = queue.removeFirst()
                visited += 1
                if element.value(forKey: "accessibilityRole") as? String == "AXButton",
                   element.value(forKey: "accessibilityLabel") as? String == label {
                    found.append(element)
                }
                queue.append(contentsOf: element.value(forKey: "accessibilityChildren") as? [NSObject] ?? [])
            }
            return found
        }

        @Test func typingSearchingAndSending() async {
            let harness = await makeHarness()
            defer { harness.panel.orderOut(nil) }
            let environment = harness.environment
            #expect(inputHasFocus(harness), "the input is focused when the panel appears")

            await type(harness, "zqxjv")
            #expect(environment.panelState.inputText == "zqxjv")
            #expect(mode(harness) == .search)

            // Arrows and ⌘1 are consumed in search mode (no results here) and must not change the text.
            await press(harness, keyCode: 125, characters: "\u{F701}")
            await press(harness, keyCode: 126, characters: "\u{F700}")
            await press(harness, keyCode: 18, characters: "1", modifiers: .command)
            #expect(environment.panelState.inputText == "zqxjv")

            environment.panelState.attachments = SampleData.attachments
            await press(harness, keyCode: 36, characters: "\r")
            if case .user(let text, let attachments)? = environment.agentLoop.items.first?.kind {
                #expect(text == "zqxjv")
                #expect(attachments == SampleData.attachments)
            } else {
                Issue.record("expected a user message")
            }
            #expect(environment.panelState.inputText.isEmpty)
            #expect(environment.panelState.attachments.isEmpty)
            #expect(inputHasFocus(harness))

            // Chat mode: Return sends the follow-up once the first request is done, also when the
            // panel was hidden and shown again within the pause.
            await waitUntilIdle(harness)
            await reopen(harness, after: ChatParking.pause - 1)
            #expect(mode(harness) == .chat)
            await type(harness, "Weiter")
            await press(harness, keyCode: 36, characters: "\r")
            #expect(userMessages(harness) == ["zqxjv", "Weiter"])
            await waitUntilIdle(harness)

            // After a pause the chat is parked: typing searches, and Return asks Orbit in a new chat.
            let parked = environment.agentLoop.conversationID
            await reopen(harness, after: ChatParking.pause)
            #expect(mode(harness) == .compact)
            await type(harness, "Neu")
            #expect(mode(harness) == .search)
            await press(harness, keyCode: 36, characters: "\r")
            #expect(userMessages(harness) == ["Neu"], "a new chat")
            #expect(environment.agentLoop.conversationID != parked)
            #expect(environment.settings.dismissedConversationID == parked, "the parked chat was closed like with ⌘N")
            #expect(mode(harness) == .chat)
            await waitUntilIdle(harness)

            // ⌘N starts a new chat.
            await press(harness, keyCode: 45, characters: "n", modifiers: .command)
            #expect(!environment.agentLoop.hasConversation)
            #expect(environment.panelState.inputText.isEmpty)
        }

        /// "Nach Pause: Suche zuerst": the panel opens in search mode with the
        /// chat one step away: ↑ in the empty input or "Continue chat" bring
        /// it back, typing searches (instant results, not the model).
        @Test func afterAPauseThePanelSearchesAndTheChatIsOneStepAway() async throws {
            let folder = try TemporaryFolder("keyboard-parked")
            defer { folder.remove() }
            let opener = MockSearchOpener()
            let harness = await makeHarness(services: try SampleData.instantSearchServices(in: folder, opener: opener))
            defer { harness.panel.orderOut(nil) }
            let environment = harness.environment
            let accessibility = UIWindowTests.FileCardKeyboardTests.AccessibilityTree()
            defer { accessibility.end() }
            await startChat(harness, "Wie spät ist es in Tokio?")
            let items = environment.agentLoop.items

            await reopen(harness, after: ChatParking.pause)
            #expect(mode(harness) == .compact)
            #expect(inputHasFocus(harness))
            let row = "Chat fortsetzen: „Wie spät ist es in Tokio?“"
            #expect(accessibilityElement(in: harness, labeled: row) != nil, "the row under the empty input")
            let input = try #require(accessibilityElement(in: harness) { $0.value(forKey: "accessibilityRole") as? String == "AXTextField" })
            #expect(input.value(forKey: "accessibilityHelp") as? String == "Type to search; the Up Arrow continues the last chat.")

            // Typing searches like without a chat; the row gives way to the results.
            await type(harness, "ma")
            let search = environment.instantSearch
            #expect(await SearchTestSupport.eventually { search.results.count == 7 && !search.isSearching })
            #expect(accessibilityElement(in: harness, labeled: row) == nil)
            await press(harness, keyCode: 125, characters: "\u{F701}")
            await press(harness, keyCode: 36, characters: "\r")
            #expect(await SearchTestSupport.eventually { opener.openedApps.map(\.lastPathComponent) == ["Mail.app"] })
            #expect(environment.agentLoop.items == items, "nothing went to the model")

            // ↑ in the empty input continues the chat, with the keyboard in the input.
            #expect(environment.panelState.inputText.isEmpty)
            #expect(mode(harness) == .compact)
            await press(harness, keyCode: 126, characters: "\u{F700}")
            #expect(mode(harness) == .chat)
            #expect(inputHasFocus(harness))
            #expect(environment.agentLoop.items == items)

            // And so does the row (VoiceOver presses it like a click).
            await reopen(harness, after: 10 * 60)
            let button = try #require(accessibilityElement(in: harness, labeled: row))
            #expect(button.value(forKey: "accessibilityHelp") as? String == "Shows the last chat again.")
            #expect(button.responds(to: NSSelectorFromString("accessibilityPerformPress")))
            _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
            await SnapshotRenderer.settle(0.2)
            #expect(mode(harness) == .chat)
            #expect(inputHasFocus(harness))

            // Escape closes the panel as usual while the chat is parked.
            await reopen(harness, after: 10 * 60)
            await press(harness, keyCode: 53, characters: "\u{1B}")
            #expect(harness.closeCount() == 2, "the result closed it once, Escape once")

            // ⌘N (the menu) discards the parked chat.
            environment.startNewChat()
            await SnapshotRenderer.settle(0.2)
            #expect(!environment.agentLoop.hasConversation)
            #expect(accessibilityElement(in: harness, labeled: row) == nil)
        }

        /// ERR-7, FC5-3: after a notice that the conversation no longer fits,
        /// ⌘N, the input's "New Chat" button and the notice's "New Chat"
        /// each start a new chat with the request it could not answer in the
        /// input, not sent until Return. (The chat comes by a restore: offline,
        /// requests fail with another notice here.)
        @Test func everyNewChatInThePanelKeepsARequestTheChatCouldNoLongerAnswer() async throws {
            let harness = await makeHarness()
            defer { harness.panel.orderOut(nil) }
            let environment = harness.environment
            let accessibility = UIWindowTests.FileCardKeyboardTests.AccessibilityTree()
            defer { accessibility.end() }
            let request = "Und was steht in der langen Datei?"

            /// A chat whose request no longer fit, restored and shown.
            func showTooLongChat() async throws {
                environment.panelState.inputText = ""
                let notice = Notice(style: .error, message: LLMError.contextTooLong.userMessage, action: .newChat)
                try await environment.conversationStore.save(Conversation(title: request, items: [
                    ChatItem(kind: .user(text: request, attachments: [])), ChatItem(kind: .notice(notice)),
                ]))
                await environment.chatParking.restoreMostRecentChat()
                environment.chatParking.unpark()
                await SnapshotRenderer.settle(0.3)
                #expect(environment.agentLoop.requestForNewChat == request)
                #expect(mode(harness) == .chat)
            }

            try await showTooLongChat()
            await press(harness, keyCode: 45, characters: "n", modifiers: .command)
            #expect(environment.panelState.inputText == request, "⌘N")
            #expect(!environment.agentLoop.hasConversation)

            // The input's button and the notice's (pressed as VoiceOver does).
            for index in 0..<2 {
                try await showTooLongChat()
                let buttons = accessibilityButtons(in: harness, labeled: "New Chat")
                #expect(buttons.count == 2, "the input's and the notice's")
                guard buttons.indices.contains(index) else { continue }
                _ = buttons[index].perform(NSSelectorFromString("accessibilityPerformPress"))
                await SnapshotRenderer.settle(0.2)
                #expect(environment.panelState.inputText == request, "button \(index + 1)")
                #expect(!environment.agentLoop.hasConversation)
            }

            // Return asks Orbit with it (the input is a search now; "Orbit fragen" is highlighted).
            #expect(mode(harness) == .search)
            await press(harness, keyCode: 36, characters: "\r")
            #expect(userMessages(harness) == [request])
            await waitUntilIdle(harness)
        }

        /// A follow-up typed but not sent keeps the chat through a pause: the
        /// draft stays in the chat's input, and Return sends it to that chat.
        @Test func aDraftedFollowUpKeepsTheChatAfterAPause() async {
            let harness = await makeHarness()
            defer { harness.panel.orderOut(nil) }
            let environment = harness.environment
            await startChat(harness, "Wie spät ist es in Tokio?")
            let conversation = environment.agentLoop.conversationID
            await type(harness, "Und in Rom")

            await reopen(harness, after: 10 * 60)
            #expect(!environment.chatParking.isParked)
            #expect(mode(harness) == .chat)
            #expect(environment.panelState.inputText == "Und in Rom")
            #expect(inputHasFocus(harness))
            await press(harness, keyCode: 36, characters: "\r")
            #expect(userMessages(harness) == ["Wie spät ist es in Tokio?", "Und in Rom"])
            #expect(environment.agentLoop.conversationID == conversation, "a follow-up, not a new chat")
            await waitUntilIdle(harness)
        }

        /// After a relaunch the restored chat is parked; continuing it shows its
        /// end, with the keyboard in the input.
        @Test func continuingARestoredChatShowsItsEnd() async throws {
            let harness = await makeHarness()
            defer { harness.panel.orderOut(nil) }
            let environment = harness.environment
            let answers = (1...30).map { number in
                ChatItem(kind: .assistant(text: "Antwort \(number): " + String(repeating: "Lorem ipsum dolor sit amet. ", count: 8),
                                          isStreaming: false))
            }
            let conversation = Conversation(title: "Erzähl mir viel",
                                            items: [ChatItem(kind: .user(text: "Erzähl mir viel", attachments: []))] + answers)
            try await environment.conversationStore.save(conversation)
            await environment.chatParking.restoreMostRecentChat()
            #expect(environment.agentLoop.conversationID == conversation.id)
            #expect(environment.chatParking.isParked, "a restored chat starts parked")
            await SnapshotRenderer.settle(0.3)
            #expect(mode(harness) == .compact)

            await press(harness, keyCode: 126, characters: "\u{F700}")
            await SnapshotRenderer.settle(0.6)
            #expect(mode(harness) == .chat)
            #expect(inputHasFocus(harness))
            let scrollView = try #require(Self.scrollView(in: harness.panel.contentView))
            let document = try #require(scrollView.documentView)
            let visible = scrollView.contentView.documentVisibleRect
            #expect(document.frame.height > visible.height + 100, "the chat is longer than the panel")
            let distanceToEnd = document.isFlipped ? document.frame.height - visible.maxY : visible.minY
            #expect(distanceToEnd < 2, "scrolled to the end (\(distanceToEnd) pt left)")
        }

        private static func scrollView(in view: NSView?) -> NSScrollView? {
            guard let view else { return nil }
            if let scrollView = view as? NSScrollView { return scrollView }
            for subview in view.subviews {
                if let found = scrollView(in: subview) { return found }
            }
            return nil
        }

        /// ↑/↓ keep the keyboard in the input: VoiceOver hears the highlighted
        /// row with its ⌘ number, and each search's result count once, not when
        /// results refresh.
        @Test func voiceOverHearsTheHighlightedRow() async throws {
            let folder = try TemporaryFolder("keyboard-voiceover")
            defer { folder.remove() }
            let announcer = RecordingAnnouncer()
            let harness = await makeHarness(services: try SampleData.instantSearchServices(in: folder, announcer: announcer))
            defer { harness.panel.orderOut(nil) }
            let search = harness.environment.instantSearch

            await type(harness, "ma")
            #expect(await SearchTestSupport.eventually { search.results.count == 7 && !search.isSearching })
            await SnapshotRenderer.settle(0.1)
            #expect(announcer.announcements.last == "7 Ergebnisse")
            #expect(announcer.priorities.last == .medium, "after what VoiceOver is saying")
            let counted = announcer.announcements.count

            await press(harness, keyCode: 125, characters: "\u{F701}")
            await press(harness, keyCode: 125, characters: "\u{F701}")
            await press(harness, keyCode: 126, characters: "\u{F700}")
            await press(harness, keyCode: 126, characters: "\u{F700}")
            #expect(Array(announcer.announcements.dropFirst(counted)) == [
                "Mail, Programm, Befehl-1", "Karten, Programm, Befehl-2", "Mail, Programm, Befehl-1", "Orbit fragen: „ma“",
            ])
            #expect(announcer.priorities.suffix(4) == [.high, .high, .high, .high])

            // Showing the panel again refreshes the results silently.
            let heard = announcer.announcements.count
            harness.environment.panelState.showCount += 1
            #expect(await SearchTestSupport.eventually { !search.isSearching })
            await SnapshotRenderer.settle(0.3)
            #expect(announcer.announcements.count == heard)
        }

        /// UX-2: a file moved or deleted since the search is not opened; the
        /// panel stays, says so, and searches again.
        @Test func aResultThatIsGoneIsNotOpened() async throws {
            let folder = try TemporaryFolder("keyboard-gone")
            defer { folder.remove() }
            let opener = MockSearchOpener()
            let workspace = MockWorkspace()
            let harness = await makeHarness(services: try SampleData.instantSearchServices(in: folder, opener: opener,
                                                                                            workspace: workspace))
            defer { harness.panel.orderOut(nil) }
            let search = harness.environment.instantSearch
            let accessibility = UIWindowTests.FileCardKeyboardTests.AccessibilityTree()
            defer { accessibility.end() }

            await type(harness, "ma")
            #expect(await SearchTestSupport.eventually { search.results.count == 7 && !search.isSearching })
            guard case .file(let url) = search.results[2].kind else {
                Issue.record("⌘3 is the first file")
                return
            }
            workspace.remove(url)
            let spotlight = try #require(harness.environment.services.spotlight as? MockSpotlight)
            let queries = spotlight.queries.count
            await press(harness, keyCode: 20, characters: "3", modifiers: .command)
            await SnapshotRenderer.settle(0.2)
            #expect(opener.openedURLs.isEmpty)
            #expect(harness.closeCount() == 0)
            #expect(harness.environment.panelState.inputText == "ma")
            let hint = "“\(url.lastPathComponent)” was not found. It may have been moved or deleted."
            #expect(accessibilityElement(in: harness, labeled: hint) != nil)
            #expect(await SearchTestSupport.eventually { spotlight.queries.count == queries + 2 }, "searched again")
        }

        /// Typed text shows instant results; ↓ + Return, ⌘2 and ⌘3 open them.
        @Test func instantResultsOpenFromTheKeyboard() async throws {
            let folder = try TemporaryFolder("keyboard-instant")
            defer { folder.remove() }
            let opener = MockSearchOpener()
            let harness = await makeHarness(services: try SampleData.instantSearchServices(in: folder, opener: opener))
            defer { harness.panel.orderOut(nil) }
            let search = harness.environment.instantSearch

            await type(harness, "ma")
            #expect(await SearchTestSupport.eventually { search.results.count == 7 && !search.isSearching })
            // Showing the panel again searches the text again (files may have changed meanwhile).
            let spotlight = try #require(harness.environment.services.spotlight as? MockSpotlight)
            let queries = spotlight.queries.count
            harness.environment.panelState.showCount += 1
            #expect(await SearchTestSupport.eventually { spotlight.queries.count == queries + 2 && !search.isSearching })
            #expect(search.results.count == 7)
            await SnapshotRenderer.settle(0.1)
            await press(harness, keyCode: 125, characters: "\u{F701}")
            await press(harness, keyCode: 36, characters: "\r")
            #expect(await SearchTestSupport.eventually { opener.openedApps.map(\.lastPathComponent) == ["Mail.app"] })
            #expect(harness.closeCount() == 1)
            #expect(harness.environment.panelState.inputText.isEmpty)
            #expect(search.results.isEmpty)
            #expect(!harness.environment.agentLoop.hasConversation, "opening a result does not ask the agent")

            await type(harness, "ma")
            #expect(await SearchTestSupport.eventually { search.results.count == 7 && !search.isSearching })
            await press(harness, keyCode: 19, characters: "2", modifiers: .command)
            #expect(await SearchTestSupport.eventually { opener.openedApps.map(\.lastPathComponent) == ["Mail.app", "Maps.app"] })

            await type(harness, "ma")
            #expect(await SearchTestSupport.eventually { search.results.count == 7 && !search.isSearching })
            await press(harness, keyCode: 20, characters: "3", modifiers: .command)
            #expect(await SearchTestSupport.eventually { opener.openedURLs.map(\.lastPathComponent) == ["Mahnung März.pdf"] })
            #expect(harness.closeCount() == 3)
        }

        @Test func commandReturnAlwaysAsks() async {
            let harness = await makeHarness()
            defer { harness.panel.orderOut(nil) }
            await type(harness, "zqxjv")
            await press(harness, keyCode: 36, characters: "\r", modifiers: .command)
            #expect(userMessages(harness) == ["zqxjv"])
            await waitUntilIdle(harness)
        }

        @Test func escapeClosesWhenIdle() async {
            let harness = await makeHarness()
            defer { harness.panel.orderOut(nil) }
            await press(harness, keyCode: 53, characters: "\u{1B}")
            #expect(harness.closeCount() == 1)
        }

        @Test func showingThePanelRefocusesTheInput() async {
            let harness = await makeHarness()
            defer { harness.panel.orderOut(nil) }
            harness.panel.makeFirstResponder(nil)
            #expect(!inputHasFocus(harness))
            harness.environment.panelState.showCount += 1
            await SnapshotRenderer.settle(0.3)
            #expect(inputHasFocus(harness))
        }

        @Test func reportsContentHeight() async {
            let harness = await makeHarness()
            defer { harness.panel.orderOut(nil) }
            let compact = harness.environment.panelState.preferredContentHeight
            await type(harness, "zqxjv")
            let search = harness.environment.panelState.preferredContentHeight
            #expect(compact > 40 && compact < 80)
            #expect(search > compact)
        }

        /// UX-3: ⌫ in the empty input removes the last context chip (VoiceOver hears which); with text it deletes
        /// the text, and held down it stops at the empty input.
        @Test func backspaceRemovesTheLastChipFromTheEmptyInput() async {
            let announcer = RecordingAnnouncer()
            let harness = await makeHarness(services: .fake(announcer: announcer))
            defer { harness.panel.orderOut(nil) }
            let panelState = harness.environment.panelState
            let first = ContextAttachment(kind: .finderSelection(paths: ["~/Documents/Angebot.pdf"]), label: "Mit Auswahl: Angebot.pdf")
            let second = ContextAttachment(kind: .selectedText(text: "Lieferung", appName: "Mail"), label: "Mit Auswahl: „Lieferung“ (Mail)")
            panelState.attachments = [first, second]
            await SnapshotRenderer.settle(0.2)
            await type(harness, "x")
            await press(harness, keyCode: 51, characters: "\u{7F}")
            #expect(panelState.inputText.isEmpty)
            #expect(panelState.attachments == [first, second], "⌫ deleted the text, not a chip")
            await press(harness, keyCode: 51, characters: "\u{7F}")
            #expect(panelState.attachments == [first])
            #expect(announcer.announcements.last == "Context removed: Mit Auswahl: „Lieferung“ (Mail)")
            await press(harness, keyCode: 51, characters: "\u{7F}")
            #expect(panelState.attachments.isEmpty)
            #expect(inputHasFocus(harness), "the keyboard stays in the input")
        }

        /// ⌘Return with text in the input sends it; it must never approve a
        /// pending action. With an empty input, ⌘Return approves.
        @Test func commandReturnApprovesOnlyWithAnEmptyInput() async {
            _ = NSApplication.shared
            let request = ConfirmationRequest(toolCallID: "t1", toolName: "move_to_trash", riskLevel: .destructive,
                                              title: "In den Papierkorb legen", message: "3 Dateien")
            for inputIsEmpty in [false, true] {
                let decisions = Counter()
                let card = ConfirmationCard(state: ConfirmationState(request: request, status: .pending),
                                            approveShortcutEnabled: inputIsEmpty) { _ in decisions.value += 1 }
                let panel = OffscreenKeyPanel(size: CGSize(width: 500, height: 300))
                panel.contentView = NSHostingView(rootView: card.frame(width: 480))
                panel.makeKeyAndOrderFront(nil)
                await SnapshotRenderer.settle(0.3)
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber, context: nil, characters: "\r",
                                             charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
                let handled = event.map { panel.performKeyEquivalent(with: $0) } ?? false
                await SnapshotRenderer.settle(0.1)
                #expect(handled == inputIsEmpty)
                #expect(decisions.value == (inputIsEmpty ? 1 : 0))
                panel.orderOut(nil)
            }
        }
    }
}
