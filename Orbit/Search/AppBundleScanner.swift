import Foundation

/// Finds app bundles and reads their names. Reads only bundle folders and
/// their Info.plist and name localizations, never anything inside apps
/// beyond that. Runs off the main actor.
enum AppBundleScanner {
    /// Apps directly in a folder are at depth 1, those in a subfolder at depth 2.
    static let maximumDepth = 2

    /// Every app of the configuration, ordered by name; nil when the task was
    /// cancelled. An app found twice (a symlink to it) is listed once, by its
    /// own path when that was found.
    static func scan(_ configuration: AppIndexConfiguration,
                     displayName: (String) -> String = { FileManager.default.displayName(atPath: $0) }) -> [IndexedApp]? {
        let bundles = configuration.folders.flatMap { appBundles(in: $0) } + configuration.singleApps.filter(isAppBundle)
        var chosen: [String: String] = [:]
        var order: [String] = []
        for path in bundles {
            let resolved = FilePath.canonical(path)
            if let earlier = chosen[resolved] {
                if earlier != resolved, path == resolved { chosen[resolved] = path }
            } else {
                chosen[resolved] = path
                order.append(resolved)
            }
        }
        var apps: [IndexedApp] = []
        for resolved in order {
            guard !Task.isCancelled else { return nil }
            guard let path = chosen[resolved],
                  let app = app(at: path, languages: configuration.languages, displayName: displayName) else { continue }
            apps.append(app)
        }
        return apps.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
        }
    }

    /// App bundles in `folder` and its subfolders up to `maximumDepth`, without
    /// descending into bundles, hidden folders or symlinked folders. Symlinks to
    /// apps count (e.g. Safari in /Applications).
    static func appBundles(in folder: String, depth: Int = 1) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: folder, isDirectory: true), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }
        var bundles: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let path = FilePath.normalize(entry.path)
            if entry.pathExtension.lowercased() == "app" {
                if isAppBundle(path) { bundles.append(path) }
                continue
            }
            guard depth < maximumDepth, let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true else { continue }
            bundles += appBundles(in: path, depth: depth + 1)
        }
        return bundles
    }

    /// A folder (or a symlink to one) named *.app.
    static func isAppBundle(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.lowercased().hasSuffix(".app")
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// The app at `path` with all its names, or nil for background-only apps.
    static func app(at path: String, languages: [String], displayName: (String) -> String) -> IndexedApp? {
        let contents = path + "/Contents"
        let info = propertyList(at: contents + "/Info.plist") as? [String: Any] ?? [:]
        if isTrue(info["LSBackgroundOnly"]) { return nil }
        let fileName = withoutAppExtension(FilePath.lastComponent(path))
        var shown = withoutAppExtension(displayName(path)).trimmingCharacters(in: .whitespacesAndNewlines)
        if shown.isEmpty { shown = fileName }
        var aliases = [fileName]
        aliases += bundleNames(in: info)
        aliases += localizedBundleNames(resources: contents + "/Resources", languages: languages + ["en"])
        return IndexedApp(path: path, name: shown, aliases: aliases)
    }

    // MARK: Names

    private static let nameKeys = ["CFBundleDisplayName", "CFBundleName"]

    private static func bundleNames(in dictionary: [String: Any]) -> [String] {
        nameKeys.compactMap { dictionary[$0] as? String }.filter { !$0.isEmpty }
    }

    /// Bundle names from `InfoPlist.loctable` (Apple's apps: one table for all
    /// languages) or `<language>.lproj/InfoPlist.strings`, for each language.
    /// Looks only for the few folder names a language can have; big apps keep
    /// thousands of files in Resources.
    static func localizedBundleNames(resources: String, languages: [String]) -> [String] {
        if let table = propertyList(at: resources + "/InfoPlist.loctable") as? [String: Any] {
            return localizations(for: languages, available: Array(table.keys)).flatMap { localization in
                bundleNames(in: table[localization] as? [String: Any] ?? [:])
            }
        }
        var read = Set<String>()
        return languages.flatMap { language -> [String] in
            for folder in localizationFolders(for: language) {
                guard let strings = propertyList(at: "\(resources)/\(folder).lproj/InfoPlist.strings") as? [String: Any] else {
                    continue
                }
                return read.insert(folder).inserted ? bundleNames(in: strings) : []
            }
            return []
        }
    }

    /// The .lproj names a localization for `language` may have, best first:
    /// "de-DE", "de_DE", "de", "German".
    static func localizationFolders(for language: String) -> [String] {
        var names = [language, language.replacingOccurrences(of: "-", with: "_")]
        if let code = languageCode(language) {
            names.append(code)
            names += legacyLocalizationNames.filter { $0.value == code }.map { $0.key.capitalized }.sorted()
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// The best available localization for each language (no fallback to
    /// another language). Understands old folder names such as "German".
    static func localizations(for languages: [String], available: [String]) -> [String] {
        guard !available.isEmpty else { return [] }
        var result: [String] = []
        for language in languages {
            let code = languageCode(language)
            guard let best = Bundle.preferredLocalizations(from: available, forPreferences: [language]).first,
                  code != nil, languageCode(best) == code, !result.contains(best) else { continue }
            result.append(best)
        }
        return result
    }

    private static let legacyLocalizationNames = [
        "english": "en", "german": "de", "french": "fr", "spanish": "es", "italian": "it", "dutch": "nl",
        "japanese": "ja",
    ]

    private static func languageCode(_ localization: String) -> String? {
        if let legacy = legacyLocalizationNames[localization.lowercased()] { return legacy }
        return Locale(identifier: localization).language.languageCode?.identifier
    }

    // MARK: Helpers

    /// XML, binary and old-style plists, and .strings files.
    private static func propertyList(at path: String) -> Any? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }

    private static func isTrue(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: flag
        case let number as NSNumber: number.boolValue
        case let text as String: ["1", "true", "yes"].contains(text.lowercased())
        default: false
        }
    }

    private static func withoutAppExtension(_ name: String) -> String {
        name.lowercased().hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
