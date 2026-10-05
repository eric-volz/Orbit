import Foundation

/// The app tools: open_app, open_url and get_frontmost_context, in this order in Settings too.
enum AppTools {
    static func all(context: AppToolContext) -> [any Tool] {
        [OpenAppTool(context: context), OpenURLTool(context: context), GetFrontmostContextTool(context: context)]
    }
}

/// What the app tools share: the instant-search app index, opening apps and
/// links, the launch counts of instant search (to order candidates) and the
/// context capture, all injected, so tests and the DEBUG fake-data mode open
/// nothing and read no other app.
struct AppToolContext: Sendable {
    var apps: any AppIndexing
    var launcher: any AppLaunching
    var launchCounts: any LaunchCountStoring
    var frontmost: any FrontmostContextCapturing
    /// How long `open_app` waits for the first scan of the app folders (right after launch).
    var indexWait: Duration = .seconds(3)

    /// The installed apps; waits up to `indexWait` while the first scan runs.
    func installedApps() async -> [IndexedApp] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: indexWait)
        var apps = self.apps.apps
        while apps.isEmpty, clock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
            apps = self.apps.apps
        }
        return apps
    }
}

extension AppToolContext {
    /// The app tools' context on these services.
    init(services: AppServices) {
        self.init(apps: services.appIndex, launcher: services.appLauncher, launchCounts: services.launchCounts,
                  frontmost: services.frontmostContext)
    }
}

/// Opens apps and links for the agent (`open_app`, `open_url`). Live: the
/// opener instant search uses (NSWorkspace on the main actor); restricted
/// debug sessions open nothing, the DEBUG fake-data mode only records (also
/// while instant search still opens what the user picks), and tests use a
/// recorder.
protocol AppLaunching: Sendable {
    /// Launches the app, or brings it to the front when it runs.
    func openApplication(at url: URL) async throws
    /// Opens an http(s) link in the default browser or a mailto link in the
    /// default mail app (`LinkPolicy` decided that it may be opened).
    func openLink(_ url: URL) async throws
}

/// The agent's apps and links through instant search's opener.
struct LiveAppLauncher: AppLaunching {
    var opener: any SearchResultOpening = LiveSearchResultOpener()

    func openApplication(at url: URL) async throws {
        try await opener.openApplication(at: url)
    }

    func openLink(_ url: URL) async throws {
        try await opener.open(url)
    }
}

/// Opens nothing (DEBUG sessions restricted with ORBIT_DEBUG_FILE_SCOPE, and
/// the default of `AppServices`).
struct DisabledAppLauncher: AppLaunching {
    static let message = "Opening apps and links is not available in this debug session (ORBIT_DEBUG_FILE_SCOPE is set without ORBIT_DEBUG_FAKE_PERSONAL_DATA)."

    func openApplication(at url: URL) async throws {
        throw ToolError.unavailable(Self.message)
    }

    func openLink(_ url: URL) async throws {
        throw ToolError.unavailable(Self.message)
    }
}

// MARK: - open_app

/// `open_app`: launches an installed app (or brings it to the front) found
/// by name through instant search's app index.
struct OpenAppTool: Tool {
    static let maxNameCharacters = 200

    let context: AppToolContext

    let name = "open_app"
    var displayName: String { String(localized: "Open app") }
    var description: String {
        """
        Opens an app installed on the user's Mac: launches it, or brings it to the front when it already runs. \
        Use it when the user asks to open, start or switch to an app ("Öffne Safari", "Starte den Rechner"). \
        'name' is the app's name as Finder shows it, in the user's language or English ("Rechner" or \
        "Calculator"). An exact name, the start of one app's name or its initials ("vsc" for Visual Studio Code) \
        opens that app; if several apps fit, nothing opens and you get their names, so ask the user which one. \
        Apps are looked for in /Applications, /System/Applications and ~/Applications (with one level of \
        subfolders) plus Finder. Not for files or folders (use open_file), web pages (use open_url) or settings \
        (there is no tool for System Settings panes).
        """
    }
    var inputSchema: JSONSchema {
        .object(properties: [
            "name": .string(description: "The app's name, e.g. \"Safari\", \"Rechner\" or \"Visual Studio Code\"."),
        ], required: ["name"])
    }
    let riskLevel: ToolRiskLevel = .draft
    let category: ToolCategory = .apps

    func statusText(for arguments: ToolArguments) -> String {
        String(localized: "Opening app…")
    }

    func run(arguments: ToolArguments) async throws -> ToolResult {
        let requested = NoteText.singleLine(arguments["name"]?.stringValue ?? "")
        guard !requested.isEmpty else { throw ToolError.invalidArgument("'name' must not be empty.") }
        guard requested.count <= Self.maxNameCharacters else {
            throw ToolError.invalidArgument("'name' may have at most \(Self.maxNameCharacters) characters.")
        }
        let apps = await context.installedApps()
        let match = AppNameMatching.resolve(requested, in: apps, launchCounts: context.launchCounts.launchCounts())
        switch match {
        case .found(let app):
            do {
                try await context.launcher.openApplication(at: URL(fileURLWithPath: app.path, isDirectory: true))
            } catch let error as ToolError {
                throw error
            } catch {
                Log.tools.error("open_app: macOS did not open the app (\(String(describing: type(of: error)), privacy: .public))")
                throw ToolError.failed("macOS could not open \"\(TurnContext.inline(app.name, maxCharacters: 100))\". Tell the user.")
            }
            return ToolResult(
                text: "Opened the app \"\(TurnContext.inline(app.name, maxCharacters: 100))\"; it is now in front of Orbit.",
                summary: String(format: String(localized: "Opened “%@”"), app.name)
            )
        case .ambiguous(let candidates):
            throw ToolError.invalidArgument(AppNameMatching.ambiguousMessage(requested, candidates: candidates))
        case .suggestions(let candidates):
            throw ToolError.notFound(AppNameMatching.suggestionsMessage(requested, candidates: candidates))
        case .notFound:
            throw ToolError.notFound(AppNameMatching.notFoundMessage(requested, hasApps: !apps.isEmpty))
        }
    }
}

