import AppKit
import SwiftUI
import Testing
@testable import Orbit

extension UIWindowTests {
    /// RACE-1, UX-4 and UX-5 in an offscreen panel: ⌘Return runs a waiting
    /// confirmation card only while it is in view of the chat; a reminder's
    /// due date can be removed and given a time on the card; a decided card's
    /// dates read for VoiceOver as the card shows them.
    ///
    ///     ORBIT_UI_TESTS=1 Scripts/swiftpm.sh test --filter ConfirmationCardWindow
    @MainActor
    @Suite("ConfirmationCardWindow", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_UI_TESTS"] == "1"))
    struct ConfirmationCardWindowTests {
        private final class Decisions {
            var values: [ConfirmationDecision] = []
        }

        private static func request(fields: [ConfirmationField]) -> ConfirmationRequest {
            ConfirmationRequest(toolCallID: "t1", toolName: "create_reminder", riskLevel: .write, title: "Create reminder",
                                message: "Orbit legt diese Erinnerung in Erinnerungen an.", fields: fields, confirmLabel: "Create")
        }

        private func show(_ view: some View, size: CGSize) throws -> OffscreenKeyPanel {
            _ = NSApplication.shared
            let panel = OffscreenKeyPanel(size: size)
            panel.contentView = NSHostingView(rootView: view)
            panel.makeKeyAndOrderFront(nil)
            try #require(panel.isOffscreen, "nothing may appear on the screen")
            return panel
        }

        /// ⌘Return as a key window handles it: the key equivalents first. True when one took it.
        private func commandReturn(_ panel: NSPanel) async -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                               context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                                               isARepeat: false, keyCode: 36) else { return false }
            let handled = panel.performKeyEquivalent(with: event)
            await SnapshotRenderer.settle(0.15)
            return handled
        }

        private func elements(in panel: NSPanel) -> [NSObject] {
            var found: [NSObject] = []
            var queue: [NSObject] = panel.contentView.map { [$0] } ?? []
            while !queue.isEmpty, found.count < 5_000 {
                let element = queue.removeFirst()
                found.append(element)
                queue.append(contentsOf: element.value(forKey: "accessibilityChildren") as? [NSObject] ?? [])
            }
            return found
        }

        private func texts(_ key: String, in panel: NSPanel) -> [String] {
            elements(in: panel).compactMap { $0.value(forKey: key) as? String }
        }

        /// RACE-1: the chat follows its end, where the card waits; scrolled away, ⌘Return leaves the card alone
        /// (RootView then brings it into view); back in view, ⌘Return runs it.
        @Test func commandReturnRunsOnlyACardInView() async throws {
            let request = Self.request(fields: [ConfirmationField(id: "title", label: "Titel", value: "Müll", kind: .text)])
            var items = (1...12).map { index in
                ChatItem(kind: .assistant(text: "Antwort \(index): " + String(repeating: "Text ", count: 40), isStreaming: false))
            }
            let cardItem = ChatItem(kind: .confirmation(ConfirmationState(request: request, status: .pending)))
            items.append(cardItem)
            let decisions = Decisions()
            let keyboard = ConfirmationKeyboard()
            let scroller = ChatScroller()
            let fileCards = FileCardCoordinator(quickLook: nil, workspace: nil)
            let chat = ChatView(items: items, isRunning: true, conversationID: UUID(), maxHeight: 360, approveShortcutEnabled: true,
                                scroller: scroller,
                                actions: ChatActions(resolveConfirmation: { _, decision in decisions.values.append(decision) }))
                .environment(keyboard)
                .environment(fileCards)
                .frame(width: Theme.panelWidth)
            let panel = try show(chat, size: CGSize(width: Theme.panelWidth, height: 400))
            defer { panel.orderOut(nil) }
            await SnapshotRenderer.settle(0.6)
            #expect(keyboard.viewportHeight == 360, "the chat reports its visible height")
            #expect(keyboard.cardsInView.contains(request.id), "the chat follows its end: the card is in view")

            scroller.scroll(.top)
            await SnapshotRenderer.settle(0.4)
            #expect(!keyboard.mayRun(request.id), "scrolled away")
            #expect(await !commandReturn(panel), "the key goes on to the input")
            #expect(decisions.values.isEmpty, "never run a card the user cannot see")

            // What RootView does for ⌘Return in the input: the chat scrolls to the card, which takes the keyboard.
            keyboard.reveal(request.id)
            fileCards.scroll(to: .card(cardItem.id))
            await SnapshotRenderer.settle(0.5)
            #expect(keyboard.cardsInView.contains(request.id), "back in view")
            #expect(keyboard.keyboardHolder == request.id, "its title field has the keyboard")
            #expect(await commandReturn(panel))
            #expect(decisions.values == [.approved(edits: [:])])
        }

