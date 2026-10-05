import Foundation
import os

/// How `search_mail` searches: through Spotlight's index of Mail's message
/// files when Spotlight shows them to Orbit (fast, all mailboxes at once, and
/// words also match the message text), or by asking Mail with AppleScript
/// (always works, slower on big mailboxes, subjects and senders only).
enum MailSearchMode: String, Sendable, Hashable {
    case spotlight
    case appleScript

    /// Whether query words are also looked for in the message text.
    var searchesMessageText: Bool {
        self == .spotlight
    }
}

/// A mail search in Spotlight. Every value goes into the predicate as an
/// argument, never into its format.
struct MailSpotlightQuery: Sendable, Hashable {
    /// Bounds of the Date header (Mail's importer records no date received).
    var since: Date
    var until: Date
    /// Each must occur in the subject, a sender's name or a sender's address
    /// (anywhere, also inside words), or in the message text (from the start
    /// of a word; a phrase as its words in a row).
    var terms: [String]
    /// Each must start a word of the sender's name (Mail's importer records the
    /// address as the name of a sender without one); a single word may also
    /// start a word of the sender's address, unless the sender's address is
    /// one of `fromAddresses` (the rule of `MailText.isFrom`).
    var fromWords: [String]
    var fromAddresses: [String]
    /// Results read at most (reading happens on the main actor).
    var maxResults: Int = 500
}

/// One message file Spotlight found.
struct MailSpotlightItem: Sendable, Hashable {
    var path: String
    /// Mail's importer leaves reply prefixes ("Re:") out of it.
    var subject: String?
    var authors: [String]
    var authorAddresses: [String]
    /// The Date header.
    var date: Date?
    /// With angle brackets, as the importer records it.
    var messageID: String?
    var isLikelyJunk: Bool

    init(path: String, subject: String? = nil, authors: [String] = [], authorAddresses: [String] = [],
         date: Date? = nil, messageID: String? = nil, isLikelyJunk: Bool = false) {
        self.path = path
        self.subject = subject
        self.authors = authors
        self.authorAddresses = authorAddresses
        self.date = date
        self.messageID = messageID
        self.isLikelyJunk = isLikelyJunk
    }
}

struct MailSpotlightResults: Sendable, Hashable {
    /// Newest first; at most the query's `maxResults`.
    var items: [MailSpotlightItem]
    /// All matches Spotlight reported.
    var totalCount: Int
    /// False after a timeout.
    var isComplete: Bool
}

/// Spotlight for Mail's message files. Live: `LiveMailSpotlight` scoped to
/// ~/Library/Mail; tests use a mock (or the live one on the repository's
/// invented fixtures); restricted and fake-data sessions have none.
protocol MailSpotlightSearching: Sendable {
    /// Whether Spotlight shows Mail's messages to Orbit. Checked on first use
    /// with a query that stops at the first message and reads nothing of it;
    /// the answer is remembered for a while.
    func isAvailable() async -> Bool
    /// The last answer of `isAvailable()`; nil before the first check.
    var lastKnownAvailability: Bool? { get }
    func search(_ query: MailSpotlightQuery, timeout: Duration) async throws -> MailSpotlightResults
    /// Forgets the remembered answer, so the next `isAvailable()` asks
    /// Spotlight again (Settings → Permissions → "Check Again", e.g. after
    /// Full Disk Access was turned on).
    func forgetAvailability()
}

extension MailSpotlightSearching {
    func forgetAvailability() {}

    /// How `search_mail` searches now (checks Spotlight if needed). For the
    /// settings: shows only the mode, never counts or content.
    func searchMode() async -> MailSearchMode {
        await isAvailable() ? .spotlight : .appleScript
    }

    /// The mode found last; nil before the first check.
    var lastKnownSearchMode: MailSearchMode? {
        lastKnownAvailability.map { $0 ? .spotlight : .appleScript }
    }
}

/// No Spotlight mail search (DEBUG sessions with ORBIT_DEBUG_FILE_SCOPE or
/// fake personal data, tests): `search_mail` asks Mail.
struct UnavailableMailSpotlight: MailSpotlightSearching {
    func isAvailable() async -> Bool { false }
    var lastKnownAvailability: Bool? { false }
    func search(_ query: MailSpotlightQuery, timeout: Duration) async throws -> MailSpotlightResults {
        MailSpotlightResults(items: [], totalCount: 0, isComplete: true)
    }
}

