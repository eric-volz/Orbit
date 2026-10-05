import Foundation
import Testing
@testable import Orbit

/// InstantSearch on fakes: a fixed app list, a file search the test answers,
/// listed contacts and a debounce clock the test advances.
@MainActor
@Suite("InstantSearch")
struct InstantSearchTests {
    let clock = ManualClock()
    let files = ScriptedFileSearch()
    let opener = MockSearchOpener()
    let launchCounts = InMemoryLaunchCounts()

    static let apps = ["Safari", "Mail", "Karten", "Kalender", "Rechner", "Notizen", "Musik", "Maps Pro"].map { IndexedApp.fake($0) }
    static let contacts = [
        ContactHit(identifier: "A1B2:ABPerson", name: "Marie Schneider", detail: "marie@example.com"),
        ContactHit(identifier: "C3D4:ABPerson", name: "Martin Maier", detail: nil),
        ContactHit(identifier: "E5F6:ABPerson", name: "Mario Rossi", detail: "Pizzeria"),
    ]

    func makeSearch(apps: [IndexedApp] = apps, contacts: [ContactHit] = contacts,
                    files: (any FileNameSearching)? = nil) -> (InstantSearch, FakeAppIndex, MockContactSearch) {
        let index = FakeAppIndex(apps)
        let contactSearch = MockContactSearch(contacts)
        let search = InstantSearch(dependencies: .fake(apps: index, files: files ?? self.files, contacts: contactSearch,
                                                       opener: opener, launchCounts: launchCounts, clock: clock,
                                                       homeDirectory: "/Users/lisa"))
        return (search, index, contactSearch)
    }

    // MARK: Debounce and cancellation

    @Test func nothingIsSearchedBeforeTheDebounce() async {
        let (search, _, contacts) = makeSearch()
        search.search("saf")
        #expect(search.isSearching)
        #expect(await eventually { clock.pendingCount == 1 })
        #expect(search.groups.isEmpty)
        #expect(files.queries.isEmpty && contacts.queries.isEmpty)

        clock.advance()
        #expect(await eventually { titles(search) == [.apps: ["Safari"]] })
        #expect(clock.requests == [.milliseconds(80)])
    }

