import Foundation
import os

/// How often the user opened each app from instant search; frequently opened
/// apps rank higher (`AppRanking`). Stores app paths and counts only, never
/// files, contacts or what was typed.
protocol LaunchCountStoring: Sendable {
    /// Launches per app path.
    func launchCounts() -> [String: Int]

    func recordLaunch(ofAppAt path: String)
}

/// Launch counts in UserDefaults, bounded: at most `maxApps` apps (the least
/// launched are dropped, never the one just launched) and `maxLaunches` per app.
final class LaunchCounts: LaunchCountStoring, @unchecked Sendable {
    static let defaultsKey = "instantSearchLaunchCounts"
    static let maxApps = 100
    static let maxLaunches = 1_000

    // Only used while holding `cache`'s lock (UserDefaults is not marked Sendable).
    private let defaults: UserDefaults
    /// Loaded on first use; afterwards the source of truth, written through.
    private let cache = OSAllocatedUnfairLock<[String: Int]?>(initialState: nil)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func launchCounts() -> [String: Int] {
        cache.withLock { cache in
            let counts = cache ?? load()
            cache = counts
            return counts
        }
    }

    func recordLaunch(ofAppAt path: String) {
        let path = FilePath.normalize(path)
        guard Self.isAppPath(path) else { return }
        cache.withLock { cache in
            var counts = cache ?? load()
            counts[path] = min((counts[path] ?? 0) + 1, Self.maxLaunches)
            counts = Self.bounded(counts, keeping: path)
            cache = counts
            defaults.set(counts, forKey: Self.defaultsKey)
        }
    }

    /// Keeps `keeping` and the most launched other apps, `maxApps` in all
    /// (among equal counts the alphabetically first).
    static func bounded(_ counts: [String: Int], keeping: String? = nil) -> [String: Int] {
        guard counts.count > maxApps else { return counts }
        let ranked = counts.sorted { lhs, rhs in
            if (lhs.key == keeping) != (rhs.key == keeping) { return lhs.key == keeping }
            return lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }
        return Dictionary(uniqueKeysWithValues: ranked.prefix(maxApps).map { ($0.key, $0.value) })
    }

    static func isAppPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.lowercased().hasSuffix(".app")
    }

    /// The stored counts; only app paths with positive counts survive an edited value.
    private func load() -> [String: Int] {
        var counts: [String: Int] = [:]
        for (path, value) in defaults.dictionary(forKey: Self.defaultsKey) ?? [:] {
            guard Self.isAppPath(path), let count = value as? Int, count > 0 else { continue }
            counts[path] = min(count, Self.maxLaunches)
        }
        return Self.bounded(counts)
    }
}