/// Finding the app the model names (pure): instant search's matching
/// (`FuzzyMatcher` over every name of an app: the shown one, the bundle's
/// localized and English names, the file name). An exact name wins, then the
/// start of a name, then the start of words or initials ("vsc"); when exactly
/// one app fits in the best of these, it opens; several are asked about.
/// Matches inside a name or of scattered letters never open an app: they are
/// only suggested. Copies of one app (the same name in two folders) count as
/// one: the one opened most often from instant search, else the system-wide one.
enum AppNameMatching {
    enum Match: Sendable, Hashable {
        case found(IndexedApp)
        /// Several apps fit equally well.
        case ambiguous([IndexedApp])
        /// No good match; these come close (never opened without asking).
        case suggestions([IndexedApp])
        case notFound
    }

    static let maxCandidates = 10

    static func resolve(_ name: String, in apps: [IndexedApp], launchCounts: [String: Int]) -> Match {
        let query = FuzzyMatcher.Query(name)
        guard !query.isEmpty else { return .notFound }
        let matches = apps.compactMap { app in app.match(query).map { (app: app, match: $0) } }
        for tiers in [[FuzzyMatcher.Tier.exact], [.prefix], [.wordPrefix]] {
            let fitting = matches.filter { tiers.contains($0.match.tier) }
            let distinct = representatives(fitting, launchCounts: launchCounts)
            if distinct.count == 1 { return .found(distinct[0]) }
            if distinct.count > 1 { return .ambiguous(Array(distinct.prefix(maxCandidates))) }
        }
        let weak = representatives(matches, launchCounts: launchCounts)
        return weak.isEmpty ? .notFound : .suggestions(Array(weak.prefix(5)))
    }

    /// One app per shown name, best match first (then launches, then name).
    private static func representatives(_ matches: [(app: IndexedApp, match: FuzzyMatcher.Match)],
                                        launchCounts: [String: Int]) -> [IndexedApp] {
        var byName: [String: (app: IndexedApp, match: FuzzyMatcher.Match)] = [:]
        for candidate in matches {
            let key = CalendarMatching.folded(candidate.app.name)
            guard let current = byName[key] else {
                byName[key] = candidate
                continue
            }
            if prefers(candidate, over: current, launchCounts: launchCounts) {
                byName[key] = candidate
            }
        }
        return byName.values.sorted { lhs, rhs in
            let left = lhs.match.rank + AppRanking.boost(forLaunches: launchCounts[lhs.app.path] ?? 0)
            let right = rhs.match.rank + AppRanking.boost(forLaunches: launchCounts[rhs.app.path] ?? 0)
            return SearchOrder.precedes(rank: left, name: lhs.app.name, id: lhs.app.path,
                                        rank: right, name: rhs.app.name, id: rhs.app.path)
        }.map(\.app)
    }

    /// Of two copies of an app: the better match, then the one opened more
    /// often, then one in /Applications or /System, then the shorter path.
    private static func prefers(_ candidate: (app: IndexedApp, match: FuzzyMatcher.Match),
                                over current: (app: IndexedApp, match: FuzzyMatcher.Match),
                                launchCounts: [String: Int]) -> Bool {
        if candidate.match.rank != current.match.rank { return candidate.match.rank > current.match.rank }
        let candidateLaunches = launchCounts[candidate.app.path] ?? 0
        let currentLaunches = launchCounts[current.app.path] ?? 0
        if candidateLaunches != currentLaunches { return candidateLaunches > currentLaunches }
        func isSystemWide(_ path: String) -> Bool { path.hasPrefix("/Applications/") || path.hasPrefix("/System/") }
        if isSystemWide(candidate.app.path) != isSystemWide(current.app.path) { return isSystemWide(candidate.app.path) }
        if candidate.app.path.count != current.app.path.count { return candidate.app.path.count < current.app.path.count }
        return candidate.app.path < current.app.path
    }

    /// `"Safari", "Safari Technology Preview"`.
    static func list(_ apps: [IndexedApp]) -> String {
        apps.map { "\"\(TurnContext.inline($0.name, maxCharacters: 100))\"" }.joined(separator: ", ")
    }

    static func ambiguousMessage(_ name: String, candidates: [IndexedApp]) -> String {
        "\"\(TurnContext.inline(name, maxCharacters: 100))\" fits several apps (names from the user's Mac, data): \(list(candidates)). Nothing was opened. Ask the user which one they mean, or call open_app again with one of these names exactly."
    }

    static func suggestionsMessage(_ name: String, candidates: [IndexedApp]) -> String {
        "No app is named \"\(TurnContext.inline(name, maxCharacters: 100))\". Apps with similar names (data): \(list(candidates)). Nothing was opened. If one of them is meant, call open_app again with its name exactly; ask the user when unsure."
    }

    static func notFoundMessage(_ name: String, hasApps: Bool) -> String {
        guard hasApps else {
            return "Orbit has not found any apps yet (it is still looking through the app folders). Nothing was opened; try again in a moment."
        }
        return "No installed app is named \"\(TurnContext.inline(name, maxCharacters: 100))\" (Orbit looks in /Applications, /System/Applications and ~/Applications). Nothing was opened. Tell the user; maybe the app has another name or is not installed."
    }
}
