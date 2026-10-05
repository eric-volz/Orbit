import Foundation
import Testing
@testable import Orbit

@Suite("Spotlight predicate builder")
struct SpotlightPredicateTests {
    let scopes = [URL(fileURLWithPath: "/Users/test/Documents", isDirectory: true)]

    func format(_ query: SpotlightQuery) -> String {
        SpotlightPredicate.build(query).predicateFormat
    }

    // MARK: Terms

    @Test(arguments: [
        ("Telekom Rechnung", ["Telekom", "Rechnung"]),
        ("  invoice,  (August)  ", ["invoice", "August"]),
        ("*.pdf rech*", ["pdf", "rech"]),
        ("* ? ** \u{2013} ...", []),
        ("2026-08 report.txt", ["2026-08", "report.txt"]),
        ("\"Café Übersicht\"", ["Café", "Übersicht"]),
        ("Invoice invoice INVOICE", ["Invoice"]),
        ("O'Brien #tag", ["O'Brien", "tag"]),
        ("", []),
    ])
    func splitsSearchTerms(text: String, expected: [String]) {
        #expect(SpotlightQuery.searchTerms(from: text) == expected)
    }

    // MARK: Predicates

    @Test func everyTermMustMatchANameOrTheContent() {
        let query = SpotlightQuery(terms: ["telekom", "invoice"], scopes: scopes)
        #expect(format(query) == """
            (kMDItemDisplayName BEGINSWITH[cdw] "telekom" OR kMDItemFSName BEGINSWITH[cdw] "telekom" \
            OR kMDItemTextContent BEGINSWITH[cdw] "telekom") AND (kMDItemDisplayName BEGINSWITH[cdw] "invoice" \
            OR kMDItemFSName BEGINSWITH[cdw] "invoice" OR kMDItemTextContent BEGINSWITH[cdw] "invoice")
            """)
    }

    @Test func namesOnlyAndSingleNameFields() {
        var query = SpotlightQuery(terms: ["rechnung"], termMatch: .names, scopes: scopes)
        #expect(format(query) == #"kMDItemDisplayName BEGINSWITH[cdw] "rechnung" OR kMDItemFSName BEGINSWITH[cdw] "rechnung""#)
        query.nameFields = .fileSystemName
        #expect(format(query) == #"kMDItemFSName BEGINSWITH[cdw] "rechnung""#)
        query.nameFields = .displayName
        query.termMatch = .namesOrContent
        #expect(format(query) == #"kMDItemDisplayName BEGINSWITH[cdw] "rechnung" OR kMDItemTextContent BEGINSWITH[cdw] "rechnung""#)
        query.nameFields = []
        #expect(format(query).hasPrefix("kMDItemFSName BEGINSWITH[cdw]"), "no name field falls back to the file name")
    }

    @Test func termsStayConstantsWhateverTheyContain() throws {
        let hostile = #"x" || kMDItemFSName == "*"#
        let predicate = SpotlightPredicate.build(SpotlightQuery(terms: [hostile], termMatch: .names,
                                                                nameFields: .fileSystemName, scopes: scopes))
        let comparison = try #require(predicate as? NSComparisonPredicate)
        #expect(comparison.rightExpression.expressionType == .constantValue)
        #expect(comparison.rightExpression.constantValue as? String == hostile)
        #expect(comparison.leftExpression.keyPath == "kMDItemFSName")
        #expect(comparison.predicateOperatorType == .beginsWith)
        // c, d and the word option (0x10): Spotlight's "cdw".
        #expect(comparison.options.rawValue == 0x13)
    }

    @Test func kindsAndExclusions() {
        let pdf = SpotlightQuery(contentTypes: FileKind.pdf.contentTypes, scopes: scopes)
        #expect(format(pdf) == #"kMDItemContentTypeTree == "com.adobe.pdf""#)
        let text = SpotlightQuery(contentTypes: FileKind.text.contentTypes,
                                  excludedContentTypes: FileKind.text.excludedContentTypes, scopes: scopes)
        #expect(format(text) == #"kMDItemContentTypeTree == "public.plain-text" AND (NOT kMDItemContentTypeTree == "public.source-code")"#)
        let several = SpotlightQuery(contentTypes: ["public.image", "public.movie"],
                                     excludedContentTypes: ["public.folder", "com.apple.application"], scopes: scopes)
        #expect(format(several) == """
            (kMDItemContentTypeTree == "public.image" OR kMDItemContentTypeTree == "public.movie") AND \
            (NOT (kMDItemContentTypeTree == "public.folder" OR kMDItemContentTypeTree == "com.apple.application"))
            """)
    }

    @Test func dateBoundsAreInclusive() throws {
        let from = try #require(FlexibleDate.parse("2026-08-01T00:00:00+02:00")).date
        let through = try #require(FlexibleDate.parse("2026-08-31T23:59:59+02:00")).date
        let query = SpotlightQuery(modified: .init(from: from, through: through), lastUsed: .init(from: from),
                                   scopes: scopes)
        let predicate = try #require(SpotlightPredicate.build(query) as? NSCompoundPredicate)
        #expect(predicate.compoundPredicateType == .and)
        let parts = try predicate.subpredicates.map { try #require($0 as? NSComparisonPredicate) }
        #expect(parts.map(\.leftExpression.keyPath) == ["kMDItemContentModificationDate", "kMDItemContentModificationDate",
                                                        "kMDItemLastUsedDate"])
        #expect(parts.map(\.predicateOperatorType) == [.greaterThanOrEqualTo, .lessThanOrEqualTo, .greaterThanOrEqualTo])
        #expect(parts.map { $0.rightExpression.constantValue as? Date } == [from, through, from])
    }

    @Test func withoutConditionsEverythingInTheScopesMatches() {
        #expect(format(SpotlightQuery(scopes: scopes)) == #"kMDItemContentTypeTree == "public.item""#)
    }

    @Test func sortOrders() {
        #expect(SpotlightPredicate.sortDescriptors(for: .modifiedNewestFirst).map(\.key) == ["kMDItemContentModificationDate"])
        #expect(SpotlightPredicate.sortDescriptors(for: .lastUsedNewestFirst).map(\.key) == ["kMDItemLastUsedDate"])
        #expect(SpotlightPredicate.sortDescriptors(for: .modifiedNewestFirst).allSatisfy { !$0.ascending })
    }

    // MARK: Scopes

    @Test func onlyAbsoluteFileURLsAreSearched() throws {
        let query = SpotlightQuery(scopes: [
            URL(fileURLWithPath: "/Users/test/Documents"),
            try #require(URL(string: "https://example.com/x")),
            try #require(URL(string: "relative/path")),
        ])
        #expect(query.searchScopes.map(\.path) == ["/Users/test/Documents"])
    }

    @Test func liveSpotlightSearchesNothingWithoutScopes() async throws {
        // No NSMetadataQuery is started: an empty scope would mean "the whole Mac".
        let spotlight = LiveSpotlight()
        let empty = SpotlightQuery(terms: ["x"], scopes: [])
        #expect(try await spotlight.search(empty, timeout: .seconds(1)) == .none)
        let relative = SpotlightQuery(terms: ["x"], scopes: [try #require(URL(string: "relative"))])
        var snapshots: [SpotlightResults] = []
        for try await snapshot in spotlight.snapshots(of: relative, timeout: .seconds(1)) {
            snapshots.append(snapshot)
        }
        #expect(snapshots == [.none])
    }

    @Test func itemDerivedValues() throws {
        let used = try #require(FlexibleDate.parse("2026-09-29T10:00")).date
        let modified = try #require(FlexibleDate.parse("2026-09-20T10:00")).date
        let item = SpotlightItem(path: "/x/Ordner", contentType: "public.folder", contentTypeTree: ["public.folder"],
                                 modified: modified, lastUsed: used)
        #expect(item.displayName == "Ordner")
        #expect(item.fileSystemName == "Ordner")
        #expect(item.isFolder)
        #expect(item.mostRecentDate == used)
        #expect(SpotlightItem(path: "/x/a.pages", contentTypeTree: ["com.apple.package", "public.directory"]).isFolder == false)
        #expect(SpotlightItem(path: "/x/a").mostRecentDate == nil)
        #expect(SpotlightItem(path: "/x/a", modified: modified).mostRecentDate == modified)
    }
}