/// The predicate of a mail search. Pure.
///
/// Verified with `mdfind -onlyin` and NSMetadataQuery on the fixtures (macOS
/// 27, Mail's importer, 2026-10-03):
/// - `CONTAINS[cd]` (`== "*term*"cd`) matches inside words, ignoring case and
///   accents, also in the multi-valued kMDItemAuthors and
///   kMDItemAuthorEmailAddresses; `==[c]` matches a whole address ignoring
///   case; kMDItemContentCreationDate is the Date header.
/// - kMDItemTextContent holds the message text (it cannot be read back, only
///   searched): `BEGINSWITH[cdw]` (`== "term*"cdw`) matches words of the text
///   from their start, ignoring case and accents ("quok" and "QUOKKA" find
///   "Quokka-Entwürfe", "manteln" finds "Mänteln", "grusse" finds "Grüße"),
///   but not inside a word ("okka" finds nothing); a phrase matches its words
///   in a row ("Projekt Orb" finds "Projekt Orbit", "Orbit Projekt" nothing);
///   `*`, `?` and quotes in a term match literally. Only the body is in it
///   (words that occur only in the sender or the subject are not), of a
///   multipart/alternative message the HTML part (a word only in its plain
///   part is not found), and nothing of a message file with CRLF line endings
///   (Mail's store writes LF; checked with invented probe messages: LF files,
///   also .partial.emlx, are indexed). `CONTAINS[cd]` would find words inside
///   words in the text too, but it is slow on large indexes.
/// - kMDItemAuthors holds the sender's display name, decoded and without
///   quotes ("Telekom Deutschland", "Lisa Muster" from an encoded word), and
///   for a sender without one the address as written ("noreply@telekom.example",
///   "<max.weber@…>"; `mdimport -t` on invented messages, 2026-10-04);
///   kMDItemAuthorEmailAddresses the bare address. `BEGINSWITH[cdw]` splits
///   both into words at spaces and punctuation, "." and "@" included: "lisa"
///   and "LISA" find "Lisa Beispiel", "isa" does not; "beispiel", "firma" and
///   "telekom.example" find "lisa.beispiel@firma.example" and
///   "rechnung@telekom.example", "isa.beispiel" does not (2026-10-04).
enum MailSpotlightPredicate {
    static let contentType = "com.apple.mail.emlx"
    static let subject = "kMDItemSubject"
    static let authors = "kMDItemAuthors"
    static let authorAddresses = "kMDItemAuthorEmailAddresses"
    static let textContent = "kMDItemTextContent"
    static let date = "kMDItemContentCreationDate"
    static let messageID = "kMDItemIdentifier"
    static let likelyJunk = "kMDItemIsLikelyJunk"

    static func build(_ query: MailSpotlightQuery) -> NSPredicate {
        var conditions = [
            isMessage,
            NSPredicate(format: "%K >= %@", argumentArray: [date, query.since as NSDate]),
            NSPredicate(format: "%K <= %@", argumentArray: [date, query.until as NSDate]),
        ]
        for term in query.terms {
            conditions.append(NSCompoundPredicate(orPredicateWithSubpredicates: [
                contains(subject, term), contains(authors, term), contains(authorAddresses, term),
                wordPrefix(textContent, term),
            ]))
        }
        var senders: [NSPredicate] = []
        if !query.fromWords.isEmpty {
            // Every word starts a word of the name; for a sender without one, the importer
            // records the address as its name, so its address counts too. A single word may
            // also start a word of the address (companies by their domain); two or more never
            // match another person's address.
            senders.append(all(query.fromWords.map { wordPrefix(authors, $0) }))
            if query.fromWords.count == 1 {
                senders.append(wordPrefix(authorAddresses, query.fromWords[0]))
            }
        }
        senders += query.fromAddresses.map { NSPredicate(format: "%K ==[c] %@", argumentArray: [authorAddresses, $0]) }
        if !senders.isEmpty {
            conditions.append(senders.count == 1 ? senders[0] : NSCompoundPredicate(orPredicateWithSubpredicates: senders))
        }
        return NSCompoundPredicate(andPredicateWithSubpredicates: conditions)
    }

