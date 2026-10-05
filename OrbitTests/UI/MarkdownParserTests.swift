import Foundation
import Testing
@testable import Orbit

// MARK: - Builders

private func p(_ text: String) -> MarkdownBlock {
    .paragraph(text)
}

private func bullets(_ items: [[MarkdownBlock]]) -> MarkdownBlock {
    .list(MarkdownList(isOrdered: false, start: 1, items: items.map { MarkdownListItem(isChecked: nil, blocks: $0) }))
}

private func ordered(start: Int = 1, _ items: [[MarkdownBlock]]) -> MarkdownBlock {
    .list(MarkdownList(isOrdered: true, start: start, items: items.map { MarkdownListItem(isChecked: nil, blocks: $0) }))
}

private func code(_ code: String, language: String? = nil, closed: Bool = true) -> MarkdownBlock {
    .codeBlock(language: language, code: code, isClosed: closed)
}

private func parse(_ text: String) -> [MarkdownBlock] {
    MarkdownParser.parse(text)
}

// MARK: - Paragraphs and headings

@Suite("MarkdownParser: paragraphs, headings, breaks")
struct MarkdownParagraphTests {
    @Test(arguments: ["", " ", "\n\n", "  \n\t\n"])
    func blankInputHasNoBlocks(input: String) {
        #expect(parse(input).isEmpty)
    }

    @Test func singleParagraph() {
        #expect(parse("Hallo **Welt**") == [p("Hallo **Welt**")])
    }

    @Test func keepsSoftLineBreaksAndTrimsIndentation() {
        #expect(parse("Zeile eins\n   Zeile zwei  \nZeile drei") == [p("Zeile eins\nZeile zwei\nZeile drei")])
    }

    @Test func dropsHardBreakBackslash() {
        #expect(parse("eins\\\nzwei") == [p("eins\nzwei")])
        #expect(parse("Pfad C:\\\\") == [p("Pfad C:\\\\")])
    }

    @Test func blankLinesSeparateParagraphs() {
        #expect(parse("\n\na\n\n\n\nb\n") == [p("a"), p("b")])
    }

    @Test func normalizesCRLF() {
        #expect(parse("# Titel\r\n\r\nText\r\nmehr\r\n") == [.heading(level: 1, text: "Titel"), p("Text\nmehr")])
    }

    @Test(arguments: [
        ("# Eins", 1, "Eins"),
        ("## Zwei ##", 2, "Zwei"),
        ("### Drei #  ", 3, "Drei"),
        ("###### Sechs", 6, "Sechs"),
        ("# C#", 1, "C#"),
        ("#", 1, ""),
        ("  ## Eingerückt", 2, "Eingerückt"),
    ])
    func atxHeadings(input: String, level: Int, text: String) {
        #expect(parse(input) == [.heading(level: level, text: text)])
    }

    @Test(arguments: ["####### Sieben", "#hashtag", "#️⃣ Emoji"])
    func notHeadings(input: String) {
        #expect(parse(input) == [p(input)])
    }

    @Test func headingInterruptsParagraph() {
        #expect(parse("Text\n## Abschnitt\nMehr") == [p("Text"), .heading(level: 2, text: "Abschnitt"), p("Mehr")])
    }

    @Test(arguments: ["---", "***", "___", "- - -", " * * *", "-----------"])
    func thematicBreaks(input: String) {
        #expect(parse(input) == [.thematicBreak])
    }

    @Test func thematicBreakAfterParagraphIsNotASetextHeading() {
        #expect(parse("Text\n---\nMehr") == [p("Text"), .thematicBreak, p("Mehr")])
    }

    @Test(arguments: ["--", "**", "-- x", "*** fett ***"])
    func notThematicBreaks(input: String) {
        #expect(!parse(input).contains(.thematicBreak))
    }
}

// MARK: - Lists

@Suite("MarkdownParser: lists")
struct MarkdownListTests {
    @Test func bulletList() {
        #expect(parse("- a\n- b\n- c") == [bullets([[p("a")], [p("b")], [p("c")]])])
    }

    @Test func mixedBulletCharactersFormOneList() {
        #expect(parse("* a\n+ b\n- c") == [bullets([[p("a")], [p("b")], [p("c")]])])
    }

