import AppKit
import Testing
@testable import Orbit

extension UIWindowTests {
    /// UX-1: Orbit hands the keyboard to Mail's reply window. Orbit's real panel
    /// (offscreen, with the keyboard) and an offscreen window that stands in for
    /// Mail's reply window. Another app's window cannot take the keyboard in a
    /// test, so the controller is told that it is none of Orbit's. Nothing
    /// appears on the screen and Mail is never involved.
    ///
    ///     ORBIT_UI_TESTS=1 Scripts/swiftpm.sh test --filter PanelHandoff
    @Suite("PanelHandoff", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_UI_TESTS"] == "1"))
    @MainActor
    struct PanelHandoffTests {
        @MainActor
        struct Harness {
            let environment: AppEnvironment
            let controller: PanelController
            /// Stands in for Mail's reply window.
            let replyWindow: OffscreenKeyPanel
            let announcer: RecordingAnnouncer

            var panel: OrbitPanel { controller.panel }
            var state: PanelState { environment.panelState }

            func close() {
                controller.hide()
                replyWindow.orderOut(nil)
            }
        }

        static let replyStatus = "Reply opened in Mail: paste the text from the clipboard with ⌘V"

        private static func isOffscreen(_ window: NSWindow) -> Bool {
            NSScreen.screens.allSatisfy { !$0.frame.intersects(window.frame) }
        }

        /// The panel is up with the keyboard, like after the hotkey (but offscreen).
        private func makeHarness() async throws -> Harness {
            _ = NSApplication.shared
            let announcer = RecordingAnnouncer()
            let environment = SnapshotEnvironment.make(services: .fake(announcer: announcer))
            let controller = PanelController(environment: environment, openSettings: { _ in })
            let replyWindow = OffscreenKeyPanel(size: CGSize(width: 600, height: 400))
            controller.isOrbitWindow = { $0 !== replyWindow }
            let panel = controller.panel
            panel.setFrame(CGRect(x: -20_000, y: -21_000, width: Theme.panelWidth, height: 420), display: false)
            try #require(Self.isOffscreen(panel), "nothing may appear on the screen")
            panel.orderFrontRegardless()
            try #require(Self.isOffscreen(panel), "the borderless panel stays where it is")
            panel.makeKey()
            environment.panelState.isVisible = true
            await SnapshotRenderer.settle(0.3)
            try #require(panel.isKeyWindow)
            return Harness(environment: environment, controller: controller, replyWindow: replyWindow, announcer: announcer)
        }

        /// Mail's reply window takes the keyboard.
        private func replyWindowTakesTheKeyboard(_ harness: Harness) async {
            harness.replyWindow.makeKeyAndOrderFront(nil)
            await SnapshotRenderer.settle(0.3)
        }

        @Test func thePanelStaysVisibleWithoutTheKeyboardUntilTheNextClickOutside() async throws {
            let harness = try await makeHarness()
            defer { harness.close() }
            let handoff = try #require(await harness.state.beginKeyboardHandoff(to: "com.apple.mail"))
            await harness.state.endKeyboardHandoff(handoff, opened: true)
            await replyWindowTakesTheKeyboard(harness)
            #expect(harness.panel.isVisible)
            #expect(harness.state.isVisible)
            #expect(!harness.panel.isKeyWindow, "the keyboard stays with Mail's reply window: ⌘V pastes there")
            #expect(harness.replyWindow.isKeyWindow)
            #expect(harness.state.keyboardHandoff.isPanelKeptVisible)

            harness.controller.mouseDownOutsideOrbit(at: CGPoint(x: -40_000, y: -40_000))
            #expect(!harness.panel.isVisible)
            #expect(!harness.state.isVisible)
            #expect(harness.state.keyboardHandoff == KeyboardHandoff())
        }

        /// The old behavior: another app's window taking the keyboard closes the panel.
        @Test func withoutAHandoffAnotherAppsWindowClosesThePanel() async throws {
            let harness = try await makeHarness()
            defer { harness.close() }
            await replyWindowTakesTheKeyboard(harness)
            #expect(!harness.panel.isVisible)
            #expect(!harness.state.isVisible)

            // Also after a hand-off that is long over.
            let late = try await makeHarness()
            defer { late.close() }
            let id = late.state.keyboardHandoff.begin(to: "com.apple.mail", now: Date().addingTimeInterval(-60))
            late.state.keyboardHandoff.end(id, opened: true, now: Date().addingTimeInterval(-KeyboardHandoff.grace - 1))
            await replyWindowTakesTheKeyboard(late)
            #expect(!late.panel.isVisible)
        }

        /// Mail may bring its window up while the script still runs.
        @Test func theWindowMayTakeTheKeyboardBeforeTheScriptReturns() async throws {
            let harness = try await makeHarness()
            defer { harness.close() }
            let handoff = try #require(await harness.state.beginKeyboardHandoff(to: "com.apple.mail"))
            await replyWindowTakesTheKeyboard(harness)
            await harness.state.endKeyboardHandoff(handoff, opened: true)
            #expect(harness.panel.isVisible)
            #expect(!harness.panel.isKeyWindow)
            #expect(harness.state.keyboardHandoff.isPanelKeptVisible)
        }

        @Test func anotherAppComingToTheFrontClosesTheKeptPanel() async throws {
            let harness = try await makeHarness()
            defer { harness.close() }
            let handoff = try #require(await harness.state.beginKeyboardHandoff(to: "com.apple.mail"))
            await harness.state.endKeyboardHandoff(handoff, opened: true)
            await replyWindowTakesTheKeyboard(harness)
            harness.controller.applicationDidActivate(bundleIdentifier: "com.apple.mail", processIdentifier: 4_242)
            #expect(harness.panel.isVisible, "Mail coming to the front (reported after it took the keyboard) keeps it")
            harness.controller.applicationDidActivate(bundleIdentifier: "com.apple.finder", processIdentifier: 4_243)
            #expect(!harness.panel.isVisible)
        }

        /// UX1-EDGE: another app comes to the front while the reply window is
        /// still opening (the user went elsewhere, e.g. with ⌘Tab; macOS may
        /// report the app before the lost keyboard): the hand-off is over, and
        /// the panel closes when that app's window takes the keyboard, as always.
        @Test func anotherAppWhileTheReplyWindowOpensEndsTheHandoff() async throws {
            let harness = try await makeHarness()
            defer { harness.close() }
            let handoff = try #require(await harness.state.beginKeyboardHandoff(to: "com.apple.mail"))
            harness.controller.applicationDidActivate(bundleIdentifier: "com.apple.finder", processIdentifier: 4_243)
            #expect(harness.panel.isVisible && harness.panel.isKeyWindow, "it still has the keyboard")
            // The offscreen window stands in for the other app's window here.
            await replyWindowTakesTheKeyboard(harness)
            #expect(!harness.panel.isVisible)
            #expect(!harness.state.isVisible)
            await harness.state.endKeyboardHandoff(handoff, opened: true)
            #expect(!harness.panel.isVisible, "the script's late report brings nothing back")
            #expect(harness.state.keyboardHandoff == KeyboardHandoff())
        }

        /// UX1-EDGE: the panel stayed visible without the keyboard, but the
        /// reply window did not open after all (the script failed or was
        /// stopped): the panel closes.
        @Test func aReplyWindowThatDoesNotOpenAfterAllClosesTheKeptPanel() async throws {
            let harness = try await makeHarness()
            defer { harness.close() }
            let handoff = try #require(await harness.state.beginKeyboardHandoff(to: "com.apple.mail"))
            await replyWindowTakesTheKeyboard(harness)
            #expect(harness.panel.isVisible && harness.state.keyboardHandoff.isPanelKeptVisible)
            await harness.state.endKeyboardHandoff(handoff, opened: false)
            #expect(!harness.panel.isVisible)
            #expect(!harness.state.isVisible)
            #expect(harness.state.keyboardHandoff == KeyboardHandoff())
        }

        /// A click into the panel makes it key as usual and ends the hand-off:
        /// the next window that takes the keyboard closes it as always.
        @Test func aClickIntoThePanelEndsTheHandoff() async throws {
            let harness = try await makeHarness()
            defer { harness.close() }
            let handoff = try #require(await harness.state.beginKeyboardHandoff(to: "com.apple.mail"))
            await harness.state.endKeyboardHandoff(handoff, opened: true)
            await replyWindowTakesTheKeyboard(harness)
            #expect(harness.panel.isVisible)
            harness.panel.makeKey()
            await SnapshotRenderer.settle(0.2)
            #expect(harness.panel.isKeyWindow)
            #expect(harness.state.keyboardHandoff == KeyboardHandoff())
            await replyWindowTakesTheKeyboard(harness)
            #expect(!harness.panel.isVisible)
        }

        /// FC5-4: while Mail's reply window has the keyboard, ⌘↩ and ⌘. would
        /// reach it, so a card that waits is read without them. A click into the
        /// panel gives the keyboard back, once, and the card is read with them
        /// (`PanelState.keyboardDidReturn`; what is read: AppEnvironmentTests).
        @Test func aClickIntoThePanelGivesItTheKeyboardBack() async throws {
            let harness = try await makeHarness()
            defer { harness.close() }
            var returns = 0
            harness.state.keyboardDidReturn = { returns += 1 }
            let dependencies = harness.environment.agentLoop.dependencies
            #expect(dependencies.panelHasKeyboard())
            let handoff = try #require(await harness.state.beginKeyboardHandoff(to: "com.apple.mail"))
            await harness.state.endKeyboardHandoff(handoff, opened: true)
            await replyWindowTakesTheKeyboard(harness)
            #expect(harness.state.keyboardHandoff.isPanelKeptVisible)
            #expect(!dependencies.panelHasKeyboard(), "the keys would reach the reply window")
            #expect(returns == 0)

            harness.panel.makeKey()
            await SnapshotRenderer.settle(0.2)
            #expect(harness.panel.isKeyWindow)
            #expect(dependencies.panelHasKeyboard())
            #expect(returns == 1)
        }

        /// The user closed the panel (Escape, hotkey, a click outside) before
        /// the reply window appeared: it is not brought back.
        @Test func aPanelClosedDuringTheRunStaysClosed() async throws {
            let harness = try await makeHarness()
            defer { harness.close() }
            let handoff = try #require(await harness.state.beginKeyboardHandoff(to: "com.apple.mail"))
            harness.controller.hide()
            await replyWindowTakesTheKeyboard(harness)
            await harness.state.endKeyboardHandoff(handoff, opened: true)
            #expect(!harness.panel.isVisible)
            #expect(!harness.state.isVisible)
            #expect(harness.state.keyboardHandoff == KeyboardHandoff())
        }

        /// The reply's card comes into the chat while the panel stays up:
        /// VoiceOver (now in Mail's reply window) hears where the text is.
        /// (A live run needs a model; the card arrives by a restore here.)
        @Test func voiceOverHearsWhereTheTextIs() async throws {
            let harness = try await makeHarness()
            defer { harness.close() }
            let handoff = try #require(await harness.state.beginKeyboardHandoff(to: "com.apple.mail"))
            await replyWindowTakesTheKeyboard(harness)
            await harness.state.endKeyboardHandoff(handoff, opened: true)
            let reply = MailDraftItem(to: ["Lisa Beispiel <lisa.beispiel@example.com>"], cc: [], subject: "Re: Projekt Orbit",
                                      body: "Hallo Lisa,\n\nDonnerstag passt.\n\nErika", isOpenInMail: true, draftID: 8,
                                      reply: MailReplyInfo(toAll: false, isTextOnClipboard: true))
            let conversation = Conversation(title: "Antwort", items: [
                ChatItem(kind: .user(text: "Sag ihr, Donnerstag passt", attachments: [])),
                ChatItem(kind: .card(.mailDraft(reply))),
            ])
            try await harness.environment.conversationStore.save(conversation)
            await harness.environment.agentLoop.restoreMostRecentConversation()
            await SnapshotRenderer.settle(0.4)
            #expect(harness.announcer.announcements == [Self.replyStatus])
            #expect(harness.announcer.priorities == [.medium], "after VoiceOver named Mail's window")
            #expect(harness.panel.isVisible && !harness.panel.isKeyWindow)
        }
    }
}
