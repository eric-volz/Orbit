import Foundation
import Testing
@testable import Orbit

/// UX-1: when Orbit opens Mail's reply window, the panel stays visible without
/// the keyboard (once, for that hand-off), so the card that says the text is
/// on the clipboard stays in view.
@Suite("Keyboard hand-off")
struct KeyboardHandoffTests {
    let start = FlexibleDate.parse("2026-10-04T09:00:00+02:00")!.date

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    @Test func nothingIsHandedOffUntilOrbitOpensAWindow() {
        var handoff = KeyboardHandoff()
        #expect(!handoff.isHandingOff(at: start))
        handoff.keepPanelVisible()
        #expect(!handoff.isPanelKeptVisible, "no hand-off, nothing to keep")
        let closes = handoff.appDidActivate("com.apple.finder", isOrbit: false)
        #expect(!closes)
        #expect(handoff == KeyboardHandoff())
    }

    @Test func whileTheWindowOpensAndShortlyAfterItCounts() {
        var handoff = KeyboardHandoff()
        let id = handoff.begin(to: "com.apple.mail", now: start)
        #expect(handoff.id == id && handoff.app == "com.apple.mail" && handoff.startedAt == start)
        // Mail may need a while to start.
        #expect(handoff.isHandingOff(at: at(30)))
        handoff.end(id, opened: true, now: at(31))
        // The app comes to the front a moment after its script returned.
        #expect(handoff.isHandingOff(at: at(31 + KeyboardHandoff.grace)))
        #expect(!handoff.isHandingOff(at: at(31 + KeyboardHandoff.grace + 0.1)), "later focus changes are the user's")
    }

    @Test func aHandoffWhoseEndIsNeverReportedStopsCounting() {
        var handoff = KeyboardHandoff()
        handoff.begin(to: "com.apple.mail", now: start)
        #expect(handoff.isHandingOff(at: at(KeyboardHandoff.maximumDuration)))
        #expect(!handoff.isHandingOff(at: at(KeyboardHandoff.maximumDuration + 1)))
    }

    @Test func aWindowThatDidNotOpenEndsTheHandoff() {
        var handoff = KeyboardHandoff()
        let id = handoff.begin(to: "com.apple.mail", now: start)
        handoff.end(id, opened: false, now: at(1))
        #expect(handoff == KeyboardHandoff())
        #expect(!handoff.isHandingOff(at: at(1)))
    }

    @Test func thePanelStaysVisibleOncePerHandoff() {
        var handoff = KeyboardHandoff()
        let id = handoff.begin(to: "com.apple.mail", now: start)
        #expect(handoff.isHandingOff(at: at(0.5)))
        handoff.keepPanelVisible()
        #expect(handoff.isPanelKeptVisible)
        #expect(!handoff.isHandingOff(at: at(0.6)), "the next focus change closes the panel as always")
        // The script returns after Mail came to the front: still kept.
        let closes = handoff.end(id, opened: true, now: at(1))
        #expect(!closes)
        #expect(handoff.isPanelKeptVisible)
    }

    /// UX1-EDGE: the panel stayed visible without the keyboard, but the window
    /// did not open after all (the script failed or was stopped): the
    /// hand-off is over and the panel closes.
    @Test func aWindowThatDoesNotOpenAfterThePanelWasKeptClosesIt() {
        var handoff = KeyboardHandoff()
        let id = handoff.begin(to: "com.apple.mail", now: start)
        handoff.keepPanelVisible()
        let closes = handoff.end(id, opened: false, now: at(2))
        #expect(closes, "the panel closes")
        #expect(handoff == KeyboardHandoff())
        let closesAgain = handoff.end(id, opened: false, now: at(3))
        #expect(!closesAgain, "once")
        // Not while the window is still opening (the panel still has the keyboard) …
        let opening = handoff.begin(to: "com.apple.mail", now: at(10))
        let closesWhileOpening = handoff.end(opening, opened: false, now: at(11))
        #expect(!closesWhileOpening)
        // … nor for an earlier hand-off.
        let earlier = handoff.begin(to: "com.apple.mail", now: at(20))
        let current = handoff.begin(to: "com.apple.mail", now: at(21))
        handoff.keepPanelVisible()
        let closesForEarlier = handoff.end(earlier, opened: false, now: at(22))
        #expect(!closesForEarlier)
        #expect(handoff.isPanelKeptVisible && handoff.id == current)
    }