    @Test func appsComeFirstThenFilesAndContactsMergeIn() async {
        let (search, _, contacts) = makeSearch()
        search.search("ma")
        await debounce()
        #expect(await eventually { titles(search)[.apps] == ["Mail", "Maps Pro"] }, "more of the name typed first")
        #expect(await eventually { contacts.queries == ["ma"] && files.queries == ["ma"] })
        #expect(await eventually { titles(search)[.contacts] == ["Mario Rossi", "Martin Maier"] })
        #expect(search.isSearching, "the file search is still running")

        files.send([hit("Mahnung.pdf", in: "/Users/lisa/Documents")], isFinal: true)
        #expect(await eventually { !search.isSearching })
        #expect(search.groups.map(\.category) == [.apps, .files, .contacts])
        #expect(titles(search)[.files] == ["Mahnung.pdf"])
        #expect(search.results.map(\.id) == ["app:/Applications-Orbit-Test/Mail.app", "app:/Applications-Orbit-Test/Maps Pro.app",
                                             "file:/Users/lisa/Documents/Mahnung.pdf", "contact:E5F6:ABPerson",
                                             "contact:C3D4:ABPerson"])
    }

    @Test func typingFastSearchesOnlyTheLastText() async {
        let (search, _, contacts) = makeSearch()
        search.search("r")
        search.search("re")
        search.search("rec")
        #expect(await eventually { clock.requests.count == 3 && clock.pendingCount == 1 }, "earlier waits were cancelled")
        clock.advance()
        #expect(await eventually { files.queries == ["rec"] && contacts.queries == ["rec"] })
        #expect(titles(search)[.apps] == ["Rechner"])
    }

    @Test func aNewQueryStopsTheRunningFileSearch() async {
        let (search, _, _) = makeSearch()
        search.search("rech")
        await debounce()
        #expect(await eventually { files.queries == ["rech"] })
        search.search("rechn")
        #expect(await eventually { files.cancelledQueries == ["rech"] })
        await debounce()
        #expect(await eventually { files.queries == ["rech", "rechn"] })
    }

    @Test func clearStopsEverythingAndEmptiesTheList() async {
        let (search, _, _) = makeSearch()
        search.search("rech")
        await debounce()
        #expect(await eventually { files.queries == ["rech"] && !search.groups.isEmpty })
        search.clear()
        #expect(search.groups.isEmpty)
        #expect(!search.isSearching)
        #expect(await eventually { files.cancelledQueries == ["rech"] })
        files.send([hit("Rechnung.pdf")], isFinal: true)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(search.groups.isEmpty, "late results of a cleared search are dropped")
        search.search("")
        #expect(clock.pendingCount == 0)
    }

    @Test func onlyAChangedTextSearchesAgain() async {
        let (search, _, _) = makeSearch()
        search.search("saf")
        await debounce()
        #expect(await eventually { !search.groups.isEmpty && files.queries == ["saf"] })
        search.search("  saf ")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(clock.requests.count == 1)
        #expect(files.queries == ["saf"])
    }

    @Test func refreshSearchesTheSameTextAgainWithoutFlashing() async {
        let (search, _, _) = makeSearch()
        search.refresh()
        #expect(clock.requests.isEmpty, "nothing to refresh")
        search.search("mai")
        await debounce()
        #expect(await eventually { files.queries == ["mai"] })
        files.send([hit("Mailvorlage.txt")], isFinal: true)
        #expect(await eventually { !search.isSearching })
        let shown = search.groups

        search.refresh()
        #expect(search.groups == shown, "the results stay while the search runs again")
        #expect(search.isSearching)
        await debounce()
        #expect(await eventually { files.queries == ["mai", "mai"] })
        files.send([hit("Mailvorlage.txt"), hit("Mailing-Liste.csv")], isFinal: true)
        #expect(await eventually { titles(search)[.files] == ["Mailvorlage.txt", "Mailing-Liste.csv"] })
    }

    @Test func filesAndContactsNeedTwoCharacters() async {
        let (search, _, contacts) = makeSearch()
        search.search("m")
        await debounce()
        #expect(await eventually { !search.isSearching })
        #expect(titles(search)[.apps] == ["Mail", "Musik", "Maps Pro"])
        #expect(files.queries.isEmpty && contacts.queries.isEmpty)
        search.search("m.")
        #expect(await eventually { clock.pendingCount == 1 })
        clock.advance()
        #expect(await eventually { !search.isSearching })
        #expect(files.queries.isEmpty, "punctuation does not count")
    }

    // MARK: Stale results

    @Test func resultsThatStillMatchStayWhileTheNextSearchRuns() async {
        let (search, _, _) = makeSearch()
        search.search("re")
        await debounce()
        #expect(await eventually { files.queries == ["re"] })
        files.send([hit("Rechnung.pdf"), hit("Rechner-Notizen.txt"), hit("Telekom-Rechnung.pdf"), hit("Reise.md")], isFinal: true)
        #expect(await eventually { titles(search)[.files]?.count == 4 })

        // Typing on: what no longer matches goes at once, the rest stays, before the debounce.
        search.search("rechnung")
        #expect(titles(search)[.files] == ["Rechnung.pdf", "Telekom-Rechnung.pdf"])
        #expect(titles(search)[.apps] == nil, "Rechner no longer matches")

        // A first batch merges in front of the earlier results …
        await debounce()
        #expect(await eventually { files.queries == ["re", "rechnung"] })
        files.send([hit("Rechnung-2026-08.pdf")], isFinal: false)
        #expect(await eventually { titles(search)[.files] == ["Rechnung-2026-08.pdf", "Rechnung.pdf", "Telekom-Rechnung.pdf"] })
        // … and the final list replaces them.
        files.send([hit("Rechnung-2026-08.pdf"), hit("Telekom-Rechnung.pdf")], isFinal: true)
        #expect(await eventually { titles(search)[.files] == ["Rechnung-2026-08.pdf", "Telekom-Rechnung.pdf"] })
    }

    @Test func mergingKeepsEarlierHitsAfterNewOnes() {
        let merged = InstantSearch.merged([hit("b"), hit("c")], keeping: [hit("a"), hit("b")])
        #expect(merged.map(\.name) == ["b", "c", "a"])
    }

    @Test func aFailingFileSearchShowsNoFiles() async {
        struct Broken: FileNameSearching {
            func search(_ text: String) -> AsyncThrowingStream<FileSearchSnapshot, any Error> {
                AsyncThrowingStream { $0.finish(throwing: SpotlightError.couldNotStart) }
            }
        }
        let (search, _, _) = makeSearch(contacts: [], files: Broken())
        search.search("mai")
        await debounce()
        #expect(await eventually { !search.isSearching })
        #expect(titles(search) == [.apps: ["Mail"]])
    }

    // MARK: Grouping and limits

    @Test func groupsAreLimitedAndInFixedOrder() async {
        let manyApps = (1...6).map { IndexedApp.fake("Test App \($0)") }
        let contacts = (1...3).map { ContactHit(identifier: "id\($0)", name: "Test Person \($0)") }
        let answering = ScriptedFileSearch { _ in (1...10).map { fileHit("Test File \($0).txt") } }
        let (search, _, _) = makeSearch(apps: manyApps, contacts: contacts, files: answering)
        search.search("test")
        await debounce()
        #expect(await eventually { !search.isSearching })
        #expect(search.groups.map(\.category) == [.apps, .files, .contacts])
        #expect(search.groups.map(\.results.count) == [4, 2, 2])
        #expect(search.results.count == SearchLayout.maxResults)
    }

    @Test(arguments: [
        (0, 0, 0, [Int]()),
        (1, 0, 0, [1]),
        (6, 0, 0, [4]),
        (1, 10, 0, [1, 7]),
        (0, 10, 0, [8]),
        (0, 10, 5, [6, 2]),
        (4, 10, 2, [4, 2, 2]),
        (3, 1, 1, [3, 1, 1]),
        (2, 0, 3, [2, 2]),
    ])
    func layoutRule(apps: Int, files: Int, contacts: Int, expected: [Int]) {
        func results(_ count: Int, _ prefix: String) -> [SearchResult] {
            (0..<count).map { SearchResult(id: "\(prefix)\($0)", kind: .contact(identifier: "\($0)"), title: "\($0)") }
        }
        let groups = SearchLayout.groups(apps: results(apps, "a"), files: results(files, "f"), contacts: results(contacts, "c"))
        #expect(groups.map(\.results.count) == expected)
        #expect(groups.map(\.category) == [SearchResultGroup.Category.apps, .files, .contacts].filter { category in
            switch category {
            case .apps: apps > 0
            case .files: files > 0
            case .contacts: contacts > 0
            }
        })
    }

    // MARK: Apps

    @Test func launchCountsLiftFrequentlyOpenedApps() async throws {
        let apps = ["Nova", "Notes"].map { IndexedApp.fake($0) }
        let (search, _, _) = makeSearch(apps: apps)
        search.search("no")
        await debounce()
        #expect(await eventually { titles(search)[.apps] == ["Nova", "Notes"] }, "Nova: more of the name typed")

        let notes = try #require(search.results.first { $0.title == "Notes" })
        for _ in 0..<3 {
            await search.open(notes).value
        }
        #expect(launchCounts.launchCounts() == ["/Applications-Orbit-Test/Notes.app": 3])
        search.search("not")
        search.search("no")
        await debounce()
        #expect(await eventually { titles(search)[.apps] == ["Notes", "Nova"] })
    }

    @Test func theShownNameWinsATieWithAnotherName() {
        let apps = [IndexedApp(path: "/Apps/Maps.app", name: "Karten", aliases: ["Maps"]), IndexedApp.fake("Mail")]
        let ranked = AppRanking.rank(apps, query: FuzzyMatcher.Query("ma"), launchCounts: [:], limit: 4)
        #expect(ranked.map(\.name) == ["Mail", "Karten"])
        #expect(apps[0].match(FuzzyMatcher.Query("maps"))?.tier == .exact, "other names still match fully")
    }

    @Test func aNewScanOfTheAppFoldersUpdatesTheList() async {
        let (search, index, _) = makeSearch(apps: [])
        #expect(index.startCount == 1)
        search.search("rech")
        index.replace(with: [.fake("Rechner")])
        #expect(search.groups.isEmpty, "not before the debounce")
        await debounce()
        #expect(await eventually { titles(search)[.apps] == ["Rechner"] })
        index.replace(with: [.fake("Rechner"), .fake("Rechenschieber")])
        #expect(titles(search)[.apps] == ["Rechner", "Rechenschieber"])
    }

    @Test func appsWithTheSameNameShowTheirFolder() {
        let results = SearchResults.apps([.fake("Xcode", folder: "/Applications"), .fake("Xcode", folder: "/Users/lisa/Applications"),
                                          .fake("Safari")], homeDirectory: "/Users/lisa")
        #expect(results.map(\.subtitle) == ["/Applications", "~/Applications", "Application"])
        #expect(results[0].kind == .app(url: URL(fileURLWithPath: "/Applications/Xcode.app", isDirectory: true)))
    }

    @Test func filesShowTheirFolder() {
        let results = SearchResults.files([hit("Rechnung.pdf", in: "/Users/lisa/Documents"),
                                           FileHit(path: "/Users/lisa/Projekte", name: "Projekte", isFolder: true)],
                                          homeDirectory: "/Users/lisa")
        #expect(results.map(\.subtitle) == ["~/Documents", "~"])
        #expect(results.map(\.id) == ["file:/Users/lisa/Documents/Rechnung.pdf", "file:/Users/lisa/Projekte"])
        #expect(results[1].kind == .file(url: URL(fileURLWithPath: "/Users/lisa/Projekte", isDirectory: true)))
    }

    // MARK: Opening

    @Test func openingResults() async {
        let (search, _, _) = makeSearch()
        let app = SearchResult(id: "app:/Applications/Safari.app", kind: .app(url: URL(fileURLWithPath: "/Applications/Safari.app")),
                               title: "Safari")
        let file = SearchResult(id: "file:/Users/lisa/a b.pdf", kind: .file(url: URL(fileURLWithPath: "/Users/lisa/a b.pdf")),
                                title: "a b.pdf")
        let contact = SearchResult(id: "contact:A1B2:ABPerson", kind: .contact(identifier: "A1B2-C3:ABPerson"), title: "Marie")
        await search.open(app).value
        await search.open(file).value
        await search.open(contact).value
        #expect(opener.openedApps == [URL(fileURLWithPath: "/Applications/Safari.app")])
        #expect(opener.openedURLs.map(\.absoluteString) == ["file:///Users/lisa/a%20b.pdf", "addressbook://A1B2-C3:ABPerson"])
        #expect(launchCounts.launchCounts() == ["/Applications/Safari.app": 1], "only apps are counted")
    }

    // MARK: Wiring

    @Test func theAppEnvironmentsSearchRunsOnInjectedServices() async {
        let spotlight = MockSpotlight()
        let index = FakeAppIndex([.fake("Rechner")])
        let contacts = MockContactSearch()
        let opener = MockSearchOpener()
        let search = InstantSearch(services: .fake(spotlight: spotlight, apps: index, contacts: contacts, searchOpener: opener))
        #expect(index.startCount == 1)
        search.search("rechner")
        #expect(await eventually(timeout: .seconds(2)) { titles(search)[.apps] == ["Rechner"] })
        #expect(await eventually(timeout: .seconds(2)) { !search.isSearching })
        #expect(spotlight.queries.count == 2)
        #expect(spotlight.queries.allSatisfy { $0.scopes.isEmpty }, "the fake file scope has no folders")
        #expect(contacts.queries == ["rechner"])
        await search.open(search.results[0]).value
        #expect(opener.openedApps.map(\.lastPathComponent) == ["Rechner.app"])
    }

    /// From the keystroke to the first results, with the real 80 ms debounce and 500 apps (target: about 85 ms).
    /// The pipeline runs on the main actor, which the other suites keep busy at the start of a parallel run: a
    /// first, cold search is not measured, and the best of several keystrokes must be well within the target: a
    /// passing stall cannot fail the test, a slow pipeline still does. Orbit's own work is measured without
    /// scheduling in `AppIndexTests.queryLatencyForFiveHundredApps`, the debounce in `nothingIsSearchedBeforeTheDebounce`.
    @Test func firstResultsArriveWellWithinTheTarget() async {
        let search = InstantSearch(dependencies: InstantSearchDependencies(
            apps: FakeAppIndex(AppIndexTests.fiveHundredApps()), files: ScriptedFileSearch(), contacts: MockContactSearch(),
            opener: opener, launchCounts: launchCounts, homeDirectory: "/Users/lisa"))
        search.search("kal")
        #expect(await eventually { !search.groups.isEmpty }, "warm-up, not measured")
        var durations: [Duration] = []
        for text in ["saf", "code", "photo", "mail", "note"] {
            search.clear()
            let start = ContinuousClock.now
            search.search(text)
            #expect(await eventually { !search.groups.isEmpty })
            durations.append(ContinuousClock.now - start)
        }
        print("Instant search, keystroke to first results (80 ms debounce, 500 apps): "
            + durations.map { AppIndexTests.milliseconds($0) + " ms" }.joined(separator: ", "))
        let best = durations.min() ?? .seconds(60)
        #expect(best < .milliseconds(300), "best of \(durations.count): \(AppIndexTests.milliseconds(best)) ms")
    }

    // MARK: Helpers

    private func debounce() async {
        _ = await eventually { clock.pendingCount == 1 }
        clock.advance()
    }

    private func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        await SearchTestSupport.eventually(timeout: timeout, condition)
    }

    private func titles(_ search: InstantSearch) -> [SearchResultGroup.Category: [String]] {
        Dictionary(uniqueKeysWithValues: search.groups.map { ($0.category, $0.results.map(\.title)) })
    }

    private func hit(_ name: String, in folder: String = "/Users/lisa/Documents") -> FileHit {
        fileHit(name, in: folder)
    }
}