    private static func all(_ predicates: [NSPredicate]) -> NSPredicate {
        predicates.count == 1 ? predicates[0] : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    /// Any message file.
    static var isMessage: NSPredicate {
        NSPredicate(format: "%K == %@", argumentArray: [NSMetadataItemContentTypeKey, contentType])
    }

    private static func contains(_ attribute: String, _ value: String) -> NSPredicate {
        NSPredicate(format: "%K CONTAINS[cd] %@", argumentArray: [attribute, value])
    }

    private static func wordPrefix(_ attribute: String, _ value: String) -> NSPredicate {
        NSPredicate(format: "%K BEGINSWITH[cdw] %@", argumentArray: [attribute, value])
    }

    static var sortDescriptors: [NSSortDescriptor] {
        [NSSortDescriptor(key: date, ascending: false)]
    }
}

/// `MailSpotlightSearching` with NSMetadataQuery in one folder: Mail's store
/// (~/Library/Mail) in the app. Queries run on the main actor like
/// `LiveSpotlight`'s; reading is bounded by `maxResults`. Logs record whether
/// Spotlight works and durations, never counts of messages, paths or values.
final class LiveMailSpotlight: MailSpotlightSearching, Sendable {
    /// How long an answer is kept before Spotlight is asked again: "not
    /// available" briefly (the user may grant Full Disk Access meanwhile),
    /// "available" longer (access can be taken away).
    static let unavailableRecheckInterval: TimeInterval = 600
    static let availableRecheckInterval: TimeInterval = 3_600
    static let probeTimeout: Duration = .seconds(3)

    /// Mail's store of the user whose home folder is `home`.
    static func mailStore(home: String) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Mail", isDirectory: true)
    }

    let scope: URL
    private let state = OSAllocatedUnfairLock<(available: Bool?, checkedAt: Date?)>(initialState: (nil, nil))

    init(scope: URL) {
        self.scope = scope
    }

    var lastKnownAvailability: Bool? {
        state.withLock { $0.available }
    }

    func forgetAvailability() {
        state.withLock { $0 = (nil, nil) }
    }

    func isAvailable() async -> Bool {
        let now = Date()
        let cached = state.withLock { state -> Bool? in
            guard let available = state.available, let checkedAt = state.checkedAt else { return nil }
            let interval = available ? Self.availableRecheckInterval : Self.unavailableRecheckInterval
            return now.timeIntervalSince(checkedAt) < interval ? available : nil
        }
        if let cached { return cached }
        let probe = try? await run(nil, timeout: Self.probeTimeout)
        // A check that was cancelled says nothing about Spotlight: not remembered.
        guard !Task.isCancelled else { return false }
        let available = (probe?.totalCount ?? 0) > 0
        state.withLock { $0 = (available, now) }
        Log.tools.info("Mail search through Spotlight: \(available ? "available" : "not available", privacy: .public)")
        return available
    }

    func search(_ query: MailSpotlightQuery, timeout: Duration) async throws -> MailSpotlightResults {
        try await run(query, timeout: timeout)
    }

    /// Runs `request` (nil: the probe, which stops at the first message).
    private func run(_ request: MailSpotlightQuery?, timeout: Duration) async throws -> MailSpotlightResults {
        let (stream, continuation) = AsyncThrowingStream<MailSpotlightResults, any Error>.makeStream()
        let session = MailMetadataSession(request: request, scope: scope, timeout: timeout, continuation: continuation)
        continuation.onTermination = { _ in
            Task { @MainActor in session.cancel() }
        }
        Task { @MainActor in session.start() }
        var last = MailSpotlightResults(items: [], totalCount: 0, isComplete: false)
        for try await results in stream {
            last = results
        }
        try Task.checkCancellation()
        return last
    }
}

/// One running NSMetadataQuery over message files. Main-actor bound;
/// finishes exactly once (gathered, first match of a probe, timed out, failed
/// or cancelled) and then stops the query.
@MainActor
private final class MailMetadataSession {
    static let attributes = [
        MailSpotlightPredicate.subject, MailSpotlightPredicate.authors, MailSpotlightPredicate.authorAddresses,
        MailSpotlightPredicate.date, MailSpotlightPredicate.messageID, MailSpotlightPredicate.likelyJunk,
    ]

