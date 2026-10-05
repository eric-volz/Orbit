import Foundation
import Testing
@testable import Orbit

/// RACE-1 / E2E4-3: ⌘Return and the confirmation card that waits for the
/// user. ⌘Return runs the card only while the user can see it; out of view,
/// the first ⌘Return brings it into view and gives it the keyboard; it is
/// never swallowed without an effect. The keys themselves run in
/// `ConfirmationCardWindowTests` (gated window tests).
@Suite("⌘Return and the waiting confirmation card")
@MainActor
struct ConfirmationKeyboardTests {
    let card = UUID()

    @Test func commandReturnSendsTextOtherwiseRunsOrRevealsTheCard() {
        typealias K = ConfirmationKeyboard
        #expect(K.commandReturn(inputText: "Hallo", pendingRequestID: card, mayRunPending: true) == .send,
                "with text, ⌘Return means send, never run the card instead")
        #expect(K.commandReturn(inputText: "Hallo", pendingRequestID: nil, mayRunPending: false) == .send)
        #expect(K.commandReturn(inputText: "", pendingRequestID: card, mayRunPending: true) == .approve(card))
        #expect(K.commandReturn(inputText: " \n", pendingRequestID: card, mayRunPending: false) == .reveal(card),
                "a card out of view comes into view first")
        #expect(K.commandReturn(inputText: "", pendingRequestID: nil, mayRunPending: false) == ConfirmationKeyboard.Action.none,
                "nothing to do: the key is left to others")
    }

    @Test func aCardIsInViewWhenTheUserSeesAllOfIt() {
        typealias K = ConfirmationKeyboard
        func frame(_ y: CGFloat, _ height: CGFloat) -> CGRect { CGRect(x: 0, y: y, width: 640, height: height) }
        #expect(K.isInView(frame: frame(100, 200), viewportHeight: 400))
        #expect(K.isInView(frame: frame(0, 400), viewportHeight: 400), "exactly fitting")
        #expect(K.isInView(frame: frame(201.5, 200), viewportHeight: 400), "within the tolerance")
        #expect(!K.isInView(frame: frame(300, 200), viewportHeight: 400), "its buttons are below the view")
        #expect(!K.isInView(frame: frame(-60, 200), viewportHeight: 400), "its title is above the view")
        #expect(!K.isInView(frame: frame(2_000, 200), viewportHeight: 400), "scrolled far away")
        #expect(K.isInView(frame: frame(-100, 700), viewportHeight: 400), "taller than the view and filling it")
        #expect(!K.isInView(frame: frame(50, 700), viewportHeight: 400))
        #expect(!K.isInView(frame: frame(0, 200), viewportHeight: 0), "a chat without height shows nothing")
        #expect(K.isInView(frame: frame(5_000, 200), viewportHeight: nil), "outside a chat")
    }

    @Test func onlyACardInViewMayBeRun() {
        let keyboard = ConfirmationKeyboard()
        #expect(!keyboard.mayRun(card))
        keyboard.setInView(true, requestID: card)
        #expect(keyboard.mayRun(card) && !keyboard.mayRun(UUID()))
        keyboard.setInView(false, requestID: card)
        #expect(!keyboard.mayRun(card), "scrolled away")
        #expect(ConfirmationKeyboard.commandReturn(inputText: "", pendingRequestID: card, mayRunPending: keyboard.mayRun(card))
            == .reveal(card))
    }

    @Test func aRevealedCardRunsWithTheNextCommandReturn() {
        let keyboard = ConfirmationKeyboard()
        keyboard.reveal(card)
        #expect(keyboard.focusRequest?.requestID == card, "the card takes the keyboard")
        #expect(keyboard.mayRun(card), "also when the card cannot tell that the chat scrolled it into view")
        #expect(ConfirmationKeyboard.commandReturn(inputText: "", pendingRequestID: card, mayRunPending: keyboard.mayRun(card))
            == .approve(card))
        // It came into view and left it again: ⌘Return brings it back first.
        keyboard.setInView(true, requestID: card)
        keyboard.setInView(false, requestID: card)
        #expect(!keyboard.mayRun(card))
    }

    @Test func requestsReachTheirCardOnce() throws {
        let keyboard = ConfirmationKeyboard()
        keyboard.approve(card)
        let approval = try #require(keyboard.approveRequest)
        #expect(approval.requestID == card)
        keyboard.approve(card)
        let second = try #require(keyboard.approveRequest)
        #expect(second != approval, "a second ⌘Return is a new request")
        keyboard.didHandle(approval)
        #expect(keyboard.approveRequest == second, "an older request does not clear a newer one")
        keyboard.didHandle(second)
        #expect(keyboard.approveRequest == nil)
        keyboard.reveal(card)
        keyboard.didHandle(try #require(keyboard.focusRequest))
        #expect(keyboard.focusRequest == nil)
    }

    @Test func theInputGetsTheKeyboardBackOnceTheCardIsDecided() {
        let keyboard = ConfirmationKeyboard()
        keyboard.reveal(card)
        keyboard.cardTookKeyboard(card)
        keyboard.setInView(true, requestID: card)
        keyboard.setInView(false, requestID: card)
        #expect(keyboard.mayRun(card), "⌘Return in the card's own field runs it")
        #expect(!keyboard.cardDone(UUID()))
        #expect(keyboard.cardDone(card), "the input takes the keyboard back")
        #expect(!keyboard.mayRun(card) && keyboard.keyboardHolder == nil && keyboard.focusRequest == nil)
        #expect(!keyboard.cardDone(card))
    }

    /// V5-1: ⌘Return brought the card into view and gave it the keyboard; the user clicked back into the input
    /// and scrolled the card away. ⌘Return must bring it back first: never run it unseen, never do nothing.
    @Test func aCardWhoseFieldsLostTheKeyboardIsRevealedAgainOutOfView() {
        let keyboard = ConfirmationKeyboard()
        keyboard.reveal(card)
        keyboard.setInView(true, requestID: card)
        keyboard.cardTookKeyboard(card)
        keyboard.cardLostKeyboard(card)
        #expect(keyboard.keyboardHolder == nil)
        #expect(keyboard.mayRun(card), "still in view")
        keyboard.setInView(false, requestID: card)
        #expect(!keyboard.mayRun(card), "its run button no longer takes ⌘Return")
        #expect(ConfirmationKeyboard.commandReturn(inputText: "", pendingRequestID: card,
                                                   mayRunPending: keyboard.mayRunFromInput(card)) == .reveal(card))
        #expect(!keyboard.cardDone(card), "the input has the keyboard already")
    }

    /// ⌘Return in the input: the input has the keyboard, so a card only counts while it is in view (or was just
    /// brought there), also when the card could not report that its fields lost the keyboard (its row was gone).
    @Test func commandReturnInTheInputRunsOnlyACardInView() {
        let keyboard = ConfirmationKeyboard()
        keyboard.cardTookKeyboard(card)
        #expect(keyboard.mayRun(card), "⌘Return in the card's own field runs it")
        #expect(!keyboard.mayRunFromInput(card))
        #expect(ConfirmationKeyboard.commandReturn(inputText: "", pendingRequestID: card,
                                                   mayRunPending: keyboard.mayRunFromInput(card)) == .reveal(card))
        keyboard.setInView(true, requestID: card)
        #expect(keyboard.mayRunFromInput(card))
        keyboard.setInView(false, requestID: card)
        keyboard.reveal(card)
        #expect(keyboard.mayRunFromInput(card), "just brought into view")
        keyboard.cardLostKeyboard(UUID())
        #expect(keyboard.keyboardHolder == card, "another card losing the keyboard changes nothing here")
    }

    /// Where the keyboard goes when ⌘Return brings a card into view: its first field that takes it.
    @Test func theKeyboardGoesToAFieldThatTakesIt() {
        #expect(ConfirmationCard.takesKeyboard(ConfirmationField(id: "title", label: "Titel", value: "x", kind: .text)))
        #expect(ConfirmationCard.takesKeyboard(ConfirmationField(id: "input", label: "Input", value: "", kind: .multilineText)))
        #expect(ConfirmationCard.takesKeyboard(ConfirmationField(id: "start", label: "Start", value: "2026-10-06T10:00", kind: .dateTime)))
        #expect(!ConfirmationCard.takesKeyboard(ConfirmationField(id: "name", label: "Kurzbefehl", value: "x", kind: .readOnly)))
        #expect(!ConfirmationCard.takesKeyboard(ConfirmationField(id: "due", label: "Due", value: "", kind: .dateTime,
                                                                  isOptionalDate: true)),
                "no date yet: „Datum hinzufügen“ is a button")
    }

    @Test func theHintSaysHowToRunOrCancel() {
        #expect(InputHint.confirmationWaiting.text == "The action above is waiting for your confirmation: ⌘↩ runs it, ⌘. cancels it.")
    }
}
