import AppKit
import Foundation
import Testing
@testable import Orbit

/// The app's environment (its shared actions and how it wires the agent loop to
/// the panel) on fakes: settings and the chat history in memory, no keychain, a
/// scripted provider. The panel is never shown: tests set `PanelState` the way
/// the panel controller does.
@Suite("App environment")
@MainActor
struct AppEnvironmentTests {
    @MainActor
    private struct Harness {
        let environment: AppEnvironment
        let provider: MockLLMProvider
        /// What VoiceOver would hear.
        let announcer: RecordingAnnouncer

        var agentLoop: AgentLoop { environment.agentLoop }
        var panelState: PanelState { environment.panelState }

        /// Sends and waits until the run is over.
        func send(_ text: String, attachments: [ContextAttachment] = []) async {
            agentLoop.send(text, attachments: attachments)
            await agentLoop.waitUntilIdle()
        }
    }

    private func makeHarness(_ scripts: [[MockLLMProvider.Step]]) throws -> Harness {
        let provider = MockLLMProvider(scripts: scripts)
        let announcer = RecordingAnnouncer()
        let environment = AppEnvironment(services: .fake(announcer: announcer),
                                         settings: SettingsStore(defaults: AgentTestDefaults()),
                                         secrets: InMemorySecretStore([SecretAccount.anthropicAPIKey: "test-key"]),
                                         conversationStore: ConversationStore(database: try AppDatabase.inMemory()),
                                         claudeCodeRuntime: ClaudeCodeRuntime(),
                                         providerFactory: LLMProviderFactory { _ in provider })
        return Harness(environment: environment, provider: provider, announcer: announcer)
    }

    // MARK: A new chat (ERR-7, FC5-1, FC5-3)

    /// A chat that ends with a notice that it no longer fits the model: a new chat (⌘N, the input's button, the
    /// menus and the notice's "New Chat" all start it here) has the request it could not answer in its input,
    /// as typed, to send again or change: not sent, and without the request's chips. Every other chat starts
    /// with an empty input, as before.
    @Test(arguments: [
        [MockLLMProvider.Step.fail(LLMError.contextTooLong)],
        [.fail(LLMError.requestTooLarge)],
        [.end([], stopReason: .contextWindowExceeded)],
    ])
    func aNewChatKeepsTheRequestTheChatCouldNoLongerAnswer(failure: [MockLLMProvider.Step]) async throws {
        let harness = try makeHarness([MockScript.answer("Eins."), MockScript.answer("Zwei."), failure])
        await harness.send("Erste Frage")
        harness.panelState.inputText = "Entwurf"
        harness.environment.startNewChat()
        #expect(harness.panelState.inputText.isEmpty, "a chat that ended with an answer leaves nothing behind")
        #expect(!harness.agentLoop.hasConversation)

        await harness.send("Zweite Frage")
        await harness.send("  Und was steht in der langen Datei?  ", attachments: SampleData.attachments)
        #expect(harness.agentLoop.requestForNewChat == "Und was steht in der langen Datei?")
        let requests = harness.provider.requests.count
        harness.environment.startNewChat()
        #expect(harness.panelState.inputText == "Und was steht in der langen Datei?")
        #expect(harness.panelState.attachments.isEmpty, "its chips stay behind: what was selected may have changed")
        #expect(!harness.agentLoop.hasConversation && !harness.agentLoop.isRunning, "a new chat, the request not sent")
        #expect(harness.provider.requests.count == requests)

        // Once the new chat started, the next one starts empty again.
        harness.environment.startNewChat()
        #expect(harness.panelState.inputText.isEmpty)
    }

