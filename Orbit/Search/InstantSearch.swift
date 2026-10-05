import Foundation
import Observation
import os

/// A local search hit (no LLM involved).
struct SearchResult: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable {
        case app(url: URL)
        case file(url: URL)
        case contact(identifier: String)
    }

    var id: String
    var kind: Kind
    var title: String
    var subtitle: String?
    /// What VoiceOver reads for the subtitle when that differs (folder names
    /// without the ▸ between them); nil reads the subtitle.
    var spokenSubtitle: String? = nil
}

struct SearchResultGroup: Sendable, Hashable, Identifiable {
    enum Category: String, Sendable, Hashable {
        case apps
        case files
        case contacts
    }

    var category: Category
    var results: [SearchResult]

    var id: String { category.rawValue }

    var title: String {
        switch category {
        case .apps: String(localized: "Apps")
        case .files: String(localized: "Files")
        case .contacts: String(localized: "Contacts")
        }
    }
}

/// What instant search reads and opens. The app builds it from `AppServices`;
/// tests pass fakes.
struct InstantSearchDependencies: Sendable {
    var apps: any AppIndexing
    var files: any FileNameSearching
    var contacts: any ContactSearching
    var opener: any SearchResultOpening
    var launchCounts: any LaunchCountStoring
    /// Shown as "~" in the folder under a file.
    var homeDirectory: String
    /// Quiet time after a keystroke before searching.
    var debounce: Duration = .milliseconds(80)
    /// How the debounce waits; tests pass a clock they advance by hand. Must
    /// throw when the task is cancelled.
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

extension InstantSearchDependencies {
    /// Instant search on the app's services: files through the shared Spotlight
    /// layer with the file tools' rules, apps, contacts, opening and launch counts.
    init(services: AppServices) {
        self.init(
            apps: services.appIndex,
            files: SpotlightFileNameSearch(spotlight: services.spotlight, rules: FileToolContext(services: services)),
            contacts: services.contacts,
            opener: services.searchOpener,
            launchCounts: services.launchCounts,
            homeDirectory: services.fileScope.homeDirectory
        )
    }
}

/// Instant local results (apps, files, contacts) while the user types, no LLM.
///
/// Every keystroke first narrows what is shown to the results that still match
/// the new text, so nothing flashes empty. After the debounce (≈ 80 ms; a newer
/// keystroke cancels the wait and any search still running, which stops its
/// Spotlight queries), apps are ranked synchronously from the in-memory index;
/// the first results appear about 80 ms after the last keystroke. Files and
/// contacts (from 2 letters or digits) merge in when ready; progressive file
/// results keep the earlier ones that still match until the search is done.
/// `SearchLayout` groups and limits what is shown.
@MainActor
@Observable
final class InstantSearch {
    /// Grouped results for the current query, at most 8 in total.
    private(set) var groups: [SearchResultGroup] = []
    private(set) var isSearching = false

    /// Flattened results in display order (for keyboard navigation and ⌘1 to ⌘9).
    var results: [SearchResult] { groups.flatMap(\.results) }

    /// Files and contacts are searched from this many letters or digits.
    static let minimumLengthForFilesAndContacts = 2

    @ObservationIgnored private let dependencies: InstantSearchDependencies
    @ObservationIgnored private var query = ""
    /// Incremented for every new query; late results of older ones are dropped.
    @ObservationIgnored private var generation = 0
    /// The generation whose apps were ranked (its debounce is over).
    @ObservationIgnored private var rankedGeneration = -1
    @ObservationIgnored private var pipeline: Task<Void, Never>?
    @ObservationIgnored private var apps: [IndexedApp] = []
    @ObservationIgnored private var files: [FileHit] = []
    @ObservationIgnored private var contacts: [ContactHit] = []

    init(dependencies: InstantSearchDependencies) {
        self.dependencies = dependencies
        dependencies.apps.start { @MainActor [weak self] in
            self?.appIndexDidChange()
        }
    }

    convenience init(services: AppServices) {
        self.init(dependencies: InstantSearchDependencies(services: services))
    }

    /// Updates the query. Debounced; cancels the previous search.
    func search(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            clear()
            return
        }
        guard text != query else { return }
        query = text
        generation += 1
        pipeline?.cancel()
        let matcher = FuzzyMatcher.Query(text)
        apps = apps.filter { $0.match(matcher) != nil }
        files = files.filter { FileRanking.stillMatches($0, query: matcher) }
        contacts = contacts.filter { FuzzyMatcher.match(matcher, in: FuzzyMatcher.Name($0.name)) != nil }
        publish()
        if !isSearching { isSearching = true }
        let generation = generation
        pipeline = Task { [weak self] in
            await self?.run(text, generation: generation)
        }
    }

