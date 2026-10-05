import CoreServices
import Foundation
import os
import Testing
@testable import Orbit

/// The app index on fake bundles in temporary folders, never the real app folders.
@Suite("AppIndex")
struct AppIndexTests {
    /// Finder's name for the fake bundles: they are not registered with Launch
    /// Services, so the file name stands in (as Finder would show it).
    static let fileNameAsDisplayName: @Sendable (String) -> String = { FilePath.lastComponent($0) }

    @Test func findsAppsTwoLevelsDeepButNeverInsideBundles() throws {
        let folder = try TemporaryFolder("app-index")
        defer { folder.remove() }
        try FakeBundle.make(in: folder, "Calculator.app", info: ["CFBundleName": "Calculator"])
        try FakeBundle.make(in: folder, "Utilities/Terminal.app")
        try FakeBundle.make(in: folder, "Utilities/Deep/Too Deep.app")
        try FakeBundle.make(in: folder, "Editor.app")
        try FakeBundle.make(in: folder, "Editor.app/Contents/Resources/Helper.app")
        try FakeBundle.make(in: folder, ".Hidden.app")
        try FakeBundle.make(in: folder, ".Hidden Folder/Secret.app")
        try FakeBundle.make(in: folder, "Background.app", info: ["LSBackgroundOnly": true])
        try FakeBundle.make(in: folder, "Pages.app/Contents/Resources/Nested/Inner.app")
        try folder.write("Not An App/readme.txt", "text")
        try folder.write("Fake.app", "a file named like an app")
        let outside = try TemporaryFolder("app-index-outside")
        defer { outside.remove() }
        try FakeBundle.make(in: outside, "Real Linked.app")
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/Linked.app", withDestinationPath: outside.path + "/Real Linked.app")
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/A Link To Calculator.app", withDestinationPath: folder.path + "/Calculator.app")
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/Linked Folder", withDestinationPath: outside.path)

        let apps = try #require(AppBundleScanner.scan(configuration(folder.path), displayName: Self.fileNameAsDisplayName))
        #expect(apps.map(\.name) == ["Calculator", "Editor", "Linked", "Pages", "Terminal"])
        #expect(apps.first?.path == folder.path + "/Calculator.app", "the bundle itself, not the symlink to it")
        #expect(apps.first { $0.name == "Linked" }?.path == folder.path + "/Linked.app", "a symlinked app keeps its path")
    }

    @Test func everyNameFindsTheAppAndTheLocalizedOneIsShown() throws {
        let folder = try TemporaryFolder("app-index-names")
        defer { folder.remove() }
        // Third-party style: <language>.lproj/InfoPlist.strings.
        try FakeBundle.make(in: folder, "Calculator.app", info: ["CFBundleName": "Calculator", "CFBundleDisplayName": "Calculator"],
                            strings: ["de": ["CFBundleDisplayName": "Rechner"], "fr": ["CFBundleDisplayName": "Calculette"],
                                      "en": ["CFBundleDisplayName": "Calculator"]])
        // Apple style: one InfoPlist.loctable for all languages.
        try FakeBundle.make(in: folder, "Calendar.app", info: ["CFBundleName": "Calendar"],
                            loctable: ["de": ["CFBundleDisplayName": "Kalender", "CFBundleName": "Kalender"],
                                       "fr": ["CFBundleDisplayName": "Calendrier"], "en_GB": ["CFBundleName": "Calendar"]])
        // Old folder names ("German.lproj") and a short bundle name.
        try FakeBundle.make(in: folder, "Visual Studio Code.app", info: ["CFBundleName": "Code"],
                            strings: ["German": ["CFBundleName": "Code-Editor"]])
        let shown: @Sendable (String) -> String = { path in
            // Finder shows localized names; here the German one for the calculator.
            path.hasSuffix("Calculator.app") ? "Rechner" : FilePath.lastComponent(path)
        }
        let apps = try #require(AppBundleScanner.scan(configuration(folder.path, languages: ["de-DE"]), displayName: shown))
        let calculator = try #require(apps.first { $0.path.hasSuffix("Calculator.app") })
        #expect(calculator.name == "Rechner")
        for name in ["rech", "calc", "Rechner", "Calculator"] {
            #expect(calculator.match(FuzzyMatcher.Query(name)) != nil, "\(name)")
        }
        #expect(calculator.match(FuzzyMatcher.Query("calculette")) == nil, "only the preferred languages and English")
        let calendar = try #require(apps.first { $0.path.hasSuffix("Calendar.app") })
        #expect(calendar.name == "Calendar")
        #expect(calendar.match(FuzzyMatcher.Query("kalender"))?.tier == .exact)
        #expect(calendar.match(FuzzyMatcher.Query("calendrier")) == nil)
        let code = try #require(apps.first { $0.path.hasSuffix("Visual Studio Code.app") })
        #expect(code.match(FuzzyMatcher.Query("code"))?.tier == .exact, "CFBundleName is searchable")
        #expect(code.match(FuzzyMatcher.Query("vsc"))?.tier == .wordPrefix)
        #expect(code.match(FuzzyMatcher.Query("code editor"))?.tier == .exact, "old-style German.lproj")
    }