    /// FC5-3: the Chat menu's "New Chat" (⌘N) and the menu bar menu's reach the same new chat through the
    /// app's actions; the request the chat could no longer answer is kept there too.
    @Test(arguments: ["Chat", "Menüleiste"])
    func theMenusNewChatKeepsTheRequestToo(menu: String) async throws {
        let harness = try makeHarness([[.fail(LLMError.contextTooLong)]])
        await harness.send("Und was steht in der langen Datei?")
        // Menu items hold their targets weakly, the menus their actions: all stay alive until the item ran.
        let delegate = AppDelegate(environment: harness.environment)
        let mainMenu = MainMenu(actions: delegate)
        let menuBarMenu = MenuBarMenu(actions: delegate)
        try withExtendedLifetime((delegate, mainMenu, menuBarMenu)) {
            let item = if menu == "Chat" {
                try #require(mainMenu.menu.items.compactMap(\.submenu).flatMap(\.items).first {
                    $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == .command
                })
            } else {
                try #require(menuBarMenu.menu.items.first { $0.title == "New Chat" })
            }
            let target = try #require(item.target)
            _ = target.perform(item.action, with: item)
        }
        #expect(!harness.agentLoop.hasConversation)
        #expect(harness.panelState.inputText == "Und was steht in der langen Datei?")
    }

    // MARK: A card that waits (A11Y-1, FC5-2, FC5-4)

    static let volumeCall: [[MockLLMProvider.Step]] = [
        MockScript.toolCalls([MockScript.call("v1", "set_volume", ["level": 40])]),
        MockScript.answer("Nicht geändert."),
    ]
    static let cardWithoutKeys = "Confirmation needed: Change volume. Open Orbit to run or cancel the action."
    static let cardWithKeys = "Confirmation needed: Change volume. ⌘↩ runs the action, ⌘. cancels it."

    private func waitForTheCard(_ harness: Harness) async {
        harness.agentLoop.send("Stell die Lautstärke auf 40", attachments: [])
        #expect(await AgentHarness.eventually { harness.agentLoop.pendingConfirmation != nil })
    }

    private func cancelTheCard(_ harness: Harness) async throws {
        let request = try #require(harness.agentLoop.pendingConfirmation)
        harness.agentLoop.resolveConfirmation(request.id, decision: .cancelled)
        await harness.agentLoop.waitUntilIdle()
    }

    /// FC5-2: the user went to another app while Orbit worked, so the panel is hidden: the card is read without
    /// ⌘↩ and ⌘. (they would reach that app), and with them as soon as the panel is shown: the panel controller
    /// sets `isVisible`, no view takes part. Each later show reads it again while it waits.
    @Test func aCardThatWaitedWhileThePanelWasHiddenIsReadWithItsKeysWhenItIsShown() async throws {
        let harness = try makeHarness(Self.volumeCall)
        await waitForTheCard(harness)
        #expect(harness.announcer.announcements == [Self.cardWithoutKeys])

        harness.panelState.isVisible = true
        #expect(harness.announcer.announcements == [Self.cardWithoutKeys, Self.cardWithKeys])
        #expect(harness.announcer.priorities == [.high, .high], "it interrupts: the request waits for the user")
        harness.panelState.showCount += 1
        #expect(harness.announcer.announcements.count == 2, "shown again while it has the keyboard: said once")

        harness.panelState.isVisible = false
        harness.panelState.isVisible = true
        #expect(harness.announcer.announcements.last == Self.cardWithKeys)
        #expect(harness.announcer.announcements.count == 3)

        try await cancelTheCard(harness)
        let count = harness.announcer.announcements.count
        harness.panelState.isVisible = false
        harness.panelState.isVisible = true
        #expect(harness.announcer.announcements.count == count, "nothing waits: showing the panel says nothing")
    }

    /// FC5-4: one request replies to a mail and changes something that needs a card. Orbit hands the keyboard to
    /// Mail's reply window, and the panel stays visible without it: the card is read without ⌘↩ and ⌘. (they
    /// would reach the reply window), whether it comes while the window still opens or after it took the
    /// keyboard, and with them once the panel has the keyboard back (a click into it, or the shortcut).
    @Test(arguments: [false, true])
    func aCardWhileMailsReplyWindowHasTheKeyboardIsReadWithItsKeysOnceThePanelHasItBack(windowOpened: Bool)
        async throws {
        let harness = try makeHarness(Self.volumeCall)
        let state = harness.panelState
        state.isVisible = true
        #expect(harness.announcer.announcements.isEmpty, "shown without a card: nothing to say")
        let handoff = try #require(await state.beginKeyboardHandoff(to: "com.apple.mail"))
        if windowOpened {
            await state.endKeyboardHandoff(handoff, opened: true)
            // The panel controller: the reply window took the keyboard, the panel stays visible without it.
            state.keyboardHandoff.keepPanelVisible()
        }
        await waitForTheCard(harness)
        #expect(harness.announcer.announcements == [Self.cardWithoutKeys])

        if !windowOpened {
            await state.endKeyboardHandoff(handoff, opened: true)
            state.keyboardHandoff.keepPanelVisible()
        }
        // The panel controller: the panel became key again.
        state.panelDidBecomeKey()
        #expect(harness.announcer.announcements == [Self.cardWithoutKeys, Self.cardWithKeys])
        // The shortcut's `show()` sets `isVisible` too, so the card is not read twice.
        state.isVisible = true
        #expect(harness.announcer.announcements.count == 2)
        try await cancelTheCard(harness)
    }
}
