import Darwin
import Foundation
@testable import Orbit

/// Other spellings of the same file, Finder aliases and items whose content
/// blocks, for the security tests of the file tools. Everything happens in
/// temporary folders; nothing is opened in an app.
enum FileSystemTricks {
    /// "/.vol/<device>/2": the data volume's root through volfs (the temporary
    /// folder lives on the data volume).
    static let volfsRoot: String = {
        var info = stat()
        _ = stat(NSTemporaryDirectory(), &info)
        return "/.vol/\(info.st_dev)/2"
    }()

    /// Prefixes the kernel accepts in front of an absolute path for the same
    /// item: the data volume's mount point (firmlinks), the no-follow and
    /// resolve-flags prefixes, and volfs.
    static let aliasPrefixes = ["/System/Volumes/Data", "/.nofollow", "/.resolve/1", volfsRoot]

    /// A Finder alias at `alias` pointing to `target` (bookmark data, like
    /// Finder's "Make Alias").
    @discardableResult
    static func makeFinderAlias(to target: URL, at alias: URL) throws -> URL {
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil,
                                               relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        return alias
    }

    /// A named pipe: opening it for reading blocks until a writer appears, like
    /// reading a file whose content is not on the Mac.
    static func makePipe(at path: String) throws {
        guard mkfifo(path, 0o644) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Runs `body` on its own thread and tells whether it finished within
    /// `timeout`. If not, it opens the pipe at `pipe` for writing until
    /// `body` returns, so a blocked reader gets EOF and a regression fails
    /// the test instead of hanging the test run.
    static func finishes(within timeout: TimeInterval, releasing pipe: String,
                         _ body: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            body()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .success { return true }
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            let descriptor = open(pipe, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 { close(descriptor) }
        }
        return false
    }
}

/// A fake home folder with fake secrets, protected only by their location
/// (the name rules would not catch them), plus Orbit's data folder and
/// ~/Library.
struct FakeHome {
    let folder: TemporaryFolder
    var home: String { folder.path }
    var dataDirectory: String { home + "/Library/Application Support/Orbit" }

    /// Relative paths of the protected fake files and the denial their plain path gets.
    static let protectedFiles: [(path: String, denial: FileAccessPolicy.Denial)] = [
        (".aws/credentials", .secret), (".kube/config", .secret), (".config/gh/hosts.yml", .secret),
        (".ssh/work_key", .secret), ("Library/Application Support/Orbit/notes.txt", .orbitData),
        ("Library/Preferences/x.txt", .library),
    ]

    /// The text in each protected file.
    static let marker = "FAKE-SECRET-FOR-TESTS"

    init() throws {
        folder = try TemporaryFolder("fake-home")
        for (path, _) in Self.protectedFiles {
            try folder.write(path, "\(Self.marker) \(path)\n")
        }
        try folder.write("Documents/brief.txt", "harmless\n")
    }

    var policy: FileAccessPolicy { FileAccessPolicy(homeDirectory: home, orbitDataDirectory: dataDirectory) }

    /// A release-like context: no debug scope.
    func context(spotlight: MockSpotlight = MockSpotlight(), workspace: MockWorkspace = MockWorkspace()) -> FileToolContext {
        FileToolContext(spotlight: spotlight, workspace: workspace,
                        scope: FileSearchScope(homeDirectory: home, listHomeFolders: { ["Documents"] }), policy: policy)
    }

    func remove() {
        folder.remove()
    }
}
