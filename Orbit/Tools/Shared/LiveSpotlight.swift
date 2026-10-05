import Foundation
import os

/// `SpotlightQuerying` with NSMetadataQuery.
///
/// A query is created, started, observed and stopped on the main actor; its
/// notifications arrive on the main queue (`operationQueue = .main`), so no run
/// loop needs to spin. Only reading results happens there: at most
/// `maxResults`, with updates disabled while reading. That stays cheap because
/// every attribute except the path comes with the results
/// (`valueListAttributes`): measured ≈ 0.3 ms for 50 and ≈ 4 ms for 1,000
/// results, against ≈ 80 ms for 50 when attributes are fetched one by one.
struct LiveSpotlight: SpotlightQuerying {
    func search(_ query: SpotlightQuery, timeout: Duration) async throws -> SpotlightResults {
        var last = SpotlightResults(items: [], totalCount: 0, isComplete: false)
        for try await snapshot in stream(query, timeout: timeout, progressive: false) {
            last = snapshot
        }
        try Task.checkCancellation()
        return last
    }

    func snapshots(of query: SpotlightQuery, timeout: Duration) -> AsyncThrowingStream<SpotlightResults, any Error> {
        stream(query, timeout: timeout, progressive: true)
    }

    private func stream(_ query: SpotlightQuery, timeout: Duration,
                        progressive: Bool) -> AsyncThrowingStream<SpotlightResults, any Error> {
        let (stream, continuation) = AsyncThrowingStream<SpotlightResults, any Error>.makeStream()
        guard !query.searchScopes.isEmpty else {
            continuation.yield(.none)
            continuation.finish()
            return stream
        }
        let session = SpotlightSession(request: query, timeout: timeout, progressive: progressive,
                                       continuation: continuation)
        continuation.onTermination = { _ in
            Task { @MainActor in session.cancel() }
        }
        Task { @MainActor in session.start() }
        return stream
    }
}

/// One running NSMetadataQuery. Main-actor bound; finishes exactly once
/// (gathered, timed out, failed or cancelled) and then stops the query.
@MainActor
private final class SpotlightSession {
    /// Everything read with the results, so reading needs no further requests.
    static let attributes = [
        NSMetadataItemDisplayNameKey, NSMetadataItemFSNameKey, NSMetadataItemContentTypeKey,
        NSMetadataItemContentTypeTreeKey, NSMetadataItemKindKey, NSMetadataItemContentModificationDateKey,
        NSMetadataItemLastUsedDateKey, NSMetadataItemFSSizeKey,
    ]

    private let request: SpotlightQuery
    private let timeout: Duration
    private let progressive: Bool
    private let continuation: AsyncThrowingStream<SpotlightResults, any Error>.Continuation
    private var query: NSMetadataQuery?
    private var observers: [any NSObjectProtocol] = []
    private var timer: Task<Void, Never>?
    private var isFinished = false
    private var startedAt = ContinuousClock.now

    nonisolated init(request: SpotlightQuery, timeout: Duration, progressive: Bool,
                     continuation: AsyncThrowingStream<SpotlightResults, any Error>.Continuation) {
        self.request = request
        self.timeout = timeout
        self.progressive = progressive
        self.continuation = continuation
    }

    func start() {
        guard !isFinished else { return }
        let query = NSMetadataQuery()
        query.operationQueue = .main
        query.searchScopes = request.searchScopes
        query.predicate = SpotlightPredicate.build(request)
        query.sortDescriptors = SpotlightPredicate.sortDescriptors(for: request.sort)
        query.valueListAttributes = Self.attributes
        if progressive {
            query.notificationBatchingInterval = 0.05
        }
        self.query = query

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didFinishGathering() }
        })
        if progressive {
            observers.append(center.addObserver(forName: .NSMetadataQueryGatheringProgress, object: query,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didMakeProgress() }
            })
        }
        startedAt = .now
        guard query.start() else {
            Log.search.error("Spotlight query did not start")
            finish(nil, error: SpotlightError.couldNotStart)
            return
        }
        // Gathering may already have finished during start().
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

    private func didMakeProgress() {
        guard !isFinished, let snapshot = snapshot(isComplete: false), !snapshot.items.isEmpty else { return }
        continuation.yield(snapshot)
    }

    private func didFinishGathering() {
        guard !isFinished else { return }
        let results = snapshot(isComplete: true) ?? .none
        log("finished", results)
        finish(results)
    }

    private func didTimeOut() {
        guard !isFinished else { return }
        let results = snapshot(isComplete: false) ?? SpotlightResults(items: [], totalCount: 0, isComplete: false)
        log("timed out", results)
        finish(results)
    }

    private func finish(_ results: SpotlightResults?, error: (any Error)? = nil) {
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
        if let results {
            continuation.yield(results)
        }
        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
    }

    /// Reads at most `maxResults` results, in the query's sort order.
    private func snapshot(isComplete: Bool) -> SpotlightResults? {
        guard let query else { return nil }
        query.disableUpdates()
        defer { query.enableUpdates() }
        let total = query.resultCount
        let count = min(total, max(0, request.maxResults))
        var items: [SpotlightItem] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            guard let result = query.result(at: index) as? NSMetadataItem,
                  let path = result.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            func value<T>(_ attribute: String, as type: T.Type = T.self) -> T? {
                query.value(ofAttribute: attribute, forResultAt: index) as? T
            }
            items.append(SpotlightItem(
                path: path,
                displayName: value(NSMetadataItemDisplayNameKey),
                fileSystemName: value(NSMetadataItemFSNameKey),
                contentType: value(NSMetadataItemContentTypeKey),
                contentTypeTree: value(NSMetadataItemContentTypeTreeKey) ?? [],
                kindDescription: value(NSMetadataItemKindKey),
                modified: value(NSMetadataItemContentModificationDateKey),
                lastUsed: value(NSMetadataItemLastUsedDateKey),
                size: value(NSMetadataItemFSSizeKey, as: NSNumber.self)?.int64Value
            ))
        }
        return SpotlightResults(items: items, totalCount: total, isComplete: isComplete)
    }

    private func log(_ event: String, _ results: SpotlightResults) {
        let milliseconds = Int((ContinuousClock.now - startedAt) / .milliseconds(1))
        Log.search.debug("Spotlight query \(event, privacy: .public) after \(milliseconds) ms: \(results.totalCount) matches, \(results.items.count) read")
    }
}
