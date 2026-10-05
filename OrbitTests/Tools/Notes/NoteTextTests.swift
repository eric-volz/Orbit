import Foundation
import Testing
@testable import Orbit

@Suite("Note text (HTML ↔ plain text)")
struct NoteTextTests {
    // MARK: HTML → text

    @Test func paragraphsAndEmptyLinesAsNotesShowsThem() {
        let html = """
            <div><h1>Umzug</h1></div>
            <div>Kartons bestellen</div>
            <div><br></div>
            <div>Halteverbot <b>beantragen</b></div>
            <div><br></div><div><br></div>
            <div>Ende</div>
            """
        #expect(NoteText.plainText(fromHTML: html) == "Umzug\nKartons bestellen\n\nHalteverbot beantragen\n\nEnde")
    }

    @Test func listsGetMarkersAndNestedListsAreIndented() {
        let html = """
            <div>Packliste</div>
            <ul>
            <li>Pass</li>
            <li>Ladekabel<ul><li>USB-C</li><li>Lightning</li></ul></li>
            </ul>
            <ol><li>Erstens</li><li>Zweitens</li></ol>
            """
        #expect(NoteText.plainText(fromHTML: html) == """
            Packliste
            - Pass
            - Ladekabel
              - USB-C
              - Lightning
            1. Erstens
            2. Zweitens
            """)
    }

    @Test func listItemsWithParagraphsKeepTheirIndent() {
        let html = "<ul><li><div>Erste Zeile</div><div>Zweite Zeile</div></li></ul>"
        #expect(NoteText.plainText(fromHTML: html) == "- Erste Zeile\n  Zweite Zeile")
    }

    @Test func tableRowsBecomeLinesWithCellsSeparated() {
        let html = """
            <div><table cellspacing="0"><tbody>
            <tr><td valign="top"><div>Name</div></td><td><div>Telefon</div></td></tr>
            <tr><td><div>Lisa</div></td><td><div>0170 <br>000</div></td></tr>
            </tbody></table></div><div>Danach</div>
            """
        #expect(NoteText.plainText(fromHTML: html) == "Name | Telefon\nLisa | 0170 000\nDanach")
    }

    @Test func linksKeepTheirAddressWhenTheTextDiffers() {
        let html = """
            <div>Siehe <a href="https://example.com/a?b=1&amp;c=2">die Seite</a> und \
            <a href="https://example.com">https://example.com</a>, \
            <a href="mailto:lisa@example.com">lisa@example.com</a>, \
            <a href="javascript:alert(1)">Klick</a></div>
            """
        #expect(NoteText.plainText(fromHTML: html)
            == "Siehe die Seite (https://example.com/a?b=1&c=2) und https://example.com, lisa@example.com, Klick")
    }

    @Test func imagesAndAttachmentsArePlaceholders() {
        let html = #"<div>Foto:<img src="cid:abc" style="max-width: 100%;"></div><div><object data="cid:x"></object></div>"#
        #expect(NoteText.plainText(fromHTML: html) == "Foto: [image]\n[attachment]")
    }

    @Test func entitiesWhitespaceCommentsAndScriptsAreHandled() {
        let html = """
            <!-- Kommentar <div>nicht</div> -->
            <div>Gr&uuml;&szlig;e &amp; &lt;Tags&gt; &#8211;   viele&nbsp;&nbsp;Leerzeichen</div>
            <script>alert("nein")</script><style>div { color: red }</style>
            <div>a < b und 3>2</div>
            """
        #expect(NoteText.plainText(fromHTML: html) == "Grüße & <Tags> \u{2013} viele Leerzeichen\na < b und 3>2")
    }

    @Test func attributesWithAngleBracketsDoNotEndTheTag() {
        #expect(NoteText.plainText(fromHTML: #"<div title="a > b">Text</div>"#) == "Text")
    }

    @Test func anUnterminatedTagEndsTheText() {
        #expect(NoteText.plainText(fromHTML: "<div>Anfang</div><div class=\"x") == "Anfang")
        #expect(NoteText.plainText(fromHTML: "") == "")
        #expect(NoteText.plainText(fromHTML: "Nur Text") == "Nur Text")
    }

    @Test func deepListNestingIsIndentedAtMostEightLevels() {
        var html = ""
        for level in 1...10 { html += "<ul><li>\(level)" }
        html += String(repeating: "</li></ul>", count: 10)
        let lines = NoteText.plainText(fromHTML: html).components(separatedBy: "\n")
        #expect(lines.count == 10)
        #expect(lines.first == "- 1")
        #expect(lines[8] == String(repeating: " ", count: 16) + "- 9")
        #expect(lines[9] == String(repeating: " ", count: 16) + "- 10", "deeper lists keep the eighth level's indent")
    }

    /// Thousands of nested lists (a note written by another app) stay small
    /// text: no megabytes of indentation, and the items are there.
    @Test func thousandsOfNestedListsGiveSmallText() {
        let html = String(repeating: "<ul>", count: 3_000) + String(repeating: "<li>x</li>", count: 3_000)
        let text = NoteText.plainText(fromHTML: html)
        #expect(text.count < 3_000 * 20)
        #expect(text.hasPrefix(String(repeating: " ", count: 16) + "- x\n"))
    }

    @Test func convertingStopsWellPastALimit() {
        let html = String(repeating: "<div>Ein Absatz mit Text.</div>", count: 5_000)
        let full = NoteText.plainText(fromHTML: html)
        #expect(full.count > 100_000)
        let limited = NoteText.plainText(fromHTML: html, maxCharacters: 1_000)
        #expect((1_000...1_030).contains(limited.count), "just past the limit, so the caller knows it was cut")
        #expect(full.hasPrefix(limited))
        #expect(NoteText.plainText(fromHTML: "<div>Kurz</div><hr><div>Text</div>", maxCharacters: 1_000) == "Kurz\n---\nText")
    }

    @Test func horizontalRulesAndHeadings() {
        #expect(NoteText.plainText(fromHTML: "<h2>Teil 1</h2><hr><p>Text</p>") == "Teil 1\n---\nText")
    }

    // MARK: Text → HTML

    @Test func newNotesStartWithTheTitleAndEscapeEverything() {
        let html = NoteText.html(title: "Einkauf <b>& Co</b>", body: "Milch\n\n  Eier \"bio\"\n\tBrot's\r\nEnde")
        #expect(html == "<div><h1>Einkauf &lt;b&gt;&amp; Co&lt;/b&gt;</h1></div>"
            + "<div>Milch</div><div><br></div>"
            + "<div>&nbsp;&nbsp;Eier &quot;bio&quot;</div>"
            + "<div>&nbsp;&nbsp;&nbsp;&nbsp;Brot&#39;s</div>"
            + "<div>Ende</div>")
        // Notes takes the first line as the name; the text reads back as written.
        #expect(NoteText.plainText(fromHTML: html) == "Einkauf <b>& Co</b>\nMilch\n\nEier \"bio\"\nBrot's\nEnde")
    }

    @Test func anEmptyBodyGivesOnlyTheTitle() {
        #expect(NoteText.html(title: "Nur Titel", body: " \n ") == "<div><h1>Nur Titel</h1></div>")
    }

    @Test func titlesAreSingleLineAndBounded() {
        #expect(NoteText.singleLine("  Zeile 1\nZeile 2\u{0007} ") == "Zeile 1 Zeile 2")
        #expect(NoteText.singleLine(String(repeating: "a", count: 500)).count == NoteText.maxTitleCharacters)
    }

    @Test func controlCharactersAreRemovedButLineBreaksAndTabsStay() {
        #expect(NoteText.cleaned("a\u{0}b\u{1B}c\nd\te\u{7F}f\r") == "abc\nd\tef\r")
    }

    // MARK: Excerpts

    @Test func excerptsSkipTheTitleCollapseAndCut() {
        let text = "Umzug\nKartons   bestellen\n\nHalteverbot beantragen und Nachbarn informieren"
        #expect(NoteText.excerpt(from: text, title: "Umzug", maxCharacters: 200)
            == "Kartons bestellen Halteverbot beantragen und Nachbarn informieren")
        let short = NoteText.excerpt(from: text, title: "Umzug", maxCharacters: 30)
        #expect(short == "Kartons bestellen Halteverbot…", "cut at a word")
        #expect(NoteText.excerpt(from: text, title: "Umzug", maxCharacters: 25) == "Kartons bestellen…")
        #expect((short?.count ?? 0) <= 30)
        #expect(NoteText.excerpt(from: "Nur Titel", title: "Nur Titel", maxCharacters: 50) == nil)
        #expect(NoteText.excerpt(from: "Anderer Anfang\nText", title: "Titel", maxCharacters: 50) == "Anderer Anfang Text")
    }
}