        /// V5-1: after ⌘Return brought the card into view, the user clicks back into the input and scrolls the card
        /// away; the card's fields no longer hold the keyboard, so ⌘Return never runs it unseen.
        @Test func aRevealedCardLosesTheKeyboardToTheInput() async throws {
            let request = Self.request(fields: [ConfirmationField(id: "title", label: "Titel", value: "Müll", kind: .text)])
            var items = (1...12).map { index in
                ChatItem(kind: .assistant(text: "Antwort \(index): " + String(repeating: "Text ", count: 40), isStreaming: false))
            }
            let cardItem = ChatItem(kind: .confirmation(ConfirmationState(request: request, status: .pending)))
            items.append(cardItem)
            let decisions = Decisions()
            let keyboard = ConfirmationKeyboard()
            let scroller = ChatScroller()
            let fileCards = FileCardCoordinator(quickLook: nil, workspace: nil)
            let content = VStack(spacing: 0) {
                // Stands in for the panel's input.
                TextField(text: .constant(""), prompt: nil) { Text(verbatim: "Input") }
                ChatView(items: items, isRunning: true, conversationID: UUID(), maxHeight: 360, approveShortcutEnabled: true,
                         scroller: scroller,
                         actions: ChatActions(resolveConfirmation: { _, decision in decisions.values.append(decision) }))
                    .environment(keyboard)
                    .environment(fileCards)
            }
            .frame(width: Theme.panelWidth)
            let panel = try show(content, size: CGSize(width: Theme.panelWidth, height: 440))
            defer { panel.orderOut(nil) }
            await SnapshotRenderer.settle(0.6)

            keyboard.reveal(request.id)
            fileCards.scroll(to: .card(cardItem.id))
            await SnapshotRenderer.settle(0.5)
            #expect(keyboard.keyboardHolder == request.id, "its title field has the keyboard")

            let input = try #require(editableTextFields(in: panel).first { $0.stringValue.isEmpty }, "the input")
            #expect(panel.makeFirstResponder(input))
            await SnapshotRenderer.settle(0.3)
            #expect(keyboard.keyboardHolder == nil, "the card's fields lost the keyboard")
            #expect(keyboard.mayRun(request.id), "still in view")

            scroller.scroll(.top)
            await SnapshotRenderer.settle(0.4)
            #expect(!keyboard.mayRun(request.id) && !keyboard.mayRunFromInput(request.id), "scrolled away")
            #expect(await !commandReturn(panel), "the card's ⌘Return is gone; the input brings the card back first")
            #expect(decisions.values.isEmpty, "never run a card the user cannot see")
        }

        private func editableTextFields(in panel: NSPanel) -> [NSTextField] {
            var found: [NSTextField] = []
            var queue: [NSView] = panel.contentView.map { [$0] } ?? []
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let field = view as? NSTextField, field.isEditable { found.append(field) }
                queue.append(contentsOf: view.subviews)
            }
            return found
        }

        /// UX-4: "No Date" removes a reminder's due date before it is created; "Add Date" brings one back
        /// (today), "With time" gives it 9:00.
        @Test func aDueDateCanBeRemovedAddedAndTimedOnTheCard() async throws {
            let accessibility = UIWindowTests.FileCardKeyboardTests.AccessibilityTree()
            defer { accessibility.end() }
            let due = ConfirmationField(id: "due", label: "Due", value: "2026-10-05", kind: .dateTime, isOptionalDate: true)
            let decisions = Decisions()
            let card = ConfirmationCard(state: ConfirmationState(request: Self.request(fields: [due]), status: .pending)) {
                decisions.values.append($0)
            }
            let panel = try show(card.frame(width: 600), size: CGSize(width: 620, height: 260))
            defer { panel.orderOut(nil) }
            await SnapshotRenderer.settle(0.4)
            func press(_ title: String) async throws {
                let button = try #require(elements(in: panel).first { $0.value(forKey: "accessibilityLabel") as? String == title },
                                          "\(title)")
                _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
                await SnapshotRenderer.settle(0.2)
            }
            #expect(texts("accessibilityLabel", in: panel).contains("With time"))
            try await press("No Date")
            #expect(texts("accessibilityLabel", in: panel).contains("Add Date"))
            try await press("Add Date")
            try await press("With time")
            try await press("No Date")
            #expect(await commandReturn(panel))
            #expect(decisions.values == [.approved(edits: ["due": ""])], "created without a due date")
        }

        /// UX-5: on a decided card VoiceOver reads the dates as the card shows them, never ISO 8601.
        @Test func decidedDatesReadAsShown() async throws {
            let accessibility = UIWindowTests.FileCardKeyboardTests.AccessibilityTree()
            defer { accessibility.end() }
            let start = ConfirmationField(id: "start", label: "Start", value: "2026-10-06T10:00:00+02:00", kind: .dateTime)
            let due = ConfirmationField(id: "due", label: "Due", value: "", kind: .dateTime, isOptionalDate: true)
            let card = ConfirmationCard(state: ConfirmationState(request: Self.request(fields: [start, due]), status: .approved)) { _ in }
            let panel = try show(card.frame(width: 500), size: CGSize(width: 520, height: 300))
            defer { panel.orderOut(nil) }
            await SnapshotRenderer.settle(0.4)
            let values = texts("accessibilityValue", in: panel)
            #expect(values.contains(ConfirmationDateValue.displayText(for: start, value: start.value)))
            #expect(values.contains("No Date"))
            #expect(!values.contains { $0.contains("2026-10-06T") }, "never the ISO 8601 value: \(values)")
        }
    }
}
