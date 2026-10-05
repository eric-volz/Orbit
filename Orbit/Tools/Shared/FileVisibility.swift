import Foundation
import UniformTypeIdentifiers

/// Whether a file is one the user sees in Finder. File searches (the tools and
/// instant search) apply it to every Spotlight result.
///
/// Not visible: anything below a path component that starts with "." (hidden
/// folders, ~/.Trash, .Trashes), anything in ~/Library except iCloud Drive
/// (~/Library/Mobile Documents) and cloud storage (~/Library/CloudStorage), and
/// the contents of packages and bundles (apps, iWork documents, photo
/// libraries, …); the package itself is visible. Spotlight skips most of this
/// already; the filter is the guarantee.
struct FileVisibility: Sendable, Hashable {
    /// Folders in ~/Library whose contents the user sees in Finder.
    static let visibleLibraryFolders = ["Mobile Documents", "CloudStorage"]

    var homeDirectory: String

    /// `path` must be absolute and normalized.
    func isVisible(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard !components.isEmpty else { return false }
        if components.contains(where: { $0.hasPrefix(".") }) { return false }
        if isHiddenLibraryPath(path) { return false }
        // Only ancestors: a package itself is visible, its contents are not.
        return !components.dropLast().contains { Self.isPackageName($0) }
    }

    private func isHiddenLibraryPath(_ path: String) -> Bool {
        let library = FilePath.normalize(homeDirectory + "/Library")
        guard FilePath.isInside(path, library) else { return false }
        return !Self.visibleLibraryFolders.contains { FilePath.isInside(path, library + "/" + $0) }
    }

    /// True for folder names whose extension denotes a package or bundle
    /// ("Keynote.app", "Bericht.pages", "Fotos.photoslibrary").
    static func isPackageName(_ name: Substring) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let pathExtension = name[name.index(after: dot)...]
        guard !pathExtension.isEmpty, !pathExtension.contains(" ") else { return false }
        guard let type = UTType(filenameExtension: String(pathExtension), conformingTo: .directory) else { return false }
        return type.conforms(to: .package) || type.conforms(to: .bundle)
    }
}
