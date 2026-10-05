import Foundation
import os
import Testing
@testable import Orbit

/// Instant file search on a mock Spotlight; the files it "finds" live in a
/// temporary folder that is the home folder and the only allowed scope.
@Suite("FileNameSearch")
struct FileNameSearchTests {
    static let now = FileFixtures.now

    @Test func searchesNamesOnDiskAndFindersNamesWithTheToolsRules() async throws {
        let folder = try TemporaryFolder("instant-files")
        defer { folder.remove() }
        let found = try [
            folder.write("Documents/Rechnung-Telekom.pdf", "pdf"),
            folder.write("Documents/Telekom Rechnung alt.pdf", "pdf"),
            folder.write("Geheim/rechnung.pem", "-----BEGIN PRIVATE KEY-----"),
            folder.write(".versteckt/Rechnung.pdf", "hidden"),
            folder.write("Projekt.pages/Rechnung.pdf", "package contents"),
            folder.makeFolder("Documents/Rechnungen"),
        ].map(\.path)
        let link = folder.path + "/Documents/Rechnung-Link.pdf"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: folder.path + "/Geheim/rechnung.pem")
        let deleted = folder.path + "/Documents/Rechnung-geloescht.pdf"
        let spotlight = MockSpotlight { query in
            if query.nameFields == .displayName {
                // Finder's (localized) name of the folder only matches here.
                return SpotlightResults(items: [Self.item(folder.path + "/Dokumente", displayName: "Rechnungsordner",
                                                          modified: Self.now, isFolder: true)],
                                        totalCount: 1, isComplete: true)
            }
            let items = (found + [link, deleted]).map { Self.item($0, modified: Self.now.addingTimeInterval(-86_400)) }
            return SpotlightResults(items: items, totalCount: items.count, isComplete: true)
        }
        try FileManager.default.createDirectory(atPath: folder.path + "/Dokumente", withIntermediateDirectories: true)
        let search = SpotlightFileNameSearch(spotlight: spotlight, rules: FileFixtures.context(root: folder.path, spotlight: spotlight),
                                             now: { Self.now })

