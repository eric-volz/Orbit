import Foundation
import os

/// A file or folder found by name.
struct FileHit: Sendable, Hashable {
    var path: String
    /// The name Finder shows.
    var name: String
    /// The name on disk.
    var fileSystemName: String
    var isFolder: Bool
    /// The later of last use and modification.
    var date: Date?
    /// The folder as Finder names it (see `FolderNames`); nil shows the path.
    var folderNames: [String]?

    init(path: String, name: String, fileSystemName: String? = nil, isFolder: Bool = false, date: Date? = nil,
         folderNames: [String]? = nil) {
        self.path = path
        self.name = name
        self.fileSystemName = fileSystemName ?? FilePath.lastComponent(path)
        self.isFolder = isFolder
        self.date = date
        self.folderNames = folderNames
    }

    /// The names matched against the typed text: the shown name, the name on
    /// disk and that name without its extension ("Angebot" for Angebot.docx).
    var matchNames: [FuzzyMatcher.Name] {
        let base = (fileSystemName as NSString).deletingPathExtension
        var seen = Set<String>()
        return [name, fileSystemName, base].filter { !$0.isEmpty && seen.insert($0).inserted }.map(FuzzyMatcher.Name.init)
    }
}

/// What a file search found so far.
struct FileSearchSnapshot: Sendable, Hashable {
    /// Best first.
    var hits: [FileHit]
    /// The last snapshot of a search; earlier ones may lack matches that are still coming.
    var isFinal: Bool
}

/// Finds files by name for instant search. Live: `SpotlightFileNameSearch`.
protocol FileNameSearching: Sendable {
    /// Files and folders whose name matches every word of `text`, best first,
    /// as progressive snapshots (each the whole list so far); the last one is
    /// final. Ending the iteration or cancelling the consuming task stops the search.
    func search(_ text: String) -> AsyncThrowingStream<FileSearchSnapshot, any Error>
}

/// File-name search on the shared Spotlight layer, with the same scope,
/// visibility and access rules as the file tools (`FileToolContext`): hidden
/// items, ~/Library, package contents and secrets are never listed, and in a
/// debug session only the ORBIT_DEBUG_FILE_SCOPE folder is searched. Apps are
/// left out (the app index shows them).
///
/// Every typed word must be a word prefix of the name (case- and
/// diacritic-insensitive), like in `search_files`. Two queries run side by side:
/// one on the name on disk, which Spotlight answers within milliseconds, and one
/// on the name Finder shows (localized folder names such as "Dokumente"), which
/// always takes about 180 ms, so the first results arrive early and the rest
/// merge in. Results are ranked by `FileRanking`; the ones shown get their
/// folder as Finder names it (`FileToolContext.folderNames`).
struct SpotlightFileNameSearch: FileNameSearching {
    /// Results read per query, newest first (bounds the work on the main actor).
    static let readLimit = 100
    /// Typed text with more words is a sentence for the agent, not a file name.
    static let maxTerms = 6
    static let timeout: Duration = .seconds(2)
    static let excludedContentTypes = ["com.apple.application"]

    var spotlight: any SpotlightQuerying
    /// The file tools' scope, visibility and access rules.
    var rules: FileToolContext
    var limit: Int
    var now: @Sendable () -> Date

    init(spotlight: any SpotlightQuerying, rules: FileToolContext, limit: Int = SearchLayout.maxResults,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.spotlight = spotlight
        self.rules = rules
        self.limit = limit
        self.now = now
    }

