import Foundation
import os

/// Where file searches look, shared by the file tools and instant search.
///
/// By default Spotlight searches the visible folders directly in the home
/// folder (Desktop, Documents, Downloads, …, and folders the user created) plus
/// iCloud Drive (~/Library/Mobile Documents) and cloud storage
/// (~/Library/CloudStorage), not the home scope as a whole. The home scope
/// would make Spotlight gather everything in ~/Library (mail, caches, app
/// containers) only for Orbit to throw it away after reading it on the main
/// actor, and those hits could crowd real files out of the bounded read. The
/// trade-off: files lying directly in the home folder itself are not found.
///
/// DEBUG builds honor `ORBIT_DEBUG_FILE_SCOPE=<absolute folder>` (read once at
/// launch): searches look only there and the file tools refuse every path
/// outside it. An invalid value restricts to nothing, so a typo never widens
/// the search to the real home folder.
struct FileSearchScope: Sendable {
    /// The user's home folder (tests pass a fake one).
    let homeDirectory: String
    /// DEBUG: the only folder searches and file tools may use (canonical path),
    /// or nil for no restriction.
    let restriction: String?
    /// Lists the home folder's visible top-level folders (live: FileManager).
    private let listHomeFolders: @Sendable () -> [String]

    init(homeDirectory: String, restriction: String? = nil, listHomeFolders: @escaping @Sendable () -> [String]) {
        self.homeDirectory = FilePath.normalize(homeDirectory)
        self.restriction = restriction.map(FilePath.normalize)
        self.listHomeFolders = listHomeFolders
    }

    /// A scope that only ever searches `directory` (tests, debug sessions).
    static func restricted(to directory: String, homeDirectory: String) -> FileSearchScope {
        FileSearchScope(homeDirectory: homeDirectory, restriction: FilePath.canonical(directory), listHomeFolders: { [] })
    }

    /// The real home folder; `environment` is read for ORBIT_DEBUG_FILE_SCOPE (DEBUG only).
    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> FileSearchScope {
        let home = FilePath.normalize(NSHomeDirectory())
        var restriction: String?
        #if DEBUG
        if let value = environment[debugScopeVariable]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            restriction = debugRestriction(from: value)
            Log.search.notice("File searches are restricted to the debug scope")
        }
        #endif
        return FileSearchScope(homeDirectory: home, restriction: restriction) {
            visibleTopLevelFolders(of: home)
        }
    }

    static let debugScopeVariable = "ORBIT_DEBUG_FILE_SCOPE"

    /// The canonical folder for a debug scope value; a value that is not an
    /// absolute path to an existing folder yields a restriction nothing is inside.
    static func debugRestriction(from value: String) -> String {
        let path = FilePath.normalize(value)
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            Log.search.error("ORBIT_DEBUG_FILE_SCOPE is not an absolute path to a folder; file searches find nothing")
            return invalidRestriction
        }
        return FilePath.canonical(path)
    }

    /// A restriction no absolute path is inside of.
    static let invalidRestriction = "(invalid debug file scope)"

    // MARK: Queries

    /// The folders searched when no folder is given (absolute file URLs).
    func defaultDirectories() -> [URL] {
        if let restriction {
            guard restriction.hasPrefix("/") else { return [] }
            return [URL(fileURLWithPath: restriction, isDirectory: true)]
        }
        return Self.defaultDirectories(homeDirectory: homeDirectory, topLevelFolders: listHomeFolders(),
                                       existingLibraryFolders: existingVisibleLibraryFolders())
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Whether `canonicalPath` may be used: inside the restriction, if any.
    func allows(_ canonicalPath: String) -> Bool {
        guard let restriction else { return true }
        return restriction.hasPrefix("/") && FilePath.isInside(canonicalPath, restriction)
    }

    /// The default search folders for a home folder: the visible top-level
    /// folders except Library, then the visible Library folders that exist.
    static func defaultDirectories(homeDirectory: String, topLevelFolders: [String],
                                   existingLibraryFolders: [String]) -> [String] {
        let home = FilePath.normalize(homeDirectory)
        var seen = Set<String>()
        var result: [String] = []
        for name in topLevelFolders where !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && name != "Library" {
            let path = FilePath.normalize(home + "/" + name)
            if seen.insert(path).inserted { result.append(path) }
        }
        for name in existingLibraryFolders where FileVisibility.visibleLibraryFolders.contains(name) {
            let path = FilePath.normalize(home + "/Library/" + name)
            if seen.insert(path).inserted { result.append(path) }
        }
        return result
    }

    private func existingVisibleLibraryFolders() -> [String] {
        FileVisibility.visibleLibraryFolders.filter { name in
            var isDirectory: ObjCBool = false
            let path = homeDirectory + "/Library/" + name
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Names of the visible, real (not symlinked) folders directly in `home`.
    /// Lists names only; nothing inside them is read.
    private static func visibleTopLevelFolders(of home: String) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: home, isDirectory: true), includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]) else { return [] }
        return entries.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isPackage != true, values.isSymbolicLink != true,
                  values.isHidden != true else { return nil }
            return url.lastPathComponent
        }.sorted()
    }
}
