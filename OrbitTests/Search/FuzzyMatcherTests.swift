import Foundation
import Testing
@testable import Orbit

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {
    typealias Tier = FuzzyMatcher.Tier

    @Test(arguments: [
        // Exact: case, diacritics, width and separators do not matter.
        ("safari", "Safari", Tier.exact),
        ("SAFARI", "Safari", .exact),
        ("face time", "FaceTime", .exact),
        ("strasse", "Straße", .exact),
        ("ＡＢＣ", "abc", .exact),
        ("ubersicht", "Übersicht", .exact),
        // Prefix of the whole name.
        ("saf", "Safari", .prefix),
        ("sys", "Systemeinstellungen", .prefix),
        ("systemein", "Systemeinstellungen", .prefix),
        ("uber", "Café Übersicht", .wordPrefix),
        ("visualstu", "Visual Studio Code", .prefix),
        ("xc", "Xcode", .prefix),
        // Word prefixes: later words, initials, both, typed words in any order.
        ("code", "Visual Studio Code", .wordPrefix),
        ("vsc", "Visual Studio Code", .wordPrefix),
        ("vscode", "Visual Studio Code", .wordPrefix),
        ("visual co", "Visual Studio Code", .wordPrefix),
        ("code visual", "Visual Studio Code", .wordPrefix),
        ("time", "FaceTime", .wordPrefix),
        ("phone", "iPhone-Mirroring", .wordPrefix),
        ("365", "Office365", .wordPrefix),
        ("telekom 2026", "Rechnung-Telekom-2026-08.pdf", .wordPrefix),
        ("2026-08", "Rechnung-Telekom-2026-08.pdf", .wordPrefix),
        ("einstellungen", "System-Einstellungen", .wordPrefix),
        // Substring (from 2 characters) and subsequence (from 3).
        ("code", "Xcode", .substring),
        ("od", "Xcode", .substring),
        ("ari", "Safari", .substring),
        ("xcd", "Xcode", .subsequence),
        ("sfr", "Safari", .subsequence),
    ])
    func tiers(query: String, name: String, tier: Tier) {
        #expect(FuzzyMatcher.match(query, in: name)?.tier == tier, "\(query) → \(name)")
    }

    @Test(arguments: [
        ("safarix", "Safari"),
        ("", "Safari"),
        ("  ", "Safari"),
        ("zzz", "Safari"),
        ("xd", "Xcode"),        // two characters: no subsequence
        ("o", "Xcode"),         // one character: no substring
        ("elekom", "Telekom"),  // a substring, but …
        ("rechnung", "Telekomrechnung-alt"),
        ("sa", ""),
        ("abc", "🙂🙂🙂"),
    ])
    func noMatch(query: String, name: String) {
        let match = FuzzyMatcher.match(query, in: name)
        if query == "elekom" || query == "rechnung" {
            // … inside a word only counts as a substring, never as a word prefix.
            #expect(match?.tier == .substring)
        } else {
            #expect(match == nil, "\(query) → \(name)")
        }
    }

    @Test func tiersRankInOrder() {
        #expect(Tier.allCases.sorted() == [.subsequence, .substring, .wordPrefix, .prefix, .exact])
        let names = ["Xcalibur Code Driver", "Xcode", "Visual Studio Code", "Codeshot", "Code"]
        // Among word prefixes the earlier word wins: "Code" is the 2nd word of one, the 3rd of the other.
        #expect(ranked("code", names) == ["Code", "Codeshot", "Xcalibur Code Driver", "Visual Studio Code", "Xcode"])
    }

    @Test func closerMatchesWinWithinATier() {
        // Prefix: the more of the name typed, the better.
        #expect(ranked("saf", ["Safari Technology Preview", "Safari"]) == ["Safari", "Safari Technology Preview"])
        // Word prefix: earlier words and fewer skipped words.
        #expect(ranked("notes", ["My Old Notes", "Sticky Notes"]) == ["Sticky Notes", "My Old Notes"])
        #expect(ranked("vsc", ["Very Secret Visual Studio Code", "Visual Studio Code"]).first == "Visual Studio Code")
        // Initials from the first word beat a later word.
        #expect(ranked("vs", ["Mail VS", "Visual Studio"]).first == "Visual Studio")
        // Substring: earlier is better.
        #expect(ranked("ode", ["Xcode", "Modem"]) == ["Modem", "Xcode"])
        // Subsequence: tighter is better.
        #expect(ranked("xcd", ["Xcalibured", "Xcode"]) == ["Xcode", "Xcalibured"])
        // Initials outrank a subsequence: "xc" + "d" are word prefixes of Xcalibur Driver.
        #expect(ranked("xcd", ["Xcode", "Xcalibur Driver"]) == ["Xcalibur Driver", "Xcode"])
    }

    @Test func boostsBelowOneNeverBeatAnExactMatch() throws {
        let exact = try #require(FuzzyMatcher.match("notes", in: "Notes"))
        let prefix = try #require(FuzzyMatcher.match("notes", in: "Notes Pro"))
        let weakPrefix = try #require(FuzzyMatcher.match("notes", in: "Notes Professional Edition"))
        let wordPrefix = try #require(FuzzyMatcher.match("notes", in: "Sticky Notes"))
        #expect(prefix.rank + 0.99 < exact.rank)
        #expect(wordPrefix.rank + 0.99 > weakPrefix.rank, "a strong boost may lift a match past the next tier")
        #expect(wordPrefix.rank + 0.99 < exact.rank)
        for tier in Tier.allCases {
            #expect(FuzzyMatcher.Match(tier: tier, score: 0.99).rank < FuzzyMatcher.Match(tier: tier, score: 0).rank + 1)
        }
    }

    @Test func namesSplitIntoWords() {
        #expect(words("Visual Studio Code") == ["visual", "studio", "code"])
        #expect(words("FaceTime") == ["face", "time"])
        #expect(words("iPhone-Mirroring") == ["i", "phone", "mirroring"])
        #expect(words("Office365") == ["office", "365"])
        #expect(words("Rechnung-Telekom-2026-08.pdf") == ["rechnung", "telekom", "2026", "08", "pdf"])
        #expect(words("Café_Übersicht") == ["cafe", "ubersicht"])
        #expect(words("Straße") == ["strasse"])
        #expect(words("PDFKit") == ["pdfkit"], "only lower→upper changes split")
        #expect(words("  🙂 ") == [])
    }

    @Test func queriesKnowTheirTypedWords() {
        let query = FuzzyMatcher.Query("Code, visual!")
        #expect(query.terms.map { String(String.UnicodeScalarView($0)) } == ["code", "visual"])
        #expect(query.length == 10)
        #expect(FuzzyMatcher.Query(" \u{2013} ").isEmpty)
    }

    @Test func bestMatchAcrossNames() {
        let names = ["Systemeinstellungen", "System Settings"].map(FuzzyMatcher.Name.init)
        #expect(FuzzyMatcher.bestMatch(FuzzyMatcher.Query("settings"), in: names)?.tier == .wordPrefix)
        #expect(FuzzyMatcher.bestMatch(FuzzyMatcher.Query("system settings"), in: names)?.tier == .exact)
        #expect(FuzzyMatcher.bestMatch(FuzzyMatcher.Query("zzz"), in: names) == nil)
    }

    @Test func equalMatchesKeepAStableOrder() {
        // Same rank: by name as Finder sorts it (numbers numerically), then by id.
        #expect(SearchOrder.precedes(rank: 1, name: "Datei 2", id: "b", rank: 1, name: "Datei 10", id: "a"))
        #expect(SearchOrder.precedes(rank: 1, name: "Notes", id: "/a", rank: 1, name: "Notes", id: "/b"))
        #expect(!SearchOrder.precedes(rank: 1, name: "Notes", id: "/b", rank: 1, name: "Notes", id: "/a"))
        #expect(SearchOrder.precedes(rank: 2, name: "Zebra", id: "z", rank: 1, name: "Apfel", id: "a"))
    }

    // MARK: Helpers

    private func ranked(_ query: String, _ names: [String]) -> [String] {
        let prepared = FuzzyMatcher.Query(query)
        return names.compactMap { name in FuzzyMatcher.match(prepared, in: FuzzyMatcher.Name(name)).map { (name, $0.rank) } }
            .sorted { SearchOrder.precedes(rank: $0.1, name: $0.0, id: $0.0, rank: $1.1, name: $1.0, id: $1.0) }
            .map(\.0)
    }

    private func words(_ text: String) -> [String] {
        let name = FuzzyMatcher.Name(text)
        return name.wordStarts.indices.map { index in
            String(String.UnicodeScalarView(name.scalars[name.wordStarts[index]..<name.wordEnd(index)]))
        }
    }
}