    @Test func findersNameLosesTheAppExtension() throws {
        let folder = try TemporaryFolder("app-index-display")
        defer { folder.remove() }
        try FakeBundle.make(in: folder, "Notizblock.app")
        try FakeBundle.make(in: folder, "Leer.app")
        // Launch Services names a bundle it does not know by its file name, extension included.
        // (Not asked here: looking up fake bundles could register them on this Mac.)
        let apps = try #require(AppBundleScanner.scan(configuration(folder.path), displayName: { path in
            path.hasSuffix("Leer.app") ? " " : FilePath.lastComponent(path)
        }))
        #expect(apps.map(\.name) == ["Leer", "Notizblock"], "an empty name falls back to the file name")
    }

    @Test(arguments: [
        (["de-DE"], ["de", "en", "en_GB"], ["de"]),
        (["en-US", "de"], ["English", "German", "fr"], ["English", "German"]),
        (["fr"], ["de", "en"], [String]()),
        (["de", "de-AT"], ["de"], ["de"]),
        (["pt-BR"], ["pt_BR", "pt_PT"], ["pt_BR"]),
        (["de"], [String](), [String]()),
    ])
    func localizationsForLanguages(languages: [String], available: [String], expected: [String]) {
        #expect(AppBundleScanner.localizations(for: languages, available: available) == expected)
    }

    @Test func localizationFolderNames() {
        #expect(AppBundleScanner.localizationFolders(for: "de-DE") == ["de-DE", "de_DE", "de", "German"])
        #expect(AppBundleScanner.localizationFolders(for: "en") == ["en", "English"])
        #expect(AppBundleScanner.localizationFolders(for: "pt-BR") == ["pt-BR", "pt_BR", "pt"])
    }

    @Test func configurationForTheMacAndForADebugScope() {
        let mac = AppIndexConfiguration.standard(homeDirectory: "/Users/lisa/", restriction: nil, languages: ["de"])
        #expect(mac.folders == ["/Applications", "/System/Applications", "/Users/lisa/Applications"])
        #expect(mac.singleApps == ["/System/Library/CoreServices/Finder.app"])
        #expect(mac.watchesFolders)
        let debug = AppIndexConfiguration.standard(homeDirectory: "/Users/lisa", restriction: "/Users/lisa/Orbit/Fixtures",
                                                   languages: ["de"])
        #expect(debug.folders == ["/System/Applications", "/Users/lisa/Orbit/Fixtures"])
        #expect(debug.singleApps.isEmpty)
        let invalid = AppIndexConfiguration.standard(homeDirectory: "/Users/lisa", restriction: FileSearchScope.invalidRestriction,
                                                     languages: ["de"])
        #expect(invalid.folders == ["/System/Applications"])
    }

    @Test func languagesAreOrbitsThenTheSystemsThenEnglish() {
        #expect(AppIndexConfiguration.preferredLanguages(own: ["de"], system: ["en-US", "de-DE"]) == ["de", "en-US", "de-DE", "en"])
        // An English Mac that lists German too finds "Rechner" as well as "Calculator".
        #expect(AppIndexConfiguration.preferredLanguages(own: ["en-US"], system: ["en-US", "de-DE", "fr-DE", "it"])
                == ["en-US", "de-DE", "fr-DE", "en"])
        #expect(AppIndexConfiguration.preferredLanguages(own: ["en"], system: ["en"]) == ["en"])
        #expect(AppIndexConfiguration.preferredLanguages(own: [], system: []) == ["en"])
    }

    @Test(arguments: [
        ("/Apps", 0, true),
        ("/Apps/New.app", 0, true),
        ("/Apps/New.app/Contents", 0, true),
        ("/Apps/Utilities", 0, true),
        ("/Apps/Utilities/New.app", 0, true),
        ("/Apps/Utilities/New.app/Contents", 0, true),
        ("/Apps/Utilities/Deeper", 0, true),
        ("/Apps/Utilities/Deeper/Too Deep.app", 0, false),
        ("/Apps/Utilities/Deeper/Folder", 0, false),
        ("/Apps/New.app/Contents/Resources", 0, false),
        ("/Apps/New.app/Contents/MacOS", 0, false),
        ("/Apps/Utilities/New.app/Contents/Resources/de.lproj", 0, false),
        ("/Apps/New.app/Contents/Resources/Helper.app", 0, false),
        ("/Other/New.app", 0, false),
        ("/Apps-Other/New.app", 0, false),
        ("/Somewhere/else", kFSEventStreamEventFlagMustScanSubDirs, true),
        ("/Apps", kFSEventStreamEventFlagRootChanged, true),
    ] as [(String, Int, Bool)])
    func relevantFolderEvents(path: String, flags: Int, relevant: Bool) {
        #expect(FolderWatcher.isRelevant(path: path, flags: FSEventStreamEventFlags(flags), folders: ["/Apps"]) == relevant)
    }

    // MARK: Live index (FSEvents)

    @Test func liveIndexScansAtStartAndAgainAfterChanges() async throws {
        let folder = try TemporaryFolder("app-index-live")
        defer { folder.remove() }
        try FakeBundle.make(in: folder, "Calculator.app")
        let changes = ChangeCounter()
        let index = LiveAppIndex(configuration: fastConfiguration(folder.path), displayName: Self.fileNameAsDisplayName)
        defer { index.stop() }
        #expect(index.apps.isEmpty, "nothing is scanned before start")
        index.start { changes.increment() }
        index.start { Issue.record("a second start is ignored") }
        #expect(await waitUntil { index.apps.map(\.name) == ["Calculator"] })
        #expect(await waitUntil { changes.value >= 1 }, "instant search hears about every scan (on the main actor)")

        try FakeBundle.make(in: folder, "Utilities/Neu.app")
        #expect(await waitUntil { index.apps.map(\.name) == ["Calculator", "Neu"] }, "a new app is picked up")
        try FileManager.default.removeItem(atPath: folder.path + "/Calculator.app")
        #expect(await waitUntil { index.apps.map(\.name) == ["Neu"] }, "a removed app disappears")
        try FileManager.default.moveItem(atPath: folder.path + "/Utilities/Neu.app", toPath: folder.path + "/Umbenannt.app")
        #expect(await waitUntil { index.apps.map(\.name) == ["Umbenannt"] }, "a renamed app is found by its new name")
        #expect(await waitUntil { changes.value >= 4 })
    }

    @Test func liveIndexWatchesFoldersCreatedLater() async throws {
        let folder = try TemporaryFolder("app-index-later")
        defer { folder.remove() }
        let missing = folder.path + "/Applications"
        let index = LiveAppIndex(configuration: fastConfiguration(missing), displayName: Self.fileNameAsDisplayName)
        defer { index.stop() }
        index.start {}
        try await Task.sleep(for: .milliseconds(300))
        #expect(index.apps.isEmpty)
        try FakeBundle.make(in: folder, "Applications/Spät.app")
        #expect(await waitUntil { index.apps.map(\.name) == ["Spät"] })
    }

    @Test func stoppingEndsWatching() async throws {
        let folder = try TemporaryFolder("app-index-stop")
        defer { folder.remove() }
        let index = LiveAppIndex(configuration: fastConfiguration(folder.path), displayName: Self.fileNameAsDisplayName)
        index.start {}
        #expect(await waitUntil { index.apps.isEmpty })
        index.stop()
        try FakeBundle.make(in: folder, "Nachher.app")
        try await Task.sleep(for: .milliseconds(600))
        #expect(index.apps.isEmpty)
    }

    // MARK: Latency

    /// Ranking ~500 apps happens on the main actor right after the debounce.
    @Test func queryLatencyForFiveHundredApps() {
        let apps = Self.fiveHundredApps()
        #expect(apps.count == 500)
        var report: [String] = []
        for text in ["s", "sa", "saf", "code", "vsc", "systemeinst", "photo edit", "zzzz"] {
            let query = FuzzyMatcher.Query(text)
            var durations: [Duration] = []
            for _ in 0..<20 {
                let start = ContinuousClock.now
                _ = AppRanking.rank(apps, query: query, launchCounts: ["/Apps/Safari.app": 12], limit: SearchLayout.maxApps)
                durations.append(ContinuousClock.now - start)
            }
            durations.sort()
            let median = durations[durations.count / 2]
            report.append("\(text): median \(Self.milliseconds(median)) ms, max \(Self.milliseconds(durations.last!)) ms")
            // Generous: the full suite runs in parallel, so single runs may be descheduled.
            #expect(median < .milliseconds(50), "\(text)")
            #expect(durations.last! < .milliseconds(500), "\(text)")
        }
        print("App ranking, 500 apps: " + report.joined(separator: "; "))
        #expect(AppRanking.rank(apps, query: FuzzyMatcher.Query("saf"), launchCounts: [:], limit: 4).first?.name == "Safari")
    }

    /// Scanning 500 bundles (without Launch Services, which caches real apps).
    @Test func scanningFiveHundredBundles() throws {
        let folder = try TemporaryFolder("app-index-500")
        defer { folder.remove() }
        for (index, name) in Self.fiveHundredApps().map(\.name).enumerated() {
            try FakeBundle.make(in: folder, (index % 5 == 0 ? "Utilities/" : "") + name + ".app", info: ["CFBundleName": name],
                                strings: index % 3 == 0 ? ["de": ["CFBundleDisplayName": name + " DE"]] : [:])
        }
        let start = ContinuousClock.now
        let apps = try #require(AppBundleScanner.scan(configuration(folder.path, languages: ["de"]), displayName: Self.fileNameAsDisplayName))
        let elapsed = ContinuousClock.now - start
        print("App index scan, 500 bundles: \(Self.milliseconds(elapsed)) ms")
        #expect(apps.count == 500)
        #expect(elapsed < .seconds(5))
    }

    // MARK: Helpers

    private func configuration(_ folder: String, languages: [String] = ["de"]) -> AppIndexConfiguration {
        AppIndexConfiguration(folders: [folder], languages: languages, watchesFolders: false)
    }

    private func fastConfiguration(_ folder: String) -> AppIndexConfiguration {
        AppIndexConfiguration(folders: [folder], languages: ["de"], eventLatency: 0.05, rescanDelay: .milliseconds(100))
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    static func milliseconds(_ duration: Duration) -> String {
        String(format: "%.2f", Double(duration / .microseconds(1)) / 1_000)
    }

    /// 500 app names like on a well-stocked Mac.
    static func fiveHundredApps() -> [IndexedApp] {
        let known = ["Safari", "Mail", "Kalender", "Karten", "Fotos", "Nachrichten", "FaceTime", "Musik", "Podcasts",
                     "Systemeinstellungen", "Visual Studio Code", "Xcode", "Terminal", "Photo Editor Pro", "Slack", "Spotify",
                     "Microsoft Word", "Microsoft Excel", "Google Chrome", "Firefox"]
        let words = ["Studio", "Pro", "Photo", "Code", "Note", "Mail", "Sync", "Cloud", "Video", "Audio", "Task", "Time",
                     "Maps", "Book", "Draw", "Edit", "Scan", "Chat", "Game", "Home"]
        var names = known
        var index = 0
        while names.count < 500 {
            let name = "\(words[index % words.count]) \(words[(index / words.count) % words.count]) \(index)"
            names.append(name)
            index += 1
        }
        return names.map { IndexedApp(path: "/Apps/\($0).app", name: $0, aliases: [$0 + " Alias"]) }
    }
}

