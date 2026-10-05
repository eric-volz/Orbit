import Foundation
import os

/// An app instant search can open.
struct IndexedApp: Sendable, Hashable, Identifiable {
    /// The bundle's path as found (a symlink stays a symlink).
    let path: String
    /// The name Finder shows (localized); shown in the results.
    let name: String
    /// Every name the app is found by, prepared for matching: the shown one,
    /// the bundle names (localized and English) and the file name.
    let matchNames: [FuzzyMatcher.Name]

    var id: String { path }

    init(path: String, name: String, aliases: [String] = []) {
        self.path = path
        self.name = name
        var seen = Set<[Unicode.Scalar]>()
        matchNames = ([name] + aliases).map(FuzzyMatcher.Name.init).filter { !$0.isEmpty && seen.insert($0.scalars).inserted }
    }

    /// The best match of any name; a match on another name than the shown one
    /// (e.g. "Maps" for Karten) ranks just below an equal match on the shown name.
    func match(_ query: FuzzyMatcher.Query) -> FuzzyMatcher.Match? {
        var best: FuzzyMatcher.Match?
        for (index, name) in matchNames.enumerated() {
            guard var match = FuzzyMatcher.match(query, in: name) else { continue }
            if index > 0 { match.score *= 0.98 }
            if best.map({ match > $0 }) ?? true { best = match }
        }
        return best
    }
}

/// The apps instant search knows. Live: `LiveAppIndex`; tests use a fixed list.
protocol AppIndexing: Sendable {
    /// The apps found by the last scan (empty until the first one finished).
    /// Cheap: returns the stored list.
    var apps: [IndexedApp] { get }

    /// Starts the first scan (off the main actor) and watching for changes.
    /// `onChange` runs on the main actor after every scan. Later calls do nothing.
    func start(onChange: @escaping @MainActor @Sendable () -> Void)
}

/// Where and how the app index looks.
struct AppIndexConfiguration: Sendable, Hashable {
    /// Folders whose apps are indexed, also those one folder deeper ("Utilities"),
    /// never inside bundles. Folders that do not exist (yet) are watched anyway.
    var folders: [String]
    /// App bundles indexed on their own (Finder).
    var singleApps: [String] = []
    /// Languages for localized bundle names, most preferred first; English is always added.
    var languages: [String]
    /// Watch the folders with FSEvents and scan again after changes.
    var watchesFolders = true
    /// FSEvents latency: changes are reported in batches this far apart.
    var eventLatency: TimeInterval = 0.5
    /// Quiet time after the last change before the index scans again.
    var rescanDelay: Duration = .seconds(1)

    /// /Applications, /System/Applications and ~/Applications (each with its
    /// subfolders such as Utilities) and Finder. With a debug file scope
    /// (`restriction`): /System/Applications and the apps in that folder only;
    /// with an invalid one only /System/Applications.
    static func standard(homeDirectory: String, restriction: String?, languages: [String]) -> AppIndexConfiguration {
        if let restriction {
            let folders = ["/System/Applications"] + (restriction.hasPrefix("/") ? [restriction] : [])
            return AppIndexConfiguration(folders: folders, languages: languages)
        }
        return AppIndexConfiguration(
            folders: ["/Applications", "/System/Applications", FilePath.normalize(homeDirectory + "/Applications")],
            singleApps: ["/System/Library/CoreServices/Finder.app"],
            languages: languages
        )
    }

    /// Orbit's language first, then the user's preferred languages (up to
    /// three), then English, so apps are found by the names the user sees in
    /// Orbit and in Finder and by their names in the user's other languages
    /// ("Rechner" for Calculator on an English Mac that lists German too).
    static func preferredLanguages(own: [String] = Locale.preferredLanguages,
                                   system: [String] = systemLanguages()) -> [String] {
        var seen = Set<String>()
        return (own.prefix(1) + system.prefix(3) + ["en"]).filter { seen.insert($0).inserted }
    }

    /// The languages set in System Settings (Orbit's own choice may differ).
    static func systemLanguages() -> [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? []
    }
}

/// The apps in the configured folders, scanned off the main actor at start and
/// again after changes (FSEvents, debounced). Icons are not part of the index;
/// the UI loads them.
final class LiveAppIndex: AppIndexing {
    let configuration: AppIndexConfiguration
    private let displayName: @Sendable (String) -> String
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State: Sendable {
        var apps: [IndexedApp] = []
        var isStarted = false
        var isStopped = false
        var scan: Task<Void, Never>?
        var watcher: FolderWatcher?
        var onChange: (@MainActor @Sendable () -> Void)?
    }

    /// `displayName`: the name Finder shows for a bundle path.
    init(configuration: AppIndexConfiguration,
         displayName: @escaping @Sendable (String) -> String = { FileManager.default.displayName(atPath: $0) }) {
        self.configuration = configuration
        self.displayName = displayName
    }

    deinit {
        stop()
    }

    var apps: [IndexedApp] {
        state.withLock { $0.apps }
    }

    func start(onChange: @escaping @MainActor @Sendable () -> Void) {
        let isFirstStart = state.withLock { state in
            guard !state.isStarted else { return false }
            state.isStarted = true
            state.onChange = onChange
            return true
        }
        guard isFirstStart else { return }
        if configuration.watchesFolders {
            let delay = configuration.rescanDelay
            let watcher = FolderWatcher(paths: configuration.folders, latency: configuration.eventLatency) { [weak self] in
                self?.scheduleScan(after: delay)
            }
            if watcher == nil {
                Log.search.error("App folders could not be watched; the app index updates at the next launch")
            }
            state.withLock { $0.watcher = watcher }
        }
        scheduleScan(after: .zero)
    }

    /// Stops watching and any pending scan, for good.
    func stop() {
        let (watcher, scan) = state.withLock { state in
            defer {
                state.isStopped = true
                state.watcher = nil
                state.scan = nil
            }
            return (state.watcher, state.scan)
        }
        watcher?.stop()
        scan?.cancel()
    }

    /// Scans after `delay`, replacing a scan that is waiting or running.
    private func scheduleScan(after delay: Duration) {
        let configuration = configuration
        let displayName = displayName
        let task = Task.detached(priority: .utility) { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            let start = ContinuousClock.now
            guard let apps = AppBundleScanner.scan(configuration, displayName: displayName), let self else { return }
            let onChange = self.state.withLock { state in
                state.apps = apps
                return state.onChange
            }
            let milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
            Log.search.info("App index: \(apps.count) apps in \(milliseconds) ms")
            if let onChange {
                await onChange()
            }
        }
        let previous = state.withLock { state -> Task<Void, Never>? in
            guard !state.isStopped else { return task }
            defer { state.scan = task }
            return state.scan
        }
        previous?.cancel()
    }
}
