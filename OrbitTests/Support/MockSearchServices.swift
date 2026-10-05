import Foundation
import os
@testable import Orbit

/// A fixed app list instead of scanning the app folders.
final class FakeAppIndex: AppIndexing, Sendable {
    private struct State: Sendable {
        var apps: [IndexedApp]
        var onChange: (@MainActor @Sendable () -> Void)?
        var starts = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ apps: [IndexedApp] = []) {
        state = OSAllocatedUnfairLock(initialState: State(apps: apps))
    }

    var apps: [IndexedApp] { state.withLock { $0.apps } }
    var startCount: Int { state.withLock { $0.starts } }

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        state.withLock { state in
            state.onChange = onChange
            state.starts += 1
        }
    }

    /// Replaces the apps like a finished rescan and tells instant search.
    @MainActor
    func replace(with apps: [IndexedApp]) {
        let onChange = state.withLock { state in
            state.apps = apps
            return state.onChange
        }
        onChange?()
    }
}

extension IndexedApp {
    /// An app that exists only in tests.
    static func fake(_ name: String, aliases: [String] = [], folder: String = "/Applications-Orbit-Test") -> IndexedApp {
        IndexedApp(path: "\(folder)/\(name).app", name: name, aliases: aliases)
    }
}

/// Contacts from a list (never the Contacts framework): those whose name
/// matches, ranked like the live search.
final class MockContactSearch: ContactSearching, Sendable {
    private let state: OSAllocatedUnfairLock<(contacts: [ContactHit], queries: [String])>

    init(_ contacts: [ContactHit] = []) {
        state = OSAllocatedUnfairLock(initialState: (contacts, []))
    }

    var queries: [String] { state.withLock { $0.queries } }

    func search(_ text: String, limit: Int) async throws -> [ContactHit] {
        let contacts = state.withLock { state in
            state.queries.append(text)
            return state.contacts
        }
        let query = FuzzyMatcher.Query(text)
        let matching = contacts.filter { FuzzyMatcher.match(query, in: FuzzyMatcher.Name($0.name)) != nil }
        return ContactRanking.rank(matching, query: query, limit: limit)
    }
}

/// Records what instant search would have opened.
final class MockSearchOpener: SearchResultOpening, Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (apps: [URL](), urls: [URL]()))

    var openedApps: [URL] { state.withLock { $0.apps } }
    var openedURLs: [URL] { state.withLock { $0.urls } }

    func openApplication(at url: URL) async throws {
        state.withLock { $0.apps.append(url) }
    }

    func open(_ url: URL) async throws {
        state.withLock { $0.urls.append(url) }
    }
}

final class InMemoryLaunchCounts: LaunchCountStoring, Sendable {
    private let counts: OSAllocatedUnfairLock<[String: Int]>

    init(_ counts: [String: Int] = [:]) {
        self.counts = OSAllocatedUnfairLock(initialState: counts)
    }

    func launchCounts() -> [String: Int] {
        counts.withLock { $0 }
    }

    func recordLaunch(ofAppAt path: String) {
        counts.withLock { $0[path, default: 0] += 1 }
    }
}

/// A debounce clock the test advances by hand: `sleep` waits until `advance()`
/// and throws `CancellationError` when its task is cancelled.
final class ManualClock: Sendable {
    private struct State: Sendable {
        var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
        /// Sleeps cancelled before they started waiting.
        var cancelled: Set<UUID> = []
        var requests: [Duration] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Sleeps waiting for `advance()`.
    var pendingCount: Int { state.withLock { $0.waiting.count } }
    /// Every duration asked for, in order.
    var requests: [Duration] { state.withLock { $0.requests } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let isCancelled = state.withLock { state in
                    state.requests.append(duration)
                    if state.cancelled.remove(id) != nil { return true }
                    state.waiting[id] = continuation
                    return false
                }
                if isCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = state.withLock { state in
                guard let continuation = state.waiting.removeValue(forKey: id) else {
                    state.cancelled.insert(id)
                    return nil as CheckedContinuation<Void, any Error>?
                }
                return continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Ends every pending sleep.
    func advance() {
        let continuations = state.withLock { state in
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        for continuation in continuations {
            continuation.resume()
        }
    }
}

/// File search the test answers by hand: every search waits until the test
/// yields snapshots for it; ended searches are recorded.
final class ScriptedFileSearch: FileNameSearching, Sendable {
    private struct State: Sendable {
        var searches: [(text: String, continuation: AsyncThrowingStream<FileSearchSnapshot, any Error>.Continuation)] = []
        var cancelled: [String] = []
        /// Answers every search at once with a final snapshot.
        var answer: (@Sendable (String) -> [FileHit])?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(answer: (@Sendable (String) -> [FileHit])? = nil) {
        state.withLock { $0.answer = answer }
    }

    var queries: [String] { state.withLock { $0.searches.map(\.text) } }
    /// Searches stopped before they finished (a newer query or `clear()`).
    var cancelledQueries: [String] { state.withLock { $0.cancelled } }

    func search(_ text: String) -> AsyncThrowingStream<FileSearchSnapshot, any Error> {
        let (stream, continuation) = AsyncThrowingStream<FileSearchSnapshot, any Error>.makeStream()
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                self?.state.withLock { $0.cancelled.append(text) }
            }
        }
        let answer = state.withLock { state in
            state.searches.append((text, continuation))
            return state.answer
        }
        if let answer {
            continuation.yield(FileSearchSnapshot(hits: answer(text), isFinal: true))
            continuation.finish()
        }
        return stream
    }

    /// Sends a snapshot to the latest search; a final one ends it.
    func send(_ hits: [FileHit], isFinal: Bool) {
        guard let continuation = state.withLock({ $0.searches.last?.continuation }) else { return }
        continuation.yield(FileSearchSnapshot(hits: hits, isFinal: isFinal))
        if isFinal { continuation.finish() }
    }
}

extension InstantSearchDependencies {
    /// Instant search on fakes with a hand-driven debounce.
    static func fake(apps: FakeAppIndex = FakeAppIndex(), files: any FileNameSearching = ScriptedFileSearch(answer: { _ in [] }),
                     contacts: MockContactSearch = MockContactSearch(), opener: MockSearchOpener = MockSearchOpener(),
                     launchCounts: InMemoryLaunchCounts = InMemoryLaunchCounts(), clock: ManualClock = ManualClock(),
                     homeDirectory: String = "/Users/orbit-test") -> InstantSearchDependencies {
        InstantSearchDependencies(apps: apps, files: files, contacts: contacts, opener: opener, launchCounts: launchCounts,
                                  homeDirectory: homeDirectory, sleep: { try await clock.sleep(for: $0) })
    }
}

enum SearchTestSupport {
    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    @MainActor
    static func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return condition()
    }
}