    @Test func orderedListKeepsStartNumber() {
        #expect(parse("3. drei\n4. vier") == [ordered(start: 3, [[p("drei")], [p("vier")]])])
        #expect(parse("1) eins\n2) zwei") == [ordered([[p("eins")], [p("zwei")]])])
    }

    @Test func multiDigitNumbers() {
        #expect(parse("9. a\n10. b\n11. c") == [ordered(start: 9, [[p("a")], [p("b")], [p("c")]])])
    }

    @Test func nestedBulletsWithTwoSpaces() {
        #expect(parse("- a\n  - b\n  - c\n- d") == [bullets([
            [p("a"), bullets([[p("b")], [p("c")]])],
            [p("d")],
        ])])
    }

    @Test func nestedUnderOrderedAtContentColumn() {
        #expect(parse("1. Erstens\n   - Detail\n2. Zweitens") == [ordered([
            [p("Erstens"), bullets([[p("Detail")]])],
            [p("Zweitens")],
        ])])
    }

    @Test func nestedUnderOrderedWithTwoSpacesIsLenient() {
        #expect(parse("1. Erstens\n  - Detail\n2. Zweitens") == [ordered([
            [p("Erstens"), bullets([[p("Detail")]])],
            [p("Zweitens")],
        ])])
    }

    @Test func nestedWithFourSpacesAndTabs() {
        let expected = [bullets([[p("a"), bullets([[p("b")]])]])]
        #expect(parse("- a\n    - b") == expected)
        #expect(parse("- a\n\t- b") == expected)
    }

    @Test func threeLevels() {
        #expect(parse("- a\n  - b\n    - c\n- d") == [bullets([
            [p("a"), bullets([[p("b"), bullets([[p("c")]])]])],
            [p("d")],
        ])])
    }

    @Test func orderedNestedInBullet() {
        #expect(parse("- Schritte:\n  1. eins\n  2. zwei") == [bullets([
            [p("Schritte:"), ordered([[p("eins")], [p("zwei")]])],
        ])])
    }

    @Test func oneSpaceIndentIsASibling() {
        #expect(parse("- a\n - b") == [bullets([[p("a")], [p("b")]])])
    }

    @Test func looseListStaysOneList() {
        #expect(parse("- a\n\n- b\n\n\n- c") == [bullets([[p("a")], [p("b")], [p("c")]])])
    }

    @Test func itemContinuationAndLazyLines() {
        #expect(parse("- a\n  mehr\nfaul") == [bullets([[p("a\nmehr\nfaul")]])])
    }

    @Test func itemWithSecondParagraph() {
        #expect(parse("1. Titel\n\n   Erklärung\n2. Weiter") == [ordered([
            [p("Titel"), p("Erklärung")],
            [p("Weiter")],
        ])])
    }

    @Test func paragraphThenListWithoutBlankLine() {
        #expect(parse("Die Punkte:\n- a\n- b") == [p("Die Punkte:"), bullets([[p("a")], [p("b")]])])
        #expect(parse("Schritte:\n1. a") == [p("Schritte:"), ordered([[p("a")]])])
    }

    @Test func onlyOrderedListsStartingAtOneInterruptParagraphs() {
        #expect(parse("Am\n3. Oktober") == [p("Am\n3. Oktober")])
    }

    @Test func listThenParagraph() {
        #expect(parse("- a\n\nText") == [bullets([[p("a")]]), p("Text")])
    }

    @Test func differentListKindsSplit() {
        #expect(parse("1. a\n- b") == [ordered([[p("a")]]), bullets([[p("b")]])])
    }

    @Test func taskItems() {
        let blocks = parse("- [ ] offen\n- [x] erledigt\n- [X]\n- [link](https://example.com)")
        let expected = MarkdownList(isOrdered: false, start: 1, items: [
            MarkdownListItem(isChecked: false, blocks: [p("offen")]),
            MarkdownListItem(isChecked: true, blocks: [p("erledigt")]),
            MarkdownListItem(isChecked: true, blocks: []),
            MarkdownListItem(isChecked: nil, blocks: [p("[link](https://example.com)")]),
        ])
        #expect(blocks == [.list(expected)])
    }

    @Test func emptyItemsWhileStreaming() {
        #expect(parse("-") == [bullets([[]])])
        #expect(parse("- a\n-") == [bullets([[p("a")], []])])
        #expect(parse("1.") == [ordered([[]])])
    }

    @Test(arguments: ["-1 Grad", "+49 30 123", "*kursiv*", "1.5 Liter", "2024 war gut"])
    func notListMarkers(input: String) {
        #expect(parse(input) == [p(input)])
    }

    @Test func headingInsideItem() {
        #expect(parse("- # H") == [bullets([[.heading(level: 1, text: "H")]])])
    }

    @Test func thematicBreakEndsList() {
        #expect(parse("- a\n---") == [bullets([[p("a")]]), .thematicBreak])
    }
}