        let snapshots = try await collect(search.search("Rechnung"))
        #expect(snapshots.last?.isFinal == true)
        #expect(snapshots.dropLast().allSatisfy { !$0.isFinal })
        let hits = try #require(snapshots.last?.hits)
        #expect(Set(hits.map(\.path)) == [found[0], found[1], found[5], folder.path + "/Dokumente"],
                "no secrets, hidden items, package contents, symlinks to secrets or deleted files")
        #expect(hits.first { $0.isFolder }?.name == "Rechnungsordner", "Finder's name is shown")

        // Both run side by side, so they arrive in any order.
        let queries = spotlight.queries
        #expect(queries.count == 2)
        #expect(Set(queries.map(\.nameFields.rawValue)) == [SpotlightQuery.NameFields.fileSystemName.rawValue,
                                                            SpotlightQuery.NameFields.displayName.rawValue])
        #expect(search.queries(for: ["a"]).map(\.nameFields) == [.fileSystemName, .displayName], "the fast one first")
        for query in queries {
            #expect(query.terms == ["Rechnung"])
            #expect(query.termMatch == .names)
            #expect(query.excludedContentTypes == ["com.apple.application"], "apps come from the app index")
            #expect(query.scopes == [URL(fileURLWithPath: folder.path, isDirectory: true)])
            #expect(query.sort == .modifiedNewestFirst)
            #expect(query.maxResults == SpotlightFileNameSearch.readLimit)
        }
    }

    /// The rows name their folder like Finder; the names are read off the main actor, in the merger.
    @Test func shownHitsNameTheirFolderLikeFinder() async throws {
        let folder = try TemporaryFolder("instant-folder-names")
        defer { folder.remove() }
        let file = try folder.write("Documents/Rechnungen/Rechnung-Telekom.pdf", "pdf").path
        let spotlight = MockSpotlight { _ in
            SpotlightResults(items: [Self.item(file, modified: Self.now)], totalCount: 1, isComplete: true)
        }
        let names = FolderNames(homeDirectory: FilePath.canonical(folder.path)) { path in
            path.hasSuffix("/Documents") ? "Dokumente" : FilePath.lastComponent(path)
        }
        let rules = FileFixtures.context(root: folder.path, spotlight: spotlight, folderNames: names)
        let search = SpotlightFileNameSearch(spotlight: spotlight, rules: rules, now: { Self.now })
        let hits = try #require(try await collect(search.search("rechnung")).last?.hits)
        #expect(hits.map(\.folderNames) == [["Dokumente", "Rechnungen"]])
        #expect(SearchResults.files(hits, homeDirectory: folder.path).map(\.subtitle) == ["Dokumente ▸ Rechnungen"])
    }

    @Test func showsAtMostTheLimit() async throws {
        let folder = try TemporaryFolder("instant-files-limit")
        defer { folder.remove() }
        let paths = try (1...20).map { try folder.write("Notiz \($0).txt", "x").path }
        let spotlight = MockSpotlight { _ in
            SpotlightResults(items: paths.map { Self.item($0) }, totalCount: 20, isComplete: true)
        }
        let search = SpotlightFileNameSearch(spotlight: spotlight, rules: FileFixtures.context(root: folder.path, spotlight: spotlight),
                                             limit: 8, now: { Self.now })
        let hits = try #require(try await collect(search.search("notiz")).last?.hits)
        #expect(hits.map(\.name) == (1...8).map { "Notiz \($0).txt" }, "equal matches in Finder's order")
    }

    @Test(arguments: ["", "  ", "*", "?!", "finde bitte die telekom rechnung vom märz"])
    func textThatIsNoFileNameSearchesNothing(text: String) async throws {
        let spotlight = MockSpotlight()
        let search = SpotlightFileNameSearch(spotlight: spotlight, rules: FileFixtures.context(spotlight: spotlight))
        let snapshots = try await collect(search.search(text))
        #expect(snapshots == [FileSearchSnapshot(hits: [], isFinal: true)])
        #expect(spotlight.queries.isEmpty)
    }

    @Test func endingTheSearchStopsTheSpotlightQueries() async throws {
        let spotlight = EndlessSpotlight()
        let search = SpotlightFileNameSearch(spotlight: spotlight, rules: FileFixtures.context(spotlight: spotlight))
        let consumer = Task {
            for try await _ in search.search("rechnung") {}
        }
        #expect(await waitUntil { spotlight.started == 2 })
        consumer.cancel()
        #expect(await waitUntil { spotlight.stopped == 2 }, "both NSMetadataQueries are stopped")
    }

    // MARK: Ranking

    @Test func exactNamesFirstThenRecentOnes() {
        let items = [
            Self.item("/Users/lisa/Alte Rechnung.pdf", modified: Self.now.addingTimeInterval(-100 * 86_400)),
            Self.item("/Users/lisa/Rechnung.pdf", modified: Self.now.addingTimeInterval(-365 * 86_400)),
            Self.item("/Users/lisa/Telekom-Rechnung.pdf", modified: Self.now.addingTimeInterval(-86_400)),
            Self.item("/Users/lisa/Rechnung-Telekom.pdf", modified: Self.now.addingTimeInterval(-3_600)),
            Self.item("/Users/lisa/Rechnung ohne Datum.pdf"),
            Self.item("/Users/lisa/Rechnungen", modified: Self.now.addingTimeInterval(-20 * 86_400), lastUsed: Self.now, isFolder: true),
        ]
        let ranked = FileRanking.rank(items, query: FuzzyMatcher.Query("rechnung"), now: Self.now).map(\.hit.name)
        #expect(ranked == ["Rechnung.pdf", "Rechnungen", "Rechnung-Telekom.pdf", "Telekom-Rechnung.pdf", "Rechnung ohne Datum.pdf",
                           "Alte Rechnung.pdf"])
    }

    @Test func recencyHalvesAfterTwoWeeks() {
        #expect(FileRanking.recency(Self.now, now: Self.now) == 1)
        #expect(abs(FileRanking.recency(Self.now.addingTimeInterval(-14 * 86_400), now: Self.now) - 0.5) < 0.0001)
        #expect(FileRanking.recency(Self.now.addingTimeInterval(3_600), now: Self.now) == 1, "future dates count as now")
        #expect(FileRanking.recency(nil, now: Self.now) == 0)
    }

    @Test(arguments: [
        ("rech", "Rechnung.pdf", true),
        ("rechnung", "Telekom-Rechnung.pdf", true),
        ("angebot", "Angebot.docx", true),
        ("pdf", "Rechnung.pdf", true),
        ("rechnung", "Rechner-Notizen.txt", false),
        ("rnt", "Rechner-Notizen.txt", true),
        ("otiz", "Rechner-Notizen.txt", false),
        ("rchng", "Rechnung.pdf", false),
    ])
    func earlierHitsStayOnlyWhileTheyStillMatch(text: String, name: String, stays: Bool) {
        let hit = FileHit(path: "/Users/lisa/" + name, name: name)
        #expect(FileRanking.stillMatches(hit, query: FuzzyMatcher.Query(text)) == stays)
    }

    // MARK: Helpers

    static func item(_ path: String, displayName: String? = nil, modified: Date? = nil, lastUsed: Date? = nil,
                     isFolder: Bool = false) -> SpotlightItem {
        SpotlightItem(path: path, displayName: displayName, contentType: isFolder ? "public.folder" : "public.data",
                      contentTypeTree: isFolder ? ["public.folder", "public.item"] : ["public.data", "public.item"],
                      modified: modified, lastUsed: lastUsed, size: isFolder ? nil : 3)
    }

    private func collect(_ stream: AsyncThrowingStream<FileSearchSnapshot, any Error>) async throws -> [FileSearchSnapshot] {
        var snapshots: [FileSearchSnapshot] = []
        for try await snapshot in stream {
            snapshots.append(snapshot)
        }
        return snapshots
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

/// A Spotlight whose queries gather forever; counts started and stopped ones.
final class EndlessSpotlight: SpotlightQuerying, Sendable {
    private let counts = OSAllocatedUnfairLock(initialState: (started: 0, stopped: 0))

    var started: Int { counts.withLock { $0.started } }
    var stopped: Int { counts.withLock { $0.stopped } }

    func snapshots(of query: SpotlightQuery, timeout: Duration) -> AsyncThrowingStream<SpotlightResults, any Error> {
        let (stream, continuation) = AsyncThrowingStream<SpotlightResults, any Error>.makeStream()
        counts.withLock { $0.started += 1 }
        continuation.onTermination = { [weak self] _ in
            self?.counts.withLock { $0.stopped += 1 }
        }
        return stream
    }
}
