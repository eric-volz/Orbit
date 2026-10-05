import Foundation
import Testing
@testable import Orbit

@Suite("SearchSelection")
struct SearchSelectionTests {
    @Test func askRowIsHighlightedByDefault() {
        let selection = SearchSelection(resultIDs: ["a", "b"])
        #expect(selection.row == .ask)
        #expect(selection.isAskRowHighlighted)
        #expect(selection.position == 0)
        #expect(selection.highlightedResultIndex == nil)
        #expect(selection.returnAction(commandPressed: false) == .askAgent)
    }

    @Test func movesDownThroughResultsAndWrapsToAskRow() {
        var selection = SearchSelection(resultIDs: ["a", "b", "c"])
        selection.moveDown()
        #expect(selection.row == .result(id: "a"))
        #expect(selection.highlightedResultIndex == 0)
        selection.moveDown()
        selection.moveDown()
        #expect(selection.row == .result(id: "c"))
        selection.moveDown()
        #expect(selection.row == .ask)
    }

    @Test func movesUpFromAskRowWrapsToLastResult() {
        var selection = SearchSelection(resultIDs: ["a", "b", "c"])
        selection.moveUp()
        #expect(selection.row == .result(id: "c"))
        selection.moveUp()
        #expect(selection.row == .result(id: "b"))
    }

    @Test func withoutResultsTheAskRowStays() {
        var selection = SearchSelection()
        selection.moveDown()
        #expect(selection.row == .ask)
        selection.moveUp()
        #expect(selection.row == .ask)
    }

    @Test func returnOpensHighlightedResultAndCommandReturnAsks() {
        var selection = SearchSelection(resultIDs: ["a", "b"])
        selection.moveDown()
        selection.moveDown()
        #expect(selection.returnAction(commandPressed: false) == .openResult(index: 1))
        #expect(selection.returnAction(commandPressed: true) == .askAgent)
    }

    @Test func keepsHighlightedResultWhenListChanges() {
        var selection = SearchSelection(resultIDs: ["a", "b", "c"])
        selection.moveDown()
        selection.moveDown()
        #expect(selection.row == .result(id: "b"))
        // Files arrive after apps: "b" moves down but stays highlighted.
        selection.updateResults(["x", "a", "b", "c"])
        #expect(selection.row == .result(id: "b"))
        #expect(selection.highlightedResultIndex == 2)
    }

    @Test func clampsWhenHighlightedResultDisappears() {
        var selection = SearchSelection(resultIDs: ["a", "b", "c", "d"])
        for _ in 0..<4 { selection.moveDown() }
        #expect(selection.row == .result(id: "d"))
        selection.updateResults(["a", "b"])
        #expect(selection.row == .result(id: "b"))
        selection.updateResults([])
        #expect(selection.row == .ask)
    }

    @Test func clampsToSamePositionWhenResultIsReplaced() {
        var selection = SearchSelection(resultIDs: ["a", "b", "c"])
        selection.moveDown()
        selection.moveDown()
        selection.updateResults(["a", "x", "c"])
        #expect(selection.row == .result(id: "x"))
    }

    @Test func askRowStaysWhenResultsArrive() {
        var selection = SearchSelection()
        selection.updateResults(["a", "b"])
        #expect(selection.row == .ask)
    }

    @Test func resetReturnsToAskRow() {
        var selection = SearchSelection(resultIDs: ["a"])
        selection.moveDown()
        selection.reset()
        #expect(selection.row == .ask)
    }

    @Test func highlightResultClamps() {
        var selection = SearchSelection(resultIDs: ["a", "b"])
        selection.highlightResult(at: 1)
        #expect(selection.row == .result(id: "b"))
        selection.highlightResult(at: 7)
        #expect(selection.row == .result(id: "b"))
        selection.highlightResult(at: -3)
        #expect(selection.row == .ask)
    }

    @Test(arguments: [
        (1, 3, 0 as Int?),
        (3, 3, 2),
        (4, 3, nil),
        (9, 12, 8),
        (0, 5, nil),
        (10, 12, nil),
        (1, 0, nil),
    ])
    func shortcutMapping(number: Int, resultCount: Int, expected: Int?) {
        #expect(SearchSelection.resultIndex(forShortcut: number, resultCount: resultCount) == expected)
    }

    @Test func shortcutNumbersForFirstNineResults() {
        #expect(SearchSelection.shortcutNumber(forResultAt: 0) == 1)
        #expect(SearchSelection.shortcutNumber(forResultAt: 8) == 9)
        #expect(SearchSelection.shortcutNumber(forResultAt: 9) == nil)
        #expect(SearchSelection.shortcutNumber(forResultAt: -1) == nil)
    }
}

@Suite("PanelMode and search sections")
struct PanelModeTests {
    @Test func resolvesMode() {
        #expect(PanelMode.resolve(hasConversation: false, inputText: "") == .compact)
        #expect(PanelMode.resolve(hasConversation: false, inputText: "  \n") == .compact)
        #expect(PanelMode.resolve(hasConversation: false, inputText: "rechnung") == .search)
        #expect(PanelMode.resolve(hasConversation: true, inputText: "") == .chat)
        #expect(PanelMode.resolve(hasConversation: true, inputText: "weiter") == .chat)
    }