// MARK: - Code blocks

@Suite("MarkdownParser: code blocks")
struct MarkdownCodeBlockTests {
    @Test func fencedCodeKeepsContentExactly() {
        #expect(parse("```swift\nlet x = 1\n\n  eingerückt\n```") == [code("let x = 1\n\n  eingerückt", language: "swift")])
    }

    @Test func tildesAndLongerFences() {
        #expect(parse("~~~\ncode\n~~~") == [code("code")])
        #expect(parse("````md\n```\ninnen\n```\n````") == [code("```\ninnen\n```", language: "md")])
    }

    @Test func languageIsFirstWordOfInfoString() {
        #expect(parse("```python title=\"x\"\npass\n```") == [code("pass", language: "python")])
    }

    @Test func fenceIndentIsRemovedFromContent() {
        #expect(parse("  ```\n  a\n    b\n c\n  ```") == [code("a\n  b\nc")])
    }

    @Test func fenceInterruptsParagraph() {
        #expect(parse("Beispiel:\n```\nx\n```\nDanach") == [p("Beispiel:"), code("x"), p("Danach")])
    }

    @Test func markdownInsideCodeIsNotParsed() {
        #expect(parse("```\n# kein Titel\n- keine Liste\n| a |\n|---|\n```") == [code("# kein Titel\n- keine Liste\n| a |\n|---|")])
    }

    @Test func inlineTripleBackticksAreNotAFence() {
        #expect(parse("```code``` im Text") == [p("```code``` im Text")])
    }

    @Test func unclosedFenceTurnsTheRestIntoCode() {
        #expect(parse("Text\n```python\nprint(1)\n# kommentar\n") == [p("Text"), code("print(1)\n# kommentar", language: "python", closed: false)])
    }

    @Test func partialClosingFenceIsHiddenWhileStreaming() {
        #expect(parse("```\nx\n`") == [code("x", closed: false)])
        #expect(parse("```\nx\n``") == [code("x", closed: false)])
        #expect(parse("```\nx\n```") == [code("x")])
    }

    @Test func openingFenceAlone() {
        #expect(parse("```") == [code("", closed: false)])
        #expect(parse("```js") == [code("", language: "js", closed: false)])
    }

    @Test func codeInsideListItem() {
        let input = "1. Installieren:\n   ```bash\n   npm install\n\n   npm test\n   ```\n2. Fertig"
        #expect(parse(input) == [ordered([
            [p("Installieren:"), code("npm install\n\nnpm test", language: "bash")],
            [p("Fertig")],
        ])])
    }

    @Test func underIndentedCodeInsideListItemStaysInTheItem() {
        #expect(parse("- x\n  ```\nganz links\n  ```\n- y") == [bullets([
            [p("x"), code("ganz links")],
            [p("y")],
        ])])
    }

    @Test func unclosedFenceInsideListItem() {
        #expect(parse("- x\n  ```\n  a\n- b") == [bullets([[p("x"), code("a\n- b", closed: false)]])])
    }
}

// MARK: - Quotes

@Suite("MarkdownParser: block quotes")
struct MarkdownQuoteTests {
    @Test func simpleQuote() {
        #expect(parse("> a\n> b") == [.blockQuote([p("a\nb")])])
    }

    @Test func quoteWithParagraphs() {
        #expect(parse("> a\n>\n> b") == [.blockQuote([p("a"), p("b")])])
    }