    /// UX1-EDGE: another app comes to the front while the window is still
    /// opening (or opened but has not taken the keyboard yet): the user went
    /// elsewhere, e.g. with ⌘Tab: the hand-off is over, and the panel closes
    /// when it loses the keyboard, as always.
    @Test func anotherAppComingToTheFrontWhileTheWindowOpensEndsTheHandoff() {
        var handoff = KeyboardHandoff()
        let id = handoff.begin(to: "com.apple.mail", now: start)
        let byMail = handoff.appDidActivate("com.apple.mail", isOrbit: false)
        #expect(!byMail, "Mail coming to the front is the hand-off")
        let byOrbit = handoff.appDidActivate("io.github.eric-volz.Orbit", isOrbit: true)
        #expect(!byOrbit)
        #expect(handoff.isHandingOff(at: at(1)))
        let byFinder = handoff.appDidActivate("com.apple.finder", isOrbit: false)
        #expect(byFinder, "a panel without the keyboard closes now")
        #expect(handoff == KeyboardHandoff())
        #expect(!handoff.isHandingOff(at: at(1)), "the lost keyboard closes the panel, also when reported after the app")
        handoff.end(id, opened: true, now: at(2))
        #expect(handoff == KeyboardHandoff(), "the script's late report changes nothing")

        let opened = handoff.begin(to: "com.apple.mail", now: at(10))
        handoff.end(opened, opened: true, now: at(11))
        let byNameless = handoff.appDidActivate(nil, isOrbit: false)
        #expect(byNameless, "an app without a bundle identifier too")
        #expect(!handoff.isHandingOff(at: at(12)))
    }

    @Test func reportsForAnEarlierHandoffChangeNothing() {
        var handoff = KeyboardHandoff()
        let earlier = handoff.begin(to: "com.apple.mail", now: start)
        let current = handoff.begin(to: "com.apple.mail", now: at(10))
        handoff.end(earlier, opened: false, now: at(11))
        #expect(handoff.id == current)
        #expect(handoff.isHandingOff(at: at(12)))
    }

    @Test func anotherAppComingToTheFrontClosesTheKeptPanel() {
        var handoff = KeyboardHandoff()
        handoff.begin(to: "com.apple.mail", now: start)
        handoff.keepPanelVisible()
        let byMail = handoff.appDidActivate("com.apple.mail", isOrbit: false)
        #expect(!byMail, "Mail's own activation may be reported after the panel lost the keyboard")
        let byOrbit = handoff.appDidActivate("io.github.eric-volz.Orbit", isOrbit: true)
        #expect(!byOrbit)
        #expect(handoff.isPanelKeptVisible)
        let byFinder = handoff.appDidActivate("com.apple.finder", isOrbit: false)
        #expect(byFinder)
        let byNameless = handoff.appDidActivate(nil, isOrbit: false)
        #expect(byNameless)
    }

    /// FC5-4: keys such as ⌘↩ do not reach the panel from the start of a hand-off (the window takes the
    /// keyboard when it appears) until the panel takes it back; a window that never took it gives it back
    /// after the grace period.
    @Test func theKeyboardIsAwayFromTheStartOfAHandoffUntilThePanelTakesItBack() {
        var handoff = KeyboardHandoff()
        #expect(!handoff.isKeyboardAway(at: start))
        let id = handoff.begin(to: "com.apple.mail", now: start)
        #expect(handoff.isKeyboardAway(at: at(1)), "while the window opens")
        handoff.end(id, opened: true, now: at(2))
        #expect(handoff.isKeyboardAway(at: at(2 + KeyboardHandoff.grace)), "it takes the keyboard a moment later")
        #expect(!handoff.isKeyboardAway(at: at(2 + KeyboardHandoff.grace + 0.1)), "a window that never took it")
        handoff.keepPanelVisible()
        #expect(handoff.isKeyboardAway(at: at(600)), "the panel stays visible without it, however long")
        handoff.panelDidBecomeKey()
        #expect(!handoff.isKeyboardAway(at: at(601)))

        handoff.begin(to: "com.apple.mail", now: at(700))
        handoff.reset()
        #expect(!handoff.isKeyboardAway(at: at(701)), "the panel closed")
    }

