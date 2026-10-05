import Foundation
import os

/// The folder a file is in as Finder names it, for the folder line of file
/// rows in cards and instant search (the model gets paths, never these):
/// localized standard folders ("Dokumente", "Schreibtisch"), "iCloud Drive" and
/// its app folders instead of ~/Library/Mobile Documents/com~apple~…, cloud
/// storage by its provider's name. The names come from the disk
/// (`FileManager.displayName`, which may touch protected folders), so they are
/// computed off the main actor (when a tool builds its card, in instant
/// search's merger) and cached per folder.
struct FolderNames: Sendable {
    /// iCloud Drive's name in Finder, in every language.
    static let iCloudDrive = "iCloud Drive"
    static let iCloudDriveContainer = "com~apple~CloudDocs"

    let homeDirectory: String
    /// The name Finder shows for the folder at a path.
    let displayName: @Sendable (String) -> String

    init(homeDirectory: String, displayName: @escaping @Sendable (String) -> String) {
        self.homeDirectory = homeDirectory
        self.displayName = displayName
    }

    /// Names from the file system, in Orbit's language, cached for the process.
    static func live(homeDirectory: String) -> FolderNames {
        FolderNames(homeDirectory: homeDirectory) { path in
            cachedName(of: path) { FileManager.default.displayName(atPath: $0) }
        }
    }

    private static let cache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// The cached name of the folder at `path`, else `lookup`'s (then cached).
    static func cachedName(of path: String, lookup: (String) -> String) -> String {
        if let cached = cache.withLock({ $0[path] }) { return cached }
        let name = lookup(path)
        cache.withLock { cache in
            // Plenty for the folders of a session's results; starting over is cheap.
            if cache.count >= 2_000 { cache.removeAll() }
            cache[path] = name
        }
        return name
    }

    /// The folders from the home folder (or volume) down to the one the item
    /// at `path` is in, outermost first: ["Dokumente", "Rechnungen"] for
    /// ~/Documents/Rechnungen/Telekom.pdf, ["iCloud Drive", "Keynote"] for
    /// ~/Library/Mobile Documents/com~apple~Keynote/Documents/Plan.key. An item
    /// directly in the home folder gets the home folder's name.
    func names(ofFolderContaining path: String) -> [String] {
        let folder = FilePath.normalize(path + "/..")
        let home = FilePath.normalize(homeDirectory)
        guard folder != "/" else { return [displayName("/")] }
        guard folder != home else { return [displayName(home)] }
        var names: [String] = []
        var current: String
        var rest: ArraySlice<Substring>
        if home != "/", FilePath.isInside(folder, home) {
            current = home
            rest = folder.dropFirst(home.count + 1).split(separator: "/")[...]
            if rest.starts(with: ["Library", "Mobile Documents"]) {
                current += "/Library/Mobile Documents"
                rest = rest.dropFirst(2)
                names.append(Self.iCloudDrive)
                if let container = rest.first {
                    current += "/" + container
                    rest = rest.dropFirst()
                    if container != Self.iCloudDriveContainer {
                        // An app's folder in iCloud Drive; Finder shows its Documents folder as the app's folder.
                        names.append(Self.appFolderName(container, shown: displayName(current)))
                        if rest.first == "Documents" {
                            current += "/Documents"
                            rest = rest.dropFirst()
                        }
                    }
                }
            } else if rest.count > 2, rest.starts(with: ["Library", "CloudStorage"]) {
                current += "/Library/CloudStorage"
                rest = rest.dropFirst(2)
            }
        } else if folder.hasPrefix("/Volumes/") {
            current = "/Volumes"
            rest = folder.dropFirst("/Volumes/".count).split(separator: "/")[...]
        } else {
            current = ""
            rest = folder.split(separator: "/")[...]
        }
        for component in rest {
            current += "/" + component
            names.append(displayName(current))
        }
        return names
    }

    /// The name of an app's folder in iCloud Drive: the one the file system
    /// gives, else the last part of the container's name ("Keynote" for
    /// com~apple~Keynote).
    static func appFolderName(_ container: Substring, shown: String) -> String {
        guard shown == container || shown.isEmpty else { return shown }
        return container.split(separator: "~").last.map(String.init) ?? String(container)
    }

    /// For the folder line: "Dokumente ▸ Rechnungen".
    static func shown(_ names: [String]) -> String {
        names.joined(separator: " ▸ ")
    }

    /// For VoiceOver, which would read the triangle: "Dokumente, Rechnungen".
    static func spoken(_ names: [String]) -> String {
        names.joined(separator: ", ")
    }
}
