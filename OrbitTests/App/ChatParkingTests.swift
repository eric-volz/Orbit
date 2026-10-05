import Foundation
import Testing
@testable import Orbit

/// "Nach Pause: Suche zuerst": after the panel was hidden for 5 minutes an idle
/// chat is parked (the panel opens in search mode); sooner, or while the chat
/// needs the user, it stays. Runs on the agent harness with a settable clock.
@Suite("ChatParking")
@MainActor
struct ChatParkingTests {
    @Test(arguments: [
        // (conversation, running, pending confirmation, unsent message, hidden for, parks)
        (false, false, false, false, 3_600, false),
        (true, false, false, false, nil, false),
        (true, false, false, false, 0, false),
        (true, false, false, false, 299, false),
        (true, false, false, false, 300, true),
        (true, false, false, false, 86_400, true),
        (true, true, false, false, 3_600, false),
        (true, false, true, false, 3_600, false),
        (true, true, true, false, 3_600, false),
        (true, false, false, true, 3_600, false),
        (true, false, false, true, 86_400, false),
    ] as [(Bool, Bool, Bool, Bool, Double?, Bool)])
    func rules(hasConversation: Bool, isRunning: Bool, hasPendingConfirmation: Bool, hasUnsentMessage: Bool,
               hiddenFor: Double?, parks: Bool) {
        #expect(ChatParking.pause == 5 * 60)
        #expect(ChatParking.parks(hasConversation: hasConversation, isRunning: isRunning,
                                  hasPendingConfirmation: hasPendingConfirmation, hasUnsentMessage: hasUnsentMessage,
                                  hiddenFor: hiddenFor) == parks)
    }

    @Test func showingAfterAPauseParksTheChatWithoutEndingIt() async {
        let harness = AgentHarness(scripts: [MockScript.answer("Es ist 21:30.")])
        let parking = ChatParking(agentLoop: harness.agent, panelState: PanelState(), now: { harness.clock.now })
        parking.panelWillAppear()
        #expect(!parking.isParked, "no chat yet")

        await harness.send("Wie spät ist es?")
        let conversation = harness.agent.conversationID
        let items = harness.agent.items
        parking.panelWillAppear()
        #expect(!parking.isParked, "the panel was not hidden since launch")

        parking.panelDidHide()
        harness.clock.advance(by: 4 * 60 + 59)
        parking.panelWillAppear()
        #expect(!parking.isParked, "reopened within 5 minutes: the chat is still there")

        parking.panelDidHide()
        harness.clock.advance(by: 5 * 60)
        parking.panelWillAppear()
        #expect(parking.isParked, "after a pause the panel opens in search mode")
        #expect(harness.agent.conversationID == conversation, "parked, not discarded")
        #expect(harness.agent.items == items)
        #expect(harness.agent.hasConversation)

        parking.unpark()
        #expect(!parking.isParked)
        #expect(harness.agent.items == items)
    }

    @Test func aRunningAnswerIsNeverParked() async {
        let gate = AsyncGate()
        let harness = AgentHarness(scripts: [[.text("Ich sehe nach"), .wait(gate), .end([.text("Ich sehe nach.")])]])
        let parking = ChatParking(agentLoop: harness.agent, panelState: PanelState(), now: { harness.clock.now })
        harness.agent.send("Was steht morgen an?")
        #expect(await AgentHarness.eventually { harness.agent.items.count > 1 })
        parking.panelDidHide()
        harness.clock.advance(by: 3_600)
        parking.panelWillAppear()
        #expect(harness.agent.isRunning)
        #expect(!parking.isParked, "the chat stays visible while Orbit answers")
        gate.open()
        await harness.agent.waitUntilIdle()
    }

    @Test func aPendingConfirmationIsNeverParked() async throws {
        let log = MockToolLog()
        let call = MockScript.call("n1", "create_note", ["title": "Einkauf", "body": "Milch"])
        let harness = AgentHarness(tools: [MockCreateNoteTool(log: log)],
                                   scripts: [MockScript.toolCalls([call]), MockScript.answer("Erledigt.")])
        let parking = ChatParking(agentLoop: harness.agent, panelState: PanelState(), now: { harness.clock.now })
        harness.agent.send("Notiz Einkauf: Milch")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        parking.panelDidHide()
        harness.clock.advance(by: 3_600)
        parking.panelWillAppear()
        #expect(!parking.isParked, "the confirmation card stays in sight")

        harness.agent.resolveConfirmation(try #require(harness.agent.pendingConfirmation).id, decision: .cancelled)
        await harness.agent.waitUntilIdle()
        parking.panelDidHide()
        harness.clock.advance(by: 3_600)
        parking.panelWillAppear()
        #expect(parking.isParked, "once it was answered, the chat is parked like any other")
    }

    /// A follow-up typed into the chat's input but not sent: the chat needs the
    /// user, so it stays: the draft must not turn into a search (where Return
    /// would start a new chat without its context).
    @Test func aFollowUpBeingWrittenIsNeverParked() async {
        let harness = AgentHarness(scripts: [MockScript.answer("Es ist 21:30.")])
        let panelState = PanelState()
        let parking = ChatParking(agentLoop: harness.agent, panelState: panelState, now: { harness.clock.now })
        await harness.send("Wie spät ist es?")
        panelState.inputText = "Und in Tokio?"
        parking.panelDidHide()
        harness.clock.advance(by: 3_600)
        parking.panelWillAppear()
        #expect(!parking.isParked, "the draft stays a follow-up in the chat")
        #expect(panelState.inputText == "Und in Tokio?")

        // Only blank: nothing to lose.
        panelState.inputText = "  \n"
        parking.panelDidHide()
        harness.clock.advance(by: 3_600)
        parking.panelWillAppear()
        #expect(parking.isParked)

        // A search typed while the chat is parked keeps it parked.
        panelState.inputText = "ma"
        parking.panelDidHide()
        harness.clock.advance(by: 3_600)
        parking.panelWillAppear()
        #expect(parking.isParked)
    }

    /// After a relaunch how long the panel was hidden is unknown: the restored
    /// chat counts as after a pause.
    @Test func aChatRestoredAtLaunchStartsParked() async {
        let harness = AgentHarness(scripts: [MockScript.answer("Es ist 21:30.")])
        await harness.send("Wie spät ist es?")
        await harness.agent.waitForPendingSaves()
        harness.relaunch()

        let parking = ChatParking(agentLoop: harness.agent, panelState: PanelState(), now: { harness.clock.now })
        await parking.restoreMostRecentChat()
        #expect(harness.agent.hasConversation)
        #expect(parking.isParked)
        parking.panelWillAppear()
        #expect(parking.isParked, "the first show after the relaunch keeps it parked")
    }

    @Test func aChatStartedBeforeTheRestoreFinishedIsNotParked() async {
        let harness = AgentHarness(scripts: [MockScript.answer("Es ist 21:30."), MockScript.answer("Hallo!")])
        await harness.send("Wie spät ist es?")
        await harness.agent.waitForPendingSaves()
        harness.relaunch()

        let parking = ChatParking(agentLoop: harness.agent, panelState: PanelState(), now: { harness.clock.now })
        await harness.send("Hallo")
        await parking.restoreMostRecentChat()
        #expect(!parking.isParked)
        #expect(harness.agent.items.contains { if case .user("Hallo", _) = $0.kind { true } else { false } })
    }

    @Test func aNewChatEndsTheParking() async {
        let harness = AgentHarness(scripts: [MockScript.answer("Es ist 21:30."), MockScript.answer("Hallo!")])
        let parking = ChatParking(agentLoop: harness.agent, panelState: PanelState(), now: { harness.clock.now })
        await harness.send("Wie spät ist es?")
        parking.panelDidHide()
        harness.clock.advance(by: 600)
        parking.panelWillAppear()
        #expect(parking.isParked)

        harness.agent.newChat()
        #expect(!parking.isParked)
        await harness.send("Hallo")
        #expect(!parking.isParked, "the new chat is shown")
    }
}