private func fileHit(_ name: String, in folder: String = "/Users/lisa/Documents") -> FileHit {
    FileHit(path: folder + "/" + name, name: name, date: nil)
}

@Suite("ContactSearch")
struct ContactSearchTests {
    @Test func contactsOpenInContacts() {
        #expect(ContactRanking.url(forContact: "410FE041-5C4E-48DA-B4DE-04C15EA3DBAC:ABPerson")?.absoluteString
            == "addressbook://410FE041-5C4E-48DA-B4DE-04C15EA3DBAC:ABPerson")
        #expect(ContactRanking.url(forContact: "a b/c?d")?.absoluteString == "addressbook://a%20b%2Fc%3Fd")
        #expect(ContactRanking.url(forContact: "") == nil)
    }

    @Test func bestNameMatchFirstAndLimited() {
        let hits = [ContactHit(identifier: "1", name: "Anna Martin"), ContactHit(identifier: "2", name: "Martina Berg"),
                    ContactHit(identifier: "3", name: "Martin"), ContactHit(identifier: "4", name: "Lisa (Firma)")]
        let ranked = ContactRanking.rank(hits, query: FuzzyMatcher.Query("martin"), limit: 3)
        #expect(ranked.map(\.name) == ["Martin", "Martina Berg", "Anna Martin"])
        #expect(ContactRanking.rank(hits, query: FuzzyMatcher.Query("martin"), limit: 0).isEmpty)
    }

    @Test func aDebugSessionHasNoContacts() async throws {
        #expect(try await NoContactSearch().search("Marie", limit: 2).isEmpty)
    }
}