    @Test func aClickIntoThePanelEndsAKeptHandoffOnly() {
        var handoff = KeyboardHandoff()
        handoff.begin(to: "com.apple.mail", now: start)
        handoff.panelDidBecomeKey()
        #expect(handoff.isHandingOff(at: at(1)), "the panel may take the keyboard back while the window opens")
        handoff.keepPanelVisible()
        handoff.panelDidBecomeKey()
        #expect(handoff == KeyboardHandoff())
        handoff.begin(to: "com.apple.mail", now: start)
        handoff.reset()
        #expect(handoff == KeyboardHandoff())
    }

    /// The card shown and announced: the newest reply card created since the
    /// hand-off began, not an earlier reply, not a new message's draft.
    @Test func theReplyCardIsTheNewestSinceTheHandoffBegan() {
        func card(_ subject: String, reply: Bool, at seconds: TimeInterval) -> ChatItem {
            ChatItem(kind: .card(.mailDraft(MailDraftItem(
                to: ["lisa@example.com"], cc: [], subject: subject, body: "Passt.", isOpenInMail: true, draftID: 3,
                reply: reply ? MailReplyInfo(toAll: false, isTextOnClipboard: true) : nil))), createdAt: at(seconds))
        }
        let earlierReply = card("Re: Alt", reply: true, at: -60)
        let status = ChatItem(kind: .toolStatus(ToolStatus(toolCallID: "1", toolName: "create_mail_draft", category: .mail,
                                                           text: "Opening reply in Mail…", state: .running)), createdAt: at(-0.1))
        var handoff = KeyboardHandoff()
        #expect(handoff.replyCard(in: [earlierReply]) == nil, "no hand-off")
        handoff.begin(to: "com.apple.mail", now: start)
        #expect(handoff.replyCard(in: [earlierReply, status]) == nil)
        let draft = card("Neu", reply: false, at: 1)
        let reply = card("Re: Projekt", reply: true, at: 2)
        let answer = ChatItem(kind: .assistant(text: "Füge den Text mit ⌘V ein.", isStreaming: true), createdAt: at(3))
        #expect(handoff.replyCard(in: [earlierReply, status, draft, reply, answer])?.id == reply.id)
        #expect(handoff.replyCard(in: [earlierReply, status, draft]) == nil)
    }
}

@Suite("Panel state: keyboard hand-off")
@MainActor
struct PanelStateHandoffTests {
    @Test func aVisiblePanelTakesPartInAHandoff() async throws {
        let state = PanelState()
        state.isVisible = true
        let id = try #require(await state.beginKeyboardHandoff(to: "com.apple.mail"))
        #expect(state.keyboardHandoff.id == id)
        #expect(state.keyboardHandoff.isHandingOff(at: Date()))
        await state.endKeyboardHandoff(id, opened: true)
        guard case .opened = state.keyboardHandoff.phase else {
            Issue.record("opened: \(state.keyboardHandoff.phase)")
            return
        }
        await state.endKeyboardHandoff(nil, opened: false)
        #expect(state.keyboardHandoff.id == id, "an unknown hand-off ends nothing")
    }

    /// UX1-EDGE: a reply window the panel stayed visible for did not open
    /// after all: the panel is closed (the controller closes it only when it
    /// does not have the keyboard). Nothing closes otherwise.
    @Test func aWindowThatDoesNotOpenAfterThePanelWasKeptClosesIt() async throws {
        let state = PanelState()
        state.isVisible = true
        var closed = 0
        state.closePanelIfNotKey = { closed += 1 }
        let failedEarly = try #require(await state.beginKeyboardHandoff(to: "com.apple.mail"))
        await state.endKeyboardHandoff(failedEarly, opened: false)
        #expect(closed == 0, "the window failed before the panel lost the keyboard")
        let opened = try #require(await state.beginKeyboardHandoff(to: "com.apple.mail"))
        state.keyboardHandoff.keepPanelVisible()
        await state.endKeyboardHandoff(opened, opened: true)
        #expect(closed == 0)
        let failed = try #require(await state.beginKeyboardHandoff(to: "com.apple.mail"))
        state.keyboardHandoff.keepPanelVisible()
        await state.endKeyboardHandoff(failed, opened: false)
        #expect(closed == 1)
        #expect(state.keyboardHandoff == KeyboardHandoff())
    }