    /// Searches the current text again (the panel was shown again): the shown
    /// results stay until the new ones arrive.
    func refresh() {
        guard !query.isEmpty else { return }
        let text = query
        query = ""
        search(text)
    }

    /// Opens a result (launch app, open file, show contact). Opening an app
    /// counts as a launch for the ranking.
    @discardableResult
    func open(_ result: SearchResult) -> Task<Void, Never> {
        let opener = dependencies.opener
        switch result.kind {
        case .app(let url):
            dependencies.launchCounts.recordLaunch(ofAppAt: url.path)
            return Task { await Self.perform("app") { try await opener.openApplication(at: url) } }
        case .file(let url):
            return Task { await Self.perform("file") { try await opener.open(url) } }
        case .contact(let identifier):
            guard let url = ContactRanking.url(forContact: identifier) else { return Task {} }
            return Task { await Self.perform("contact") { try await opener.open(url) } }
        }
    }

    func clear() {
        pipeline?.cancel()
        pipeline = nil
        generation += 1
        query = ""
        apps = []
        files = []
        contacts = []
        if !groups.isEmpty { groups = [] }
        if isSearching { isSearching = false }
    }

    // MARK: Searching

    private func run(_ text: String, generation: Int) async {
        do {
            try await dependencies.sleep(dependencies.debounce)
        } catch {
            return
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        let started = ContinuousClock.now
        let matcher = FuzzyMatcher.Query(text)
        rankApps(matcher)
        rankedGeneration = generation
        publish()
        let milliseconds = Double((ContinuousClock.now - started) / .microseconds(1)) / 1_000
        Log.search.debug("Instant search: \(self.apps.count) apps ranked in \(milliseconds, format: .fixed(precision: 2)) ms")
        if matcher.length >= Self.minimumLengthForFilesAndContacts {
            async let fileSearch: Void = searchFiles(text, generation: generation)
            async let contactSearch: Void = searchContacts(text, generation: generation)
            _ = await (fileSearch, contactSearch)
        } else {
            files = []
            contacts = []
            publish()
        }
        guard generation == self.generation else { return }
        isSearching = false
    }

    private func searchFiles(_ text: String, generation: Int) async {
        let earlier = files
        do {
            for try await snapshot in dependencies.files.search(text) {
                guard generation == self.generation, !Task.isCancelled else { return }
                files = snapshot.isFinal ? snapshot.hits : Self.merged(snapshot.hits, keeping: earlier)
                publish()
            }
        } catch {
            guard generation == self.generation, !(error is CancellationError) else { return }
            Log.search.error("Instant file search failed (\(String(describing: type(of: error)), privacy: .public))")
            files = []
            publish()
        }
    }

    private func searchContacts(_ text: String, generation: Int) async {
        var hits: [ContactHit] = []
        do {
            hits = try await dependencies.contacts.search(text, limit: SearchLayout.maxContacts)
        } catch {
            guard !(error is CancellationError) else { return }
            Log.search.error("Instant contact search failed (\(String(describing: type(of: error)), privacy: .public))")
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        contacts = hits
        publish()
    }

    /// A progressive snapshot, then the earlier results it does not have (yet).
    static func merged(_ hits: [FileHit], keeping earlier: [FileHit]) -> [FileHit] {
        let paths = Set(hits.map(\.path))
        return hits + earlier.filter { !paths.contains($0.path) }
    }

    private func rankApps(_ matcher: FuzzyMatcher.Query) {
        apps = AppRanking.rank(dependencies.apps.apps, query: matcher, launchCounts: dependencies.launchCounts.launchCounts(),
                               limit: SearchLayout.maxApps)
    }

    /// A new scan of the app folders: rank again, unless the debounce is still running.
    private func appIndexDidChange() {
        guard !query.isEmpty, rankedGeneration == generation else { return }
        rankApps(FuzzyMatcher.Query(query))
        publish()
    }

    private func publish() {
        let home = dependencies.homeDirectory
        let updated = SearchLayout.groups(apps: SearchResults.apps(apps, homeDirectory: home),
                                          files: SearchResults.files(files, homeDirectory: home),
                                          contacts: SearchResults.contacts(contacts))
        if updated != groups { groups = updated }
    }

    private static func perform(_ kind: String, _ action: @Sendable () async throws -> Void) async {
        do {
            try await action()
        } catch {
            let error = error as NSError
            Log.search.error("Opening a \(kind, privacy: .public) from instant search failed (\(error.domain, privacy: .public) \(error.code))")
        }
    }
}

/// How instant results are grouped and limited: at most 8 in total, in the
/// fixed order Apps, Files, Contacts: up to 4 apps and up to 2 contacts,
/// and files fill the rest (at least 2). So apps keep their rows when files
/// arrive later, and the list fits the panel without scrolling.
enum SearchLayout {
    static let maxResults = 8
    static let maxApps = 4
    static let maxContacts = 2

    /// Non-empty groups in the fixed order, each cut to its limit.
    static func groups(apps: [SearchResult], files: [SearchResult], contacts: [SearchResult]) -> [SearchResultGroup] {
        let apps = Array(apps.prefix(maxApps))
        let contacts = Array(contacts.prefix(maxContacts))
        let files = Array(files.prefix(max(0, maxResults - apps.count - contacts.count)))
        return [
            SearchResultGroup(category: .apps, results: apps),
            SearchResultGroup(category: .files, results: files),
            SearchResultGroup(category: .contacts, results: contacts),
        ].filter { !$0.results.isEmpty }
    }
}

/// How instant search orders apps: the best match of any of an app's names
/// (`FuzzyMatcher`) plus a boost for apps the user opened often from instant
/// search, then by name.
enum AppRanking {
    /// 0 without launches, growing with the logarithm (1 → 0.17, 7 → 0.5, 63
    /// and more → 0.99). Below 1, so it reorders apps within a match tier and
    /// lifts one past at most one tier, never past an exact name match.
    static func boost(forLaunches launches: Int) -> Double {
        guard launches > 0 else { return 0 }
        return min(0.99, log2(Double(launches) + 1) / 6)
    }

    /// The best `limit` matching apps, best first.
    static func rank(_ apps: [IndexedApp], query: FuzzyMatcher.Query, launchCounts: [String: Int],
                     limit: Int) -> [IndexedApp] {
        guard !query.isEmpty, limit > 0 else { return [] }
        // A short sorted list of the best so far: far cheaper than sorting every match.
        var best: [(app: IndexedApp, rank: Double)] = []
        func precedes(_ lhs: (app: IndexedApp, rank: Double), _ rhs: (app: IndexedApp, rank: Double)) -> Bool {
            SearchOrder.precedes(rank: lhs.rank, name: lhs.app.name, id: lhs.app.path,
                                 rank: rhs.rank, name: rhs.app.name, id: rhs.app.path)
        }
        for app in apps {
            guard let match = app.match(query) else { continue }
            let candidate = (app: app, rank: match.rank + boost(forLaunches: launchCounts[app.path] ?? 0))
            if best.count == limit, let last = best.last, !precedes(candidate, last) { continue }
            let index = best.firstIndex { precedes(candidate, $0) } ?? best.count
            best.insert(candidate, at: index)
            if best.count > limit { best.removeLast() }
        }
        return best.map(\.app)
    }
}

/// Result rows for the search view.
enum SearchResults {
    /// "Application" under an app, or its folder when another shown app has the same name.
    static func apps(_ apps: [IndexedApp], homeDirectory: String) -> [SearchResult] {
        let names = apps.map { $0.name.lowercased() }
        return apps.map { app in
            let isAmbiguous = names.filter { $0 == app.name.lowercased() }.count > 1
            return SearchResult(
                id: "app:" + app.path,
                kind: .app(url: URL(fileURLWithPath: app.path, isDirectory: true)),
                title: app.name,
                subtitle: isAmbiguous ? folder(of: app.path, homeDirectory: homeDirectory) : String(localized: "Application")
            )
        }
    }

    /// The folder under a file as Finder names it ("Dokumente ▸ Rechnungen"),
    /// else its path ("~/Documents/Rechnungen").
    static func files(_ files: [FileHit], homeDirectory: String) -> [SearchResult] {
        files.map { file in
            let names = file.folderNames.flatMap { $0.isEmpty ? nil : $0 }
            return SearchResult(id: "file:" + file.path,
                                kind: .file(url: URL(fileURLWithPath: file.path, isDirectory: file.isFolder)),
                                title: file.name,
                                subtitle: names.map(FolderNames.shown) ?? folder(of: file.path, homeDirectory: homeDirectory),
                                spokenSubtitle: names.map(FolderNames.spoken))
        }
    }

    static func contacts(_ contacts: [ContactHit]) -> [SearchResult] {
        contacts.map { contact in
            SearchResult(id: "contact:" + contact.identifier, kind: .contact(identifier: contact.identifier),
                         title: contact.name, subtitle: contact.detail)
        }
    }

    private static func folder(of path: String, homeDirectory: String) -> String {
        FilePath.abbreviate(FilePath.normalize(path + "/.."), home: homeDirectory)
    }
}