/// Fake app bundles: a folder with Contents/Info.plist and optional name localizations.
enum FakeBundle {
    @discardableResult
    static func make(in folder: TemporaryFolder, _ relativePath: String, info: [String: Any] = [:],
                     strings: [String: [String: String]] = [:], loctable: [String: [String: String]]? = nil) throws -> String {
        let bundle = folder.path + "/" + relativePath
        let contents = bundle + "/Contents"
        try FileManager.default.createDirectory(atPath: contents + "/MacOS", withIntermediateDirectories: true)
        var plist = info
        plist["CFBundleIdentifier"] = plist["CFBundleIdentifier"] ?? "test.orbit." + UUID().uuidString
        plist["CFBundlePackageType"] = "APPL"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: contents + "/Info.plist"))
        for (language, values) in strings {
            let directory = "\(contents)/Resources/\(language).lproj"
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let text = values.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n")
            try text.write(toFile: directory + "/InfoPlist.strings", atomically: true, encoding: .utf16)
        }
        if let loctable {
            try FileManager.default.createDirectory(atPath: contents + "/Resources", withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: loctable, format: .binary, options: 0)
                .write(to: URL(fileURLWithPath: contents + "/Resources/InfoPlist.loctable"))
        }
        return bundle
    }
}

/// Counts calls from any thread.
final class ChangeCounter: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)

    var value: Int { count.withLock { $0 } }

    func increment() {
        count.withLock { $0 += 1 }
    }
}