    /// FC5-4: keys such as ⌘↩ reach the panel only while it is shown and has the keyboard, not while Orbit
    /// hands the keyboard to Mail's reply window, until the panel takes it back.
    @Test func theKeysReachThePanelOnlyWhileItIsShownWithTheKeyboard() async throws {
        let state = PanelState()
        #expect(!state.hasKeyboard(), "hidden")
        state.isVisible = true
        #expect(state.hasKeyboard())
        let handoff = try #require(await state.beginKeyboardHandoff(to: "com.apple.mail"))
        #expect(!state.hasKeyboard(), "the reply window opens and takes the keyboard")
        await state.endKeyboardHandoff(handoff, opened: true)
        #expect(!state.hasKeyboard())
        let afterTheGrace = Date().addingTimeInterval(KeyboardHandoff.grace + 1)
        #expect(state.hasKeyboard(at: afterTheGrace), "a window that never took it")
        state.keyboardHandoff.keepPanelVisible()
        #expect(!state.hasKeyboard(at: Date().addingTimeInterval(600)), "the panel stays visible without it")
        state.panelDidBecomeKey()
        #expect(state.hasKeyboard(), "a click into the panel, or the shortcut")
        #expect(state.keyboardHandoff == KeyboardHandoff())
    }

    /// FC5-2, FC5-4: the panel has the keyboard again when it is shown, and when it takes the keyboard back after
    /// it stayed visible for Mail's reply window, once each time (the shortcut does both); not when it becomes
    /// key while it already had the keyboard, and not when it closes.
    @Test func thePanelHasTheKeyboardAgainWhenItIsShownOrTakesItBack() async throws {
        let state = PanelState()
        var returns = 0
        state.keyboardDidReturn = { returns += 1 }
        state.panelDidBecomeKey()
        #expect(returns == 0, "hidden")
        state.isVisible = true
        #expect(returns == 1, "shown")
        state.isVisible = true
        state.panelDidBecomeKey()
        #expect(returns == 1, "shown again while it has the keyboard, or key again after a Quick Look preview")

        let handoff = try #require(await state.beginKeyboardHandoff(to: "com.apple.mail"))
        state.panelDidBecomeKey()
        #expect(returns == 1, "the window has not taken the keyboard yet")
        await state.endKeyboardHandoff(handoff, opened: true)
        state.keyboardHandoff.keepPanelVisible()
        // The shortcut: `show()` makes the panel key and sets `isVisible` (in either order), once.
        state.panelDidBecomeKey()
        state.isVisible = true
        #expect(returns == 2)
        let next = try #require(await state.beginKeyboardHandoff(to: "com.apple.mail"))
        await state.endKeyboardHandoff(next, opened: true)
        state.keyboardHandoff.keepPanelVisible()
        state.isVisible = true
        state.panelDidBecomeKey()
        #expect(returns == 3)

        // Closing the panel during a hand-off (`PanelController.hide()`) gives the keyboard to no one.
        let closed = try #require(await state.beginKeyboardHandoff(to: "com.apple.mail"))
        await state.endKeyboardHandoff(closed, opened: true)
        state.keyboardHandoff.keepPanelVisible()
        state.keyboardHandoff.reset()
        state.isVisible = false
        state.panelDidBecomeKey()
        #expect(returns == 3)
        state.isVisible = true
        #expect(returns == 4, "shown again")
    }

    /// A panel the user closed is never brought back by a hand-off.
    @Test func aHiddenPanelHasNoHandoff() async {
        let state = PanelState()
        #expect(await state.beginKeyboardHandoff(to: "com.apple.mail") == nil)
        #expect(state.keyboardHandoff == KeyboardHandoff())
        await state.endKeyboardHandoff(nil, opened: true)
        #expect(state.keyboardHandoff == KeyboardHandoff())
    }
}