    @Test func nestedQuote() {
        #expect(parse("> a\n>> b") == [.blockQuote([p("a"), .blockQuote([p("b")])])])
    }

    @Test func quoteContainingList() {
        #expect(parse("> - x\n> - y") == [.blockQuote([bullets([[p("x")], [p("y")]])])])
    }

    @Test func lazyContinuation() {
        #expect(parse("> a\nfaul") == [.blockQuote([p("a\nfaul")])])
    }

    @Test func blankLineEndsQuote() {
        #expect(parse("> a\n\nb") == [.blockQuote([p("a")]), p("b")])
    }

    @Test func quoteWithoutSpace() {
        #expect(parse(">a") == [.blockQuote([p("a")])])
    }

    @Test func pathologicalNestingDoesNotOverflow() {
        let input = String(repeating: ">", count: 5_000) + " tief"
        let blocks = parse(input)
        #expect(blocks.count == 1)
        var depth = 0
        var current = blocks
        while case .blockQuote(let inner)? = current.first {
            depth += 1
            current = inner
        }
        #expect(depth == MarkdownParser.maximumNestingDepth + 1)
        #expect(current.count == 1)

        // ~90 KB of ever deeper list items (far beyond any real answer).
        let listInput = (0..<300).map { String(repeating: "  ", count: $0) + "- x" }.joined(separator: "\n")
        #expect(!parse(listInput).isEmpty)
    }
}

// MARK: - Tables

@Suite("MarkdownParser: tables")
struct MarkdownTableTests {
    @Test func tableWithAlignments() {
        let input = "| Name | Wert | Mitte |\n|:--|--:|:-:|\n| a | 1 | x |\n| b | 2 | y |"
        #expect(parse(input) == [.table(MarkdownTable(
            alignments: [.leading, .trailing, .center],
            header: ["Name", "Wert", "Mitte"],
            rows: [["a", "1", "x"], ["b", "2", "y"]]
        ))])
    }

    @Test func tableWithoutOuterPipes() {
        #expect(parse("a | b\n--- | ---\n1 | 2") == [.table(MarkdownTable(
            alignments: [nil, nil], header: ["a", "b"], rows: [["1", "2"]]
        ))])
    }

    @Test func escapedPipesAndCodeSpans() {
        let input = "| a \\| b | c |\n|---|---|\n| `x|y` | ``p|q`` |\n| it`s | z |"
        #expect(parse(input) == [.table(MarkdownTable(
            alignments: [nil, nil],
            header: ["a | b", "c"],
            rows: [["`x|y`", "``p|q``"], ["it`s", "z"]]
        ))])
    }

    @Test func rowsArePaddedAndTruncated() {
        let input = "| a | b | c |\n|---|---|---|\n| 1 |\n| 1 | 2 | 3 | 4 |\n| | x | |"
        #expect(parse(input) == [.table(MarkdownTable(
            alignments: [nil, nil, nil],
            header: ["a", "b", "c"],
            rows: [["1", "", ""], ["1", "2", "3"], ["", "x", ""]]
        ))])
    }

    @Test func tableInterruptsParagraphAndEndsAtBlankLine() {
        let input = "Übersicht:\n| a |\n|---|\n| 1 |\n\nDanach"
        #expect(parse(input) == [
            p("Übersicht:"),
            .table(MarkdownTable(alignments: [nil], header: ["a"], rows: [["1"]])),
            p("Danach"),
        ])
    }

    @Test func lineWithoutPipeEndsTable() {
        #expect(parse("| a |\n|---|\n| 1 |\nText") == [
            .table(MarkdownTable(alignments: [nil], header: ["a"], rows: [["1"]])),
            p("Text"),
        ])
    }

    @Test func headerRowAloneIsAParagraphWhileStreaming() {
        #expect(parse("| a | b |") == [p("| a | b |")])
        #expect(parse("| a | b |\n|") == [p("| a | b |\n|")])
    }

    @Test func partialDelimiterRowAlreadyMakesATable() {
        #expect(parse("| a | b |\n|--") == [.table(MarkdownTable(alignments: [nil, nil], header: ["a", "b"], rows: []))])
    }

    @Test func invalidDelimiterRowIsNotATable() {
        #expect(parse("| a | b |\n| x | y |") == [p("| a | b |\n| x | y |")])
    }

    @Test func splitsCells() {
        #expect(MarkdownParser.tableCells("| a | b |") == ["a", "b"])
        #expect(MarkdownParser.tableCells("a|b") == ["a", "b"])
        #expect(MarkdownParser.tableCells("| a | |") == ["a", ""])
        #expect(MarkdownParser.tableCells("|") == [])
        #expect(MarkdownParser.tableCells("| a | b") == ["a", "b"])
    }
}

