import Foundation
import Testing
@testable import Orbit

extension SpotlightIntegrationTests {
    /// Instant search's file search on the live index, scoped to the fixture
    /// folder like every Spotlight integration test.
    ///
    ///     ORBIT_SPOTLIGHT_TESTS=1 Scripts/swiftpm.sh test --filter SpotlightIntegration
    @Suite("Instant search (fixtures)")
    struct InstantSearchSpotlightTests {
        let search = SpotlightFileNameSearch(spotlight: LiveSpotlight(), rules: FileFixtures.context(spotlight: LiveSpotlight()))

        func names(_ text: String) async throws -> [String] {
            var last: FileSearchSnapshot?
            for try await snapshot in search.search(text) {
                last = snapshot
            }
            let final = try #require(last)
            #expect(final.isFinal)
            return final.hits.map(\.name)
        }

        @Test func findsFilesByWordPrefixesOfTheirNamesNewestFirst() async throws {
            try await SpotlightFixtures.prepare()
            let invoices = try await names("rechn")
            #expect(Set(invoices) == ["Rechnung-Telekom-2026-08.pdf", "Rechnungen", "Rechnung-Telekom-2026-06.pdf"])
            #expect(invoices.first == "Rechnung-Telekom-2026-08.pdf", "last month's invoice is the most recent")
            #expect(try await names("notiz") == ["Notizen.md", "UTF16-Notiz.txt"], "changed two days ago first; no link to a key")
            #expect(try await names("telekom rechnung") == ["Rechnung-Telekom-2026-08.pdf", "Rechnung-Telekom-2026-06.pdf"])
            #expect(try await names("invoice 2026") == ["Invoice-Notes-2026-08.txt", "Vodafone-Invoice-2026-08.pdf"])
            #expect(try await names("PRASENTATION") == ["Alt-Präsentation.key"])
            #expect(try await names("dokumente") == ["Dokumente"])
            #expect(try await names("elekom") == [], "word prefixes only")
        }

        @Test func appsSecretsHiddenItemsAndPackageContentsAreNotListed() async throws {
            try await SpotlightFixtures.prepare()
            for text in ["rechner", "server", "privat", "env", "preview", "index"] {
                #expect(try await names(text) == [], "\(text)")
            }
            #expect(try await names("zusammenfassung") == ["Zusammenfassung.rtfd"], "a package itself is listed")
        }

        @Test func firstResultsArriveEarlyAndTheSearchEnds() async throws {
            try await SpotlightFixtures.prepare()
            var report: [String] = []
            for text in ["rechnung", "vodafone", "notiz", "zzqq"] {
                let start = ContinuousClock.now
                var first: Duration?
                var snapshots: [FileSearchSnapshot] = []
                for try await snapshot in search.search(text) {
                    if first == nil, !snapshot.hits.isEmpty { first = ContinuousClock.now - start }
                    snapshots.append(snapshot)
                }
                let total = ContinuousClock.now - start
                #expect(snapshots.last?.isFinal == true)
                #expect(snapshots.dropLast().allSatisfy { !$0.isFinal })
                #expect(total < .seconds(2), "\(text)")
                #expect(first.map { $0 < .milliseconds(500) } ?? true, "\(text)")
                report.append("\(text): first \(first.map(AppIndexTests.milliseconds) ?? "none") ms, done \(AppIndexTests.milliseconds(total)) ms")
            }
            print("Instant file search on the fixtures: " + report.joined(separator: "; "))
        }

        @MainActor
        @Test func typingShowsFixtureFilesUnderTheApps() async throws {
            try await SpotlightFixtures.prepare()
            let spotlight = LiveSpotlight()
            let search = InstantSearch(dependencies: InstantSearchDependencies(
                apps: FakeAppIndex([.fake("Rechner")]),
                files: SpotlightFileNameSearch(spotlight: spotlight, rules: FileFixtures.context(spotlight: spotlight)),
                contacts: MockContactSearch(), opener: MockSearchOpener(), launchCounts: InMemoryLaunchCounts(),
                homeDirectory: FileFixtures.root))
            func titles(_ category: SearchResultGroup.Category) -> [String] {
                search.groups.first { $0.category == category }?.results.map(\.title) ?? []
            }
            let start = ContinuousClock.now
            search.search("rechn")
            #expect(await SearchTestSupport.eventually { !titles(.apps).isEmpty })
            let apps = ContinuousClock.now - start
            #expect(await SearchTestSupport.eventually { !titles(.files).isEmpty })
            let files = ContinuousClock.now - start
            #expect(await SearchTestSupport.eventually { !search.isSearching })
            let done = ContinuousClock.now - start
            #expect(titles(.apps) == ["Rechner"])
            #expect(titles(.files).first == "Rechnung-Telekom-2026-08.pdf")
            // The folder as Finder names it (read from the disk), not its path.
            let first = search.groups.first { $0.category == .files }?.results.first
            #expect(first?.subtitle == "Rechnungen")
            #expect(first?.spokenSubtitle == "Rechnungen")
            print("Instant search on the fixtures, keystroke to: apps \(AppIndexTests.milliseconds(apps)) ms, "
                + "first files \(AppIndexTests.milliseconds(files)) ms, done \(AppIndexTests.milliseconds(done)) ms")

            // Typing on narrows the list at once; the new search then confirms it.
            search.search("rechnung t")
            #expect(titles(.files) == ["Rechnung-Telekom-2026-08.pdf", "Rechnung-Telekom-2026-06.pdf"])
            #expect(await SearchTestSupport.eventually { !search.isSearching })
            #expect(titles(.files) == ["Rechnung-Telekom-2026-08.pdf", "Rechnung-Telekom-2026-06.pdf"])
        }
    }
}