    private let request: MailSpotlightQuery?
    private let scope: URL
    private let timeout: Duration
    private let continuation: AsyncThrowingStream<MailSpotlightResults, any Error>.Continuation
    private var query: NSMetadataQuery?
    private var observers: [any NSObjectProtocol] = []
    private var timer: Task<Void, Never>?
    private var isFinished = false
    private var startedAt = ContinuousClock.now

    nonisolated init(request: MailSpotlightQuery?, scope: URL, timeout: Duration,
                     continuation: AsyncThrowingStream<MailSpotlightResults, any Error>.Continuation) {
        self.request = request
        self.scope = scope
        self.timeout = timeout
        self.continuation = continuation
    }

    func start() {
        guard !isFinished else { return }
        guard scope.isFileURL, scope.path.hasPrefix("/") else {
            finish(MailSpotlightResults(items: [], totalCount: 0, isComplete: true))
            return
        }
        let query = NSMetadataQuery()
        query.operationQueue = .main
        query.searchScopes = [scope]
        query.predicate = request.map(MailSpotlightPredicate.build) ?? MailSpotlightPredicate.isMessage
        query.sortDescriptors = MailSpotlightPredicate.sortDescriptors
        query.valueListAttributes = Self.attributes
        if request == nil {
            query.notificationBatchingInterval = 0.1
        }
        self.query = query
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinishGathering() }
        })
        if request == nil {
            observers.append(center.addObserver(forName: .NSMetadataQueryGatheringProgress, object: query,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didMakeProgress() }
            })
        }
        startedAt = .now
        guard query.start() else {
            Log.tools.error("Spotlight mail query did not start")
            finish(nil, error: SpotlightError.couldNotStart)
            return
        }
        guard !isFinished else { return }
        let timeout = timeout
        timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.didTimeOut()
        }
    }

    func cancel() {
        finish(nil)
    }

    /// A probe needs one message only.
    private func didMakeProgress() {
        guard !isFinished, let query, query.resultCount > 0 else { return }
        finish(MailSpotlightResults(items: [], totalCount: 1, isComplete: false))
    }

    private func didFinishGathering() {
        guard !isFinished else { return }
        let results = request == nil
            ? MailSpotlightResults(items: [], totalCount: min(query?.resultCount ?? 0, 1), isComplete: true)
            : snapshot(isComplete: true)
        log("finished")
        finish(results)
    }

    private func didTimeOut() {
        guard !isFinished else { return }
        log("timed out")
        finish(request == nil ? MailSpotlightResults(items: [], totalCount: 0, isComplete: false) : snapshot(isComplete: false))
    }

    private func finish(_ results: MailSpotlightResults?, error: (any Error)? = nil) {
        guard !isFinished else { return }
        isFinished = true
        timer?.cancel()
        timer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        query?.stop()
        query = nil
        if let results { continuation.yield(results) }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    /// Reads at most `maxResults` results and sorts them newest first:
    /// Spotlight's own order is not reliable while files are being re-imported
    /// (seen on the fixtures: updated items came last).
    private func snapshot(isComplete: Bool) -> MailSpotlightResults {
        guard let query, let request else { return MailSpotlightResults(items: [], totalCount: 0, isComplete: isComplete) }
        query.disableUpdates()
        defer { query.enableUpdates() }
        let total = query.resultCount
        let count = min(total, max(0, request.maxResults))
        var items: [MailSpotlightItem] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            guard let result = query.result(at: index) as? NSMetadataItem,
                  let path = result.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            func value<T>(_ attribute: String, as type: T.Type = T.self) -> T? {
                query.value(ofAttribute: attribute, forResultAt: index) as? T
            }
            items.append(MailSpotlightItem(
                path: path,
                subject: value(MailSpotlightPredicate.subject),
                authors: value(MailSpotlightPredicate.authors) ?? [],
                authorAddresses: value(MailSpotlightPredicate.authorAddresses) ?? [],
                date: value(MailSpotlightPredicate.date),
                messageID: value(MailSpotlightPredicate.messageID),
                isLikelyJunk: value(MailSpotlightPredicate.likelyJunk, as: NSNumber.self)?.boolValue ?? false
            ))
        }
        items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        return MailSpotlightResults(items: items, totalCount: total, isComplete: isComplete)
    }

    private func log(_ event: String) {
        let milliseconds = Int((ContinuousClock.now - startedAt) / .milliseconds(1))
        Log.tools.debug("Spotlight mail query \(event, privacy: .public) after \(milliseconds) ms")
    }
}