    func search(_ text: String) -> AsyncThrowingStream<FileSearchSnapshot, any Error> {
        let (stream, continuation) = AsyncThrowingStream<FileSearchSnapshot, any Error>.makeStream()
        let terms = SpotlightQuery.searchTerms(from: text)
        guard !terms.isEmpty, terms.count <= Self.maxTerms else {
            continuation.yield(FileSearchSnapshot(hits: [], isFinal: true))
            continuation.finish()
            return stream
        }
        let task = Task {
            await run(terms: terms, text: text, continuation: continuation)
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// The two queries for `terms`: names on disk first, then Finder's names.
    func queries(for terms: [String]) -> [SpotlightQuery] {
        let byFileSystemName = SpotlightQuery(
            terms: terms, termMatch: .names, nameFields: .fileSystemName, excludedContentTypes: Self.excludedContentTypes,
            scopes: rules.scope.defaultDirectories(), sort: .modifiedNewestFirst, maxResults: Self.readLimit
        )
        var byDisplayName = byFileSystemName
        byDisplayName.nameFields = .displayName
        return [byFileSystemName, byDisplayName]
    }

    private func run(terms: [String], text: String,
                     continuation: AsyncThrowingStream<FileSearchSnapshot, any Error>.Continuation) async {
        let start = ContinuousClock.now
        let merger = Merger(rules: rules, query: FuzzyMatcher.Query(text), now: now(), limit: limit)
        let queries = queries(for: terms)
        let spotlight = spotlight
        await withTaskGroup(of: Void.self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask {
                    do {
                        for try await results in spotlight.snapshots(of: query, timeout: Self.timeout) {
                            if let hits = await merger.update(source: index, with: results) {
                                continuation.yield(FileSearchSnapshot(hits: hits, isFinal: false))
                            }
                        }
                    } catch is CancellationError {
                    } catch {
                        Log.search.error("Instant file search: a Spotlight query failed (\(String(describing: type(of: error)), privacy: .public))")
                    }
                }
            }
        }
        guard !Task.isCancelled else {
            continuation.finish()
            return
        }
        let hits = await merger.hits
        let milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
        Log.search.debug("Instant file search: \(hits.count) results in \(milliseconds) ms")
        continuation.yield(FileSearchSnapshot(hits: hits, isFinal: true))
        continuation.finish()
    }

    /// Combines the latest results of both queries into one ranked, checked list.
    private actor Merger {
        let rules: FileToolContext
        let query: FuzzyMatcher.Query
        let now: Date
        let limit: Int
        private var latest: [Int: [SpotlightItem]] = [:]
        private(set) var hits: [FileHit] = []

        init(rules: FileToolContext, query: FuzzyMatcher.Query, now: Date, limit: Int) {
            self.rules = rules
            self.query = query
            self.now = now
            self.limit = limit
        }

        /// The new list, or nil when it did not change.
        func update(source: Int, with results: SpotlightResults) -> [FileHit]? {
            latest[source] = results.items
            var seen = Set<String>()
            let items = latest.keys.sorted().flatMap { latest[$0] ?? [] }.filter { item in
                seen.insert(item.path).inserted && rules.isListable(item)
            }
            let ranked = FileRanking.rank(items, query: query, now: now)
            // The full check touches the disk, so only for the best candidates.
            let checked = rules.verified(Array(ranked.prefix(limit * 2)).map(\.item))
            let checkedPaths = Set(checked.map(\.path))
            let updated = ranked.filter { checkedPaths.contains($0.item.path) }.prefix(limit).map { ranked in
                // Finder's folder names come from the disk too (cached per folder).
                var hit = ranked.hit
                hit.folderNames = rules.folderNames.names(ofFolderContaining: hit.path)
                return hit
            }
            guard updated != hits else { return nil }
            hits = updated
            return updated
        }
    }
}

/// How instant search orders files: an exact name first, then by recency with
/// a small lead for names that start with the typed text.
///
/// score = name bonus + recency, where the bonus is 2 for an exact match (of
/// the shown name, the name on disk, or that name without extension), 0.3 for a
/// prefix and 0.15 for a word-prefix match, and recency = 1 / (1 + age / 14 days)
/// of the later of last use and modification (0 without a date). So a file used
/// today (≈ 1) comes before one from last month (≈ 0.3) whichever word matched.
enum FileRanking {
    static let halfLife: TimeInterval = 14 * 86_400

    struct Ranked: Sendable {
        var item: SpotlightItem
        var hit: FileHit
        var score: Double
    }

    static func rank(_ items: [SpotlightItem], query: FuzzyMatcher.Query, now: Date) -> [Ranked] {
        items.map { item in
            let hit = FileHit(path: item.path, name: item.displayName.isEmpty ? item.fileSystemName : item.displayName,
                              fileSystemName: item.fileSystemName, isFolder: item.isFolder, date: item.mostRecentDate)
            return Ranked(item: item, hit: hit, score: score(hit, query: query, now: now))
        }
        .sorted { lhs, rhs in
            SearchOrder.precedes(rank: lhs.score, name: lhs.hit.name, id: lhs.hit.path,
                                 rank: rhs.score, name: rhs.hit.name, id: rhs.hit.path)
        }
    }

    static func score(_ hit: FileHit, query: FuzzyMatcher.Query, now: Date) -> Double {
        let bonus: Double
        switch FuzzyMatcher.bestMatch(query, in: hit.matchNames)?.tier {
        case .exact: bonus = 2
        case .prefix: bonus = 0.3
        case .wordPrefix: bonus = 0.15
        default: bonus = 0
        }
        return bonus + recency(hit.date, now: now)
    }

    static func recency(_ date: Date?, now: Date) -> Double {
        guard let date else { return 0 }
        return 1 / (1 + max(0, now.timeIntervalSince(date)) / halfLife)
    }

    /// Whether an earlier hit still fits text typed since (kept on screen while
    /// the new search runs): every typed word is a word prefix of the name.
    static func stillMatches(_ hit: FileHit, query: FuzzyMatcher.Query) -> Bool {
        guard let match = FuzzyMatcher.bestMatch(query, in: hit.matchNames) else { return false }
        return match.tier >= .wordPrefix
    }
}