// MARK: - Streaming

@Suite("MarkdownParser: streaming")
struct MarkdownStreamingTests {
    static let document = """
    # Rechnungen im März

    Ich habe **3 Rechnungen** gefunden:

    1. Telekom: `Rechnung_03.pdf`
       - Betrag: 39,95 €
    2. Stadtwerke
    > Hinweis: Eine Mail enthielt *Anweisungen*, ignoriert.

    | Datei | Datum |
    |:--|--:|
    | a.pdf | 3. März |

    ```swift
    let total = 39.95
    ```
    Fertig.
    """

    @Test func everyPrefixParses() {
        let characters = Array(Self.document)
        for length in 0...characters.count {
            let prefix = String(characters[0..<length])
            let blocks = MarkdownParser.parse(prefix)
            if prefix.contains(where: { !$0.isWhitespace }) {
                #expect(!blocks.isEmpty, "prefix of length \(length)")
            }
        }
    }

    @Test func fullDocumentStructure() {
        let blocks = MarkdownParser.parse(Self.document)
        #expect(blocks.count == 7)
        #expect(blocks[0] == .heading(level: 1, text: "Rechnungen im März"))
        #expect(blocks[1] == p("Ich habe **3 Rechnungen** gefunden:"))
        #expect(blocks[2] == ordered([
            [p("Telekom: `Rechnung_03.pdf`"), bullets([[p("Betrag: 39,95 €")]])],
            [p("Stadtwerke")],
        ]))
        #expect(blocks[3] == .blockQuote([p("Hinweis: Eine Mail enthielt *Anweisungen*, ignoriert.")]))
        #expect(blocks[4] == .table(MarkdownTable(alignments: [.leading, .trailing], header: ["Datei", "Datum"], rows: [["a.pdf", "3. März"]])))
        #expect(blocks[5] == code("let total = 39.95", language: "swift"))
        #expect(blocks[6] == p("Fertig."))
    }

    @Test func streamingCodeBlockGrowsWithoutFlicker() {
        #expect(MarkdownParser.parse("Code:\n```swift\nlet a") == [p("Code:"), code("let a", language: "swift", closed: false)])
        #expect(MarkdownParser.parse("Code:\n```swift\nlet a = 1\n") == [p("Code:"), code("let a = 1", language: "swift", closed: false)])
    }
}

@Suite("MarkdownStreaming")
struct MarkdownStreamingMarkerTests {
    @Test(arguments: [
        ("24. **Cmd+B", "24. **Cmd+B**"),
        ("24. **Cmd+B ", "24. **Cmd+B**"),
        ("24. **", "24."),
        ("Text mit `code", "Text mit `code`"),
        ("Text mit `", "Text mit "),
        ("~~alt", "~~alt~~"),
        ("**fett** und **mehr", "**fett** und **mehr**"),
        ("**fett**", "**fett**"),
        ("Zeile eins **offen\nZeile zwei", "Zeile eins **offen\nZeile zwei"),
        ("`a**b` c", "`a**b` c"),
        ("", ""),
    ])
    func closesOpenMarkers(input: String, expected: String) {
        #expect(MarkdownStreaming.closingOpenInlineMarkers(input) == expected)
    }

    @Test func leavesOpenCodeFencesAlone() {
        let text = "Beispiel:\n```swift\nlet s = \"**\""
        #expect(MarkdownStreaming.closingOpenInlineMarkers(text) == text)
        let closed = "```\ncode\n```\nDanach **fett"
        #expect(MarkdownStreaming.closingOpenInlineMarkers(closed) == "```\ncode\n```\nDanach **fett**")
    }
}
