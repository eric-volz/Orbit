import Foundation

/// A Spotlight search, described as a value. `SpotlightPredicate` turns it into
/// the NSPredicate; `SpotlightQuerying` runs it.
struct SpotlightQuery: Sendable, Hashable {
    /// The name attributes search terms are matched against.
    struct NameFields: OptionSet, Sendable, Hashable {
        let rawValue: Int
        /// kMDItemDisplayName: the name Finder shows (localized, maybe without
        /// extension). Measured: every query that uses it finishes gathering only
        /// after a fixed ~180 ms, even with no match.
        static let displayName = NameFields(rawValue: 1 << 0)
        /// kMDItemFSName: the file name on disk. Fast (2 to 5 ms for a warm query).
        static let fileSystemName = NameFields(rawValue: 1 << 1)

        static let all: NameFields = [.displayName, .fileSystemName]
    }

    enum TermMatch: Sendable, Hashable {
        /// Every term must match a word of the name.
        case names
        /// Every term must match a word of the name or of the text content.
        case namesOrContent
    }

    enum SortOrder: Sendable, Hashable {
        /// kMDItemContentModificationDate, newest first.
        case modifiedNewestFirst
        /// kMDItemLastUsedDate, newest first (never used last).
        case lastUsedNewestFirst
    }

    /// An inclusive date range; nil bounds are open.
    struct DateBounds: Sendable, Hashable {
        var from: Date?
        var through: Date?

        var isEmpty: Bool { from == nil && through == nil }
    }

    /// Words that must all match (word prefix, case- and diacritic-insensitive).
    /// Use `searchTerms(from:)` to derive them from user text.
    var terms: [String] = []
    var termMatch: TermMatch = .namesOrContent
    var nameFields: NameFields = .all
    /// Only items whose content type tree contains one of these (empty = any).
    var contentTypes: [String] = []
    /// Items whose content type tree contains one of these are left out.
    var excludedContentTypes: [String] = []
    var modified = DateBounds()
    var lastUsed = DateBounds()
    /// Folders to search. Only absolute file URLs count; with none, nothing is
    /// searched; an empty scope would make Spotlight search the whole Mac.
    var scopes: [URL]
    var sort: SortOrder = .modifiedNewestFirst
    /// How many results are read at most. Reading happens on the main actor, so
    /// this bounds the work there (≈ 4 ms per 1,000 results).
    var maxResults: Int = 200

    /// The scopes Spotlight is given: absolute file URLs only.
    var searchScopes: [URL] {
        scopes.filter { $0.isFileURL && $0.path.hasPrefix("/") }
    }

    /// `query` with terms matched against names only.
    static func namesOnly(_ query: SpotlightQuery) -> SpotlightQuery {
        var copy = query
        copy.termMatch = .names
        return copy
    }

    /// Splits user text into search terms: whitespace separates terms, leading
    /// and trailing punctuation and symbols are dropped ("Rechnung," → "Rechnung",
    /// "*.pdf" → "pdf"; Spotlight would otherwise match them literally), inner
    /// ones are kept ("2026-08", "report.txt"). Duplicates (ignoring case) and
    /// terms that consist only of punctuation ("*") are removed.
    static func searchTerms(from text: String) -> [String] {
        let edges = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        var seen = Set<String>()
        var terms: [String] = []
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let term = String(word).trimmingCharacters(in: edges)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            terms.append(term)
        }
        return terms
    }
}

/// One Spotlight match with the attributes Orbit uses.
struct SpotlightItem: Sendable, Hashable {
    var path: String
    /// The name Finder shows (kMDItemDisplayName).
    var displayName: String
    /// The name on disk (kMDItemFSName).
    var fileSystemName: String
    /// Uniform Type Identifier, e.g. "com.adobe.pdf".
    var contentType: String?
    /// The content type and everything it conforms to.
    var contentTypeTree: [String]
    /// Localized kind, e.g. "PDF-Dokument" (kMDItemKind).
    var kindDescription: String?
    var modified: Date?
    var lastUsed: Date?
    var size: Int64?

    init(path: String, displayName: String? = nil, fileSystemName: String? = nil, contentType: String? = nil,
         contentTypeTree: [String] = [], kindDescription: String? = nil, modified: Date? = nil,
         lastUsed: Date? = nil, size: Int64? = nil) {
        let name = FilePath.lastComponent(path)
        self.path = path
        self.displayName = displayName ?? name
        self.fileSystemName = fileSystemName ?? name
        self.contentType = contentType
        self.contentTypeTree = contentTypeTree
        self.kindDescription = kindDescription
        self.modified = modified
        self.lastUsed = lastUsed
        self.size = size
    }

    /// A real folder (not a package such as an app or a Pages document).
    var isFolder: Bool {
        contentType == "public.folder" || contentTypeTree.contains("public.folder")
    }

    /// The later of last use and modification.
    var mostRecentDate: Date? {
        switch (lastUsed, modified) {
        case let (used?, modified?): max(used, modified)
        case let (used?, nil): used
        case let (nil, modified?): modified
        case (nil, nil): nil
        }
    }
}

/// What a Spotlight search found so far.
struct SpotlightResults: Sendable, Hashable {
    /// In the query's sort order; at most `maxResults`.
    var items: [SpotlightItem]
    /// All matches Spotlight reported (may exceed `items.count`).
    var totalCount: Int
    /// False while gathering (a progressive snapshot) or after a timeout.
    var isComplete: Bool

    static let none = SpotlightResults(items: [], totalCount: 0, isComplete: true)
}

/// Runs Spotlight searches. Live: `LiveSpotlight` (NSMetadataQuery); tests use
/// a mock. Instant search and the file tools share it.
protocol SpotlightQuerying: Sendable {
    /// Runs `query` until Spotlight has gathered every match or `timeout` has
    /// passed (then with what it found so far and `isComplete == false`), and
    /// stops it. Cancelling the calling task stops the query and throws
    /// `CancellationError`.
    func search(_ query: SpotlightQuery, timeout: Duration) async throws -> SpotlightResults

    /// Progressive results: a snapshot whenever Spotlight delivered a batch
    /// while gathering, then a final one (`isComplete`, or not after `timeout`),
    /// then the stream ends. Ending the iteration or cancelling the consuming
    /// task stops the query.
    func snapshots(of query: SpotlightQuery, timeout: Duration) -> AsyncThrowingStream<SpotlightResults, any Error>
}

extension SpotlightQuerying {
    /// Default: the last snapshot of `snapshots(of:timeout:)`.
    func search(_ query: SpotlightQuery, timeout: Duration) async throws -> SpotlightResults {
        var last = SpotlightResults(items: [], totalCount: 0, isComplete: false)
        for try await snapshot in snapshots(of: query, timeout: timeout) {
            last = snapshot
        }
        try Task.checkCancellation()
        return last
    }
}

/// Spotlight errors (the message is for the model).
enum SpotlightError: Error, Sendable, Hashable {
    /// NSMetadataQuery refused to start (e.g. Spotlight is unavailable).
    case couldNotStart
}