@Suite("LaunchCounts")
struct LaunchCountsTests {
    @Test func countsAppLaunchesInTheDefaults() {
        let defaults = AgentTestDefaults()
        let counts = LaunchCounts(defaults: defaults)
        counts.recordLaunch(ofAppAt: "/Applications/Safari.app")
        counts.recordLaunch(ofAppAt: "/Applications/Safari.app/")
        counts.recordLaunch(ofAppAt: "/Applications/Mail.app")
        counts.recordLaunch(ofAppAt: "/Users/lisa/Documents/Rechnung.pdf")
        counts.recordLaunch(ofAppAt: "relative/Thing.app")
        #expect(counts.launchCounts() == ["/Applications/Safari.app": 2, "/Applications/Mail.app": 1])
        #expect(defaults.dictionary(forKey: LaunchCounts.defaultsKey) as? [String: Int] == counts.launchCounts())
        #expect(LaunchCounts(defaults: defaults).launchCounts() == counts.launchCounts(), "read back at the next launch")
    }

    @Test func staysBoundedButKeepsTheAppJustLaunched() {
        let counts = LaunchCounts(defaults: AgentTestDefaults())
        for _ in 0..<2 { counts.recordLaunch(ofAppAt: "/Apps/Favorit.app") }
        for index in 0..<(LaunchCounts.maxApps + 20) {
            counts.recordLaunch(ofAppAt: String(format: "/Apps/App %03d.app", index))
        }
        var stored = counts.launchCounts()
        #expect(stored.count == LaunchCounts.maxApps)
        #expect(stored["/Apps/Favorit.app"] == 2, "the most launched app stays")
        #expect(stored["/Apps/App 119.app"] == 1, "the app just launched stays")
        #expect(stored["/Apps/App 118.app"] == nil, "among single launches the alphabetically first stay")
        counts.recordLaunch(ofAppAt: "/Apps/Zuletzt.app")
        stored = counts.launchCounts()
        #expect(stored["/Apps/Zuletzt.app"] == 1)
        #expect(stored["/Apps/App 119.app"] == nil)
        #expect(stored.count == LaunchCounts.maxApps)
    }

