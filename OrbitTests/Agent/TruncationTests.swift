import Foundation
import Testing
@testable import Orbit

@Suite("Truncation")
struct TruncationTests {
    @Test func leavesShortTextAlone() {
        let result = Truncation.truncate("Hallo Welt", maxCharacters: 10)
        #expect(result.text == "Hallo Welt")
        #expect(!result.wasTruncated)
        #expect(Truncation.truncate("", maxCharacters: 0) == ("", false))
    }

    @Test func cutsAtALineBreakNearTheLimit() {
        // Five lines of 29 characters: line breaks at offsets 29, 59, 89 and 119.
        let line = String(repeating: "a", count: 29)
        let text = Array(repeating: line, count: 5).joined(separator: "\n")
        let result = Truncation.truncate(text, maxCharacters: 95)
        #expect(result.wasTruncated)
        #expect(result.text == [line, line, line].joined(separator: "\n")
            + "\n\n[Truncated: showing the first 89 of 149 characters.]")
    }

    @Test func prefersALineBreakRightAtTheLimit() {
        let text = String(repeating: "a", count: 20) + "\n" + String(repeating: "b", count: 20)
        let result = Truncation.truncate(text, maxCharacters: 20)
        #expect(result.text.hasPrefix(String(repeating: "a", count: 20) + "\n\n[Truncated: showing the first 20 of 41"))
    }

    @Test func fallsBackToWhitespaceThenToTheHardLimit() {
        let words = String(repeating: "wort ", count: 40) // 200 characters
        let atSpace = Truncation.truncate(words, maxCharacters: 103)
        #expect(atSpace.text.hasPrefix(String(repeating: "wort ", count: 20).trimmingCharacters(in: .whitespaces) + "\n\n"))

        let solid = String(repeating: "x", count: 200)
        let hard = Truncation.truncate(solid, maxCharacters: 100)
        #expect(hard.text == String(repeating: "x", count: 100) + "\n\n[Truncated: showing the first 100 of 200 characters.]")
    }

    @Test func onlyLooksBackAboutTenPercent() {
        // The only space is far before the limit, so the cut is hard.
        let text = "ab " + String(repeating: "x", count: 197)
        let result = Truncation.truncate(text, maxCharacters: 100)
        #expect(result.text.hasPrefix("ab " + String(repeating: "x", count: 97) + "\n\n"))
    }

    @Test func neverSplitsGraphemeClusters() {
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: family, count: 30)
        let result = Truncation.truncate(text, maxCharacters: 10)
        let kept = result.text.components(separatedBy: "\n\n").first ?? ""
        #expect(kept == String(repeating: family, count: 10))
        #expect(result.text.hasSuffix("[Truncated: showing the first 10 of 30 characters.]"))
        #expect(Truncation.truncate("é" + "e\u{301}", maxCharacters: 2).wasTruncated == false)
    }

    @Test func zeroLimitKeepsOnlyTheNote() {
        #expect(Truncation.truncate("abc", maxCharacters: 0).text == "[Truncated: showing the first 0 of 3 characters.]")
    }

    @Test func limitsLists() {
        let (items, omitted) = Truncation.limit(Array(1...57), max: 20)
        #expect(items == Array(1...20))
        #expect(omitted == 37)
        #expect(Truncation.limit([1, 2], max: 20) == ([1, 2], 0))
        #expect(Truncation.limit([1, 2], max: -1) == ([], 2))
    }

    @Test func listNote() {
        #expect(Truncation.listNote(shown: 20, total: 57)
            == "[Showing 20 of 57 results. Narrow the search (time range, sender, folder) to see others.]")
        #expect(Truncation.listNote(shown: 5, total: 9, hint: "Use a shorter time range.")
            == "[Showing 5 of 9 results. Use a shorter time range.]")
    }

    @Test func capsToolResults() {
        #expect(Truncation.capToolResult("kurz") == "kurz")
        let long = String(repeating: "y", count: 50_000)
        let capped = Truncation.capToolResult(long)
        #expect(capped.hasPrefix(String(repeating: "y", count: 45_000) + "\n\n[Truncated"))
        #expect(capped.hasSuffix("showing the first 45000 of 50000 characters.]"))
    }

    @Test func cutKeepsWhatTruncateKeepsWithoutTheNote() {
        let words = String(repeating: "wort ", count: 40)
        let cut = Truncation.cut(words, maxCharacters: 103)
        #expect(cut.wasTruncated)
        #expect(cut.text == String(repeating: "wort ", count: 20).trimmingCharacters(in: .whitespaces))
        #expect(Truncation.truncate(words, maxCharacters: 103).text.hasPrefix(cut.text + "\n\n[Truncated"))
        #expect(Truncation.cut("kurz", maxCharacters: 10) == ("kurz", false))
    }

    // MARK: Characters made of many scalars (ZALGO-1)

    /// Real text of many scripts, the most combining marks in a row it has
    /// (Hebrew points with cantillation, Tibetan and Myanmar stacks), and the
    /// longest emoji sequences.
    static let normalTexts = [
        "Grüße aus Köln, Straße, Maß und Fuß: ÄÖÜ äöü ß",
        "Familie 👨‍👩‍👧‍👦, Kuss 👩🏻‍❤️‍💋‍👨🏼, Daumen 👍🏽, Flaggen 🇩🇪🇫🇷 🏴󠁧󠁢󠁳󠁣󠁴󠁿, Taste 1️⃣, Regenbogen 🏳️‍🌈",
        "東京都の天気は晴れです。今日は会議があります。한국어 텍스트입니다.",
        "مَرْحَبًا بِكُمْ فِي الْعَالَمِ، كَيْفَ حَالُكَ؟ اللّٰهُ",
        "नमस्ते दुनिया, क्षत्रिय स्त्री कृष्ण ज्ञान श्रीमान् हिन्दी",
        "בְּרֵאשִׁ֖ית בָּרָ֣א אֱלֹהִ֑ים",
        "བསྒྲུབས་ ཀྵྨྱཱུཾ་ ကြွော် ကျွန်ုပ်",
        "Tie\u{0302}\u{0301}ng Vie\u{0323}\u{0302}t (NFD), e\u{0301}\u{0328}\u{0304}\u{0306}",
        "ภาษาไทย น้ำ ผู้ใหญ่",
    ]

    @Test(arguments: normalTexts)
    func normalTextIsUnchanged(text: String) {
        #expect(Truncation.collapsingCombiningMarks(text) == text)
        #expect(Truncation.cut(text, maxCharacters: text.count) == (text, false))
        #expect(Truncation.truncate(text, maxCharacters: 1_000) == (text, false))
        #expect(Truncation.prefix(text, maxCharacters: text.count) == text)
        #expect(Truncation.capToolResult(text) == text)
        // (inline drops invisible format characters such as zero-width joiners first.)
        let neutral = TurnContext.neutralizeMarkup(text)
        #expect(TurnContext.inline(text, maxCharacters: neutral.count) == neutral)
        // Cut short, it is cut exactly where it was cut before: by characters.
        let half = text.count / 2
        #expect(Truncation.prefix(text, maxCharacters: half) == String(text.prefix(half)))
        #expect(TurnContext.inline(text, maxCharacters: half) == String(neutral.prefix(half)) + "…")
    }

    /// A letter with thousands of combining marks is one character: Orbit keeps
    /// eight of them, and the text around it.
    @Test func aLetterWithThousandsOfMarksKeepsEightOfThem() {
        let marks = String(repeating: "\u{0301}", count: 200_000)
        let text = "Hallo a\(marks) Rechnung"
        let kept = "Hallo a" + String(repeating: "\u{0301}", count: 8) + " Rechnung"
        #expect(Truncation.collapsingCombiningMarks(text) == kept)
        #expect(Truncation.cut(text, maxCharacters: 4_000) == (kept, false), "the text after it stays")
        #expect(Truncation.capToolResult(text) == kept)
        #expect(Truncation.prefix(text, maxCharacters: 7) == "Hallo a" + String(repeating: "\u{0301}", count: 8))
        #expect(TurnContext.inline("Rechnung a\(marks)", maxCharacters: 200)
            == "Rechnung a" + String(repeating: "\u{0301}", count: 8))
        // Marks of several kinds in a row, also enclosing ones and vowel signs.
        let mixed = "x" + String(repeating: "\u{0300}\u{20DD}\u{093E}", count: 1_000) + "y"
        #expect(Truncation.collapsingCombiningMarks(mixed).unicodeScalars.count == 10)
    }

    /// Other ways to make one huge character (a chain of emoji joined by
    /// zero-width joiners, skin-tone modifiers, Hangul jamo) cannot be
    /// shortened inside: the limit in scalars leaves them out, also the
    /// agent loop's last cap, when one is larger than everything it allows.
    @Test func charactersMadeOfTooManyScalarsAreLeftOut() {
        let size = Truncation.maxToolResultCharacters * Truncation.maxScalarsPerCharacter
        let chain = "😀" + String(repeating: "\u{200D}😀", count: size / 2)
        let modifiers = "👍" + String(repeating: "🏻", count: size)
        let jamo = String(repeating: "\u{1100}", count: size + 1)
        for giant in [chain, modifiers, jamo] {
            #expect(giant.count == 1, "one character")
            let text = "Vorher " + giant + " nachher"
            let (kept, wasTruncated) = Truncation.cut(text, maxCharacters: 100)
            #expect(wasTruncated)
            #expect(kept == "Vorher")
            #expect(Truncation.capToolResult(text) == "Vorher\n\n[Truncated: showing the first 6 of 16 characters.]")
            // (inline drops the joiners first, so the chain falls apart into single emoji.)
            #expect(TurnContext.inline("Hallo " + giant, maxCharacters: 200).unicodeScalars.count <= 200 * Truncation.maxScalarsPerCharacter + 1)
            #expect(Truncation.prefix(giant, maxCharacters: 10).isEmpty)
        }
        #expect(TurnContext.inline("Hallo " + modifiers, maxCharacters: 200) == "Hallo …")
    }

    /// Whatever a tool returns, the model gets at most `maxScalarsPerCharacter`
    /// scalars per character of the global cap.
    @Test func toolResultsAreBoundedInScalars() {
        let zalgo = String(repeating: "a" + String(repeating: "\u{0301}", count: 30), count: 50_000)
        let capped = Truncation.capToolResult(zalgo)
        #expect(capped.unicodeScalars.count <= Truncation.maxToolResultCharacters * Truncation.maxScalarsPerCharacter + 100)
        #expect(String(String.UnicodeScalarView(capped.unicodeScalars.prefix(10))) == "a" + String(repeating: "\u{0301}", count: 8) + "a")
        #expect(capped.hasSuffix("characters.]"))
    }

    @Test func constants() {
        #expect(Truncation.maxToolResultCharacters == 45_000)
        #expect(Truncation.fileContentCharacters == 20_000)
        #expect(Truncation.maxFileContentCharacters == 40_000)
        #expect(Truncation.mailBodyCharacters == 4_000)
        #expect(Truncation.maxListItems == 20)
        // The largest file excerpt plus header and notes fits under the global cap.
        #expect(Truncation.maxFileContentCharacters + 2_000 < Truncation.maxToolResultCharacters)
    }
}