    /// After a pause the chat is parked: the panel searches again, the chat waits.
    @Test func aParkedChatLeavesThePanelToSearch() {
        #expect(PanelMode.resolve(hasConversation: true, isChatParked: true, inputText: "") == .compact)
        #expect(PanelMode.resolve(hasConversation: true, isChatParked: true, inputText: "ma") == .search)
        #expect(PanelMode.resolve(hasConversation: true, isChatParked: false, inputText: "ma") == .chat)
        #expect(PanelMode.resolve(hasConversation: false, isChatParked: true, inputText: "") == .compact)
    }

    @Test func searchRowsTellVoiceOverTheirShortcut() {
        let mail = SearchResult(id: "app:/Applications/Mail.app", kind: .app(url: URL(fileURLWithPath: "/Applications/Mail.app")),
                                title: "Mail", subtitle: "Programm")
        let file = SearchResult(id: "file:/Users/lisa/Documents/Rechnungen/a.pdf",
                                kind: .file(url: URL(fileURLWithPath: "/Users/lisa/Documents/Rechnungen/a.pdf")),
                                title: "a.pdf", subtitle: "Dokumente ▸ Rechnungen", spokenSubtitle: "Dokumente, Rechnungen")
        let contact = SearchResult(id: "contact:1", kind: .contact(identifier: "1"), title: "Lisa")
        #expect(SearchResultRow.accessibilityValue(for: mail, shortcutNumber: 1) == "Programm, Command-1")
        #expect(SearchResultRow.accessibilityValue(for: file, shortcutNumber: 3) == "Dokumente, Rechnungen, Command-3",
                "the folder without the triangles")
        #expect(SearchResultRow.accessibilityValue(for: contact, shortcutNumber: 9) == "Command-9")
        #expect(SearchResultRow.accessibilityValue(for: mail, shortcutNumber: nil) == "Programm", "beyond ⌘9")
    }

    /// ↑/↓ keep the keyboard in the input, so VoiceOver hears the highlighted row.
    @Test func announcementsNameTheHighlightedRow() {
        let results = [
            SearchResult(id: "mail", kind: .app(url: URL(fileURLWithPath: "/Applications/Mail.app")), title: "Mail", subtitle: "Programm"),
            SearchResult(id: "maps", kind: .app(url: URL(fileURLWithPath: "/Applications/Maps.app")), title: "Karten", subtitle: "Programm"),
        ]
        var selection = SearchSelection(resultIDs: results.map(\.id))
        #expect(SearchAnnouncement.text(for: selection, query: " ma ", results: results) == "Ask Orbit: “ma”")
        selection.moveDown()
        #expect(SearchAnnouncement.text(for: selection, query: "ma", results: results) == "Mail, Programm, Command-1")
        selection.moveDown()
        #expect(SearchAnnouncement.text(for: selection, query: "ma", results: results) == "Karten, Programm, Command-2")
        let untitled = [SearchResult(id: "x", kind: .contact(identifier: "x"), title: "Lisa")]
        var contact = SearchSelection(resultIDs: ["x"])
        contact.moveDown()
        #expect(SearchAnnouncement.text(for: contact, query: "li", results: untitled) == "Lisa, Command-1")

        #expect(SearchAnnouncement.resultCount(0) == "No results")
        #expect(SearchAnnouncement.resultCount(1) == "1 result")
        #expect(SearchAnnouncement.resultCount(7) == "7 results")
    }

    @Test func continueChatRowNamesTheChat() {
        #expect(ContinueChatRow.text(title: "Finde die Telekom-Rechnung") == "Continue chat: “Finde die Telekom-Rechnung”")
        #expect(ContinueChatRow.text(title: nil) == "Continue chat")
        #expect(ContinueChatRow.text(title: "  ") == "Continue chat")
    }

    @Test func sectionsNumberResultsInDisplayOrder() {
        let groups = [
            SearchResultGroup(category: .apps, results: [
                SearchResult(id: "app1", kind: .app(url: URL(fileURLWithPath: "/Applications/Safari.app")), title: "Safari"),
                SearchResult(id: "app2", kind: .app(url: URL(fileURLWithPath: "/Applications/Mail.app")), title: "Mail"),
            ]),
            SearchResultGroup(category: .files, results: []),
            SearchResultGroup(category: .contacts, results: [
                SearchResult(id: "c1", kind: .contact(identifier: "x"), title: "Lisa"),
            ]),
        ]
        let sections = SearchSection.sections(for: groups)
        #expect(sections.map(\.id) == ["apps", "contacts"])
        #expect(sections.flatMap(\.rows).map(\.index) == [0, 1, 2])
        #expect(sections[1].rows[0].result.title == "Lisa")
    }
}