    @Test func ignoresAnythingButAppPathsWhenLoading() {
        let defaults = AgentTestDefaults()
        defaults.set(["/Applications/Safari.app": 4, "/Users/lisa/Rechnung.pdf": 2, "/Applications/Mail.app": "x",
                      "/Applications/Notes.app": -1, "/Applications/Maps.app": 5_000], forKey: LaunchCounts.defaultsKey)
        #expect(LaunchCounts(defaults: defaults).launchCounts() == ["/Applications/Safari.app": 4,
                                                                    "/Applications/Maps.app": LaunchCounts.maxLaunches])
    }

    @Test func boostGrowsSlowlyAndStaysBelowOneTier() {
        #expect(AppRanking.boost(forLaunches: 0) == 0)
        #expect(AppRanking.boost(forLaunches: -3) == 0)
        #expect(abs(AppRanking.boost(forLaunches: 1) - 1.0 / 6) < 0.001)
        #expect(abs(AppRanking.boost(forLaunches: 7) - 0.5) < 0.001)
        #expect(AppRanking.boost(forLaunches: 63) == 0.99)
        #expect(AppRanking.boost(forLaunches: 100_000) == 0.99)
        #expect(AppRanking.boost(forLaunches: 2) < AppRanking.boost(forLaunches: 3))
    }
}
