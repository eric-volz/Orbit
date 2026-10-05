import AppKit
import SwiftUI
import Testing
@testable import Orbit

/// Regression tests for the UI findings of the Phase 1 review (round 2).
@Suite("UI: review fixes")
@MainActor
struct UIReviewFixesTests {
    // MARK: UI-3 / CROSSCUT-2: links

    @Test func onlyWebAndMailLinksStayLinks() {
        let text = MarkdownInline.attributedString(from:
            "[Rechnung](file:///Users/x/Downloads/setup.command), [Kurzbefehl](shortcuts://run-shortcut?name=X), "
            + "[Seite](https://example.com) und [Mail](mailto:anna@example.com)")
        let links = text.runs.compactMap(\.link).map { $0.scheme ?? "" }
        #expect(links == ["https", "mailto"])
        #expect(String(text.characters).contains("Rechnung"), "the text of a removed link stays")
    }

    // MARK: UI-7: tildes

    @Test func singleTildesStayLiteral() {
        for sample in ["Die Datei liegt in ~/Library/Mobile Documents/com~apple~CloudDocs/Rechnungen",
                       "Dauer 5~10 Minuten und 20~30 Sekunden"] {
            let text = MarkdownInline.attributedString(from: sample)
            #expect(String(text.characters) == sample)
            #expect(!text.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
        }
    }

    @Test func doubleTildesStillStrikeThrough() {
        let text = MarkdownInline.attributedString(from: "alt ~~weg~~ neu")
        #expect(String(text.characters) == "alt weg neu")
        #expect(text.runs.contains { $0.inlinePresentationIntent?.contains(.strikethrough) == true })
    }

    @Test func tildesInCodeSpansAndEscapesAreUntouched() {
        #expect(MarkdownInline.escapingSingleTildes("`a~b` und c~d") == "`a~b` und c\\~d")
        #expect(MarkdownInline.escapingSingleTildes("schon \\~ maskiert") == "schon \\~ maskiert")
        #expect(MarkdownInline.escapingSingleTildes("ohne Tilde") == "ohne Tilde")
    }

    // MARK: UI-9: streaming renders only the tail again

    @Test func streamingSplitsAtTheLastParagraphOutsideFences() {
        #expect(MarkdownStreaming.stableSplit("Nur ein Absatz") == ("", "Nur ein Absatz"))
        #expect(MarkdownStreaming.stableSplit("Eins\n\nZwei\n\nDr") == ("Eins\n\nZwei", "Dr"))
        #expect(MarkdownStreaming.stableSplit("Eins\n\n") == ("Eins", ""))
        // Not inside an open fence …
        let open = "Code:\n\n```swift\nlet a = 1\n\nlet b = 2"
        #expect(MarkdownStreaming.stableSplit(open) == ("Code:", "```swift\nlet a = 1\n\nlet b = 2"))
        // … but after a closed one.
        let closed = "```\nx\n\ny\n```\n\nWeiter"
        #expect(MarkdownStreaming.stableSplit(closed) == ("```\nx\n\ny\n```", "Weiter"))
    }

    // MARK: UI-4: the retry action

    @Test func theActionGoesToTheLastRowBeforeDisclosures() {
        let items = [
            ChatItem(kind: .user(text: "Hallo", attachments: [])),
            ChatItem(kind: .notice(Notice(style: .error, message: "Fehler", action: .retry))),
            ChatItem(kind: .disclosure(items: [ContentDisclosure(kind: .fileNames, count: 2)], providerName: "Claude")),
        ]
        #expect(ChatLayout.lastActionableIndex(in: items) == 1)
        #expect(ChatLayout.lastActionableIndex(in: []) == nil)
    }

    // MARK: UI-6: keyboard scrolling

    @Test func pagesScrollByMostOfTheViewport() {
        let visible = CGRect(x: 0, y: 1000, width: 700, height: 400)
        #expect(ChatScroller.origin(for: .pageUp, visible: visible, documentHeight: 3000, isFlipped: true).y == 640)
        #expect(ChatScroller.origin(for: .pageDown, visible: visible, documentHeight: 3000, isFlipped: true).y == 1360)
        #expect(ChatScroller.origin(for: .top, visible: visible, documentHeight: 3000, isFlipped: true).y == 0)
        #expect(ChatScroller.origin(for: .bottom, visible: visible, documentHeight: 3000, isFlipped: true).y == 2600)
        // Clamped at both ends; a document that is not flipped scrolls the other way.
        #expect(ChatScroller.origin(for: .pageUp, visible: CGRect(x: 0, y: 100, width: 700, height: 400),
                                    documentHeight: 3000, isFlipped: true).y == 0)
        #expect(ChatScroller.origin(for: .pageUp, visible: visible, documentHeight: 3000, isFlipped: false).y == 1360)
        #expect(ChatScroller.origin(for: .top, visible: visible, documentHeight: 3000, isFlipped: false).y == 2600)
    }

    @Test func theScrollerMovesARealScrollView() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: 300, height: 2000))
        scrollView.documentView = document
        let scroller = ChatScroller()
        scroller.scrollView = scrollView
        #expect(scroller.scroll(.pageDown))
        #expect(scroller.scroll(.top))
        #expect(!scroller.scroll(.top), "already at the top")
        #expect(scroller.scroll(.bottom))
    }

    // MARK: UI-12: API keys

    @Test func unsavedKeysSurviveASwitchOfProviders() async throws {
        let secrets = InMemorySecretStore()
        let editor = APIKeyEditor(secrets: secrets)
        await editor.load(kind: .anthropic)
        editor.draft = "sk-ant-typed"
        await editor.load(kind: .openAICompatible)
        #expect(editor.draft.isEmpty)
        await editor.load(kind: .anthropic)
        #expect(editor.draft == "sk-ant-typed")
        await editor.save()
        #expect(editor.status == .saved)
        #expect(try secrets.secret(for: SecretAccount.anthropicAPIKey) == "sk-ant-typed")
        await editor.load(kind: .openAICompatible)
        #expect(editor.status == .notSaved)
    }

    // MARK: CROSSCUT-3: plain http to DNS names

    @Test func blockedCleartextHostsGetAClearMessage() {
        #expect(BaseURLCheck.check("http://nas.fritz.box:11434/v1") == .cleartextBlocked)
        #expect(LLMError.network(.insecureConnectionBlocked).userMessage.contains("https://"))
        #expect(!LLMError.network(.insecureConnectionBlocked).isRetryable)
        #expect(AgentLoop.noticeActions(for: .network(.insecureConnectionBlocked)) == [.openSettings, .retry])
    }

    // MARK: UI-11: disclosure wording

    @Test func selectionsReadNaturally() {
        let text = DisclosurePhrase.text(for: [ContentDisclosure(kind: .fileNames, count: 3),
                                               ContentDisclosure(kind: .selection, count: 1)], providerName: "Claude")
        #expect(text == "3 file names and 1 selected text sent to Claude")
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
