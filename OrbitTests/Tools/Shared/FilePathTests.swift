import Foundation
import os
import Testing
@testable import Orbit

@Suite("FilePath")
struct FilePathTests {
    @Test(arguments: [
        ("/a/./b//c/../d/", "/a/b/d"),
        ("/", "/"),
        ("/..", "/"),
        ("/a/../../b", "/b"),
        ("a/../../b", "../b"),
        ("", "."),
        ("/Users/me/Documents", "/Users/me/Documents"),
    ])
    func normalizes(input: String, expected: String) {
        #expect(FilePath.normalize(input) == expected)
    }

    @Test func expandsArguments() {
        let home = "/Users/me"
        #expect(FilePath.expand("~", home: home) == "/Users/me")
        #expect(FilePath.expand("~/Documents/a.pdf", home: home) == "/Users/me/Documents/a.pdf")
        #expect(FilePath.expand("  \"~/Documents/Mit Leerzeichen.pdf\" ", home: home) == "/Users/me/Documents/Mit Leerzeichen.pdf")
        #expect(FilePath.expand("„~/Dokumente/x.txt“", home: home) == "/Users/me/Dokumente/x.txt")
        #expect(FilePath.expand("file:///Users/me/Mein%20Ordner/a.pdf", home: home) == "/Users/me/Mein Ordner/a.pdf")
        #expect(FilePath.expand("/Users/me/../other/./x", home: home) == "/Users/other/x")
        #expect(FilePath.expand("~other/x", home: home) == "~other/x", "only the own home is expanded")
        #expect(FilePath.expand("Documents/a.pdf", home: home) == "Documents/a.pdf", "relative stays relative")
    }

    @Test func abbreviatesTheHomeFolder() {
        #expect(FilePath.abbreviate("/Users/me/Documents/a.pdf", home: "/Users/me") == "~/Documents/a.pdf")
        #expect(FilePath.abbreviate("/Users/me", home: "/Users/me/") == "~")
        #expect(FilePath.abbreviate("/Users/meier/a.pdf", home: "/Users/me") == "/Users/meier/a.pdf")
        #expect(FilePath.abbreviate("/tmp/a", home: "/") == "/tmp/a")
    }

    @Test func containment() {
        #expect(FilePath.isInside("/a/b", "/a"))
        #expect(FilePath.isInside("/a", "/a"))
        #expect(!FilePath.isInside("/ab", "/a"))
        #expect(FilePath.isInside("/anything", "/"))
        #expect(FilePath.lastComponent("/a/b.pdf") == "b.pdf")
        #expect(FilePath.lastComponent("/") == "")
    }

    @Test func canonicalResolvesSymlinksAlsoForMissingFiles() throws {
        let folder = try TemporaryFolder("filepath")
        defer { folder.remove() }
        try folder.write("real/file.txt", "x")
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/link", withDestinationPath: "real")
        #expect(FilePath.canonical(folder.path + "/link/file.txt") == folder.path + "/real/file.txt")
        #expect(FilePath.canonical(folder.path + "/link/missing/deeper.txt") == folder.path + "/real/missing/deeper.txt")
        // /tmp is a symlink to /private/tmp; canonical keeps /private (unlike resolvingSymlinksInPath).
        #expect(FilePath.canonical("/tmp") == "/private/tmp")
    }

    /// realpath keeps these spellings of the same item; the file access
    /// policy's location rules only recognize the usual one.
    @Test func canonicalDropsAliasSpellingsOfTheSameItem() throws {
        let folder = try TemporaryFolder("filepath-alias")
        defer { folder.remove() }
        try folder.write("Ordner/datei.txt", "x")
        let file = folder.path + "/Ordner/datei.txt"
        for prefix in FileSystemTricks.aliasPrefixes {
            #expect(FilePath.canonical(prefix + file) == file, "\(prefix)")
            #expect(FilePath.canonical(prefix + folder.path + "/Ordner") == folder.path + "/Ordner", "\(prefix): folder")
            #expect(FilePath.canonical(prefix + folder.path + "/Ordner/fehlt/tiefer.txt") == folder.path + "/Ordner/fehlt/tiefer.txt",
                    "\(prefix): missing file")
        }
        // volfs by the folder's own inode, and another case: the kernel names the item as it is on disk.
        var info = stat()
        #expect(stat(folder.path + "/Ordner", &info) == 0)
        #expect(FilePath.canonical("/.vol/\(info.st_dev)/\(info.st_ino)/datei.txt") == file)
        #expect(FilePath.canonical(folder.path + "/ORDNER/Datei.TXT") == file)
    }

    @Test func canonicalNamesTheFileBehindAnOpenDescriptor() throws {
        let folder = try TemporaryFolder("filepath-descriptor")
        defer { folder.remove() }
        let file = try folder.write("offen.txt", "x")
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        #expect(FilePath.canonical("/dev/fd/\(handle.fileDescriptor)") == file.path)
    }

    /// Resolving opens files for event notifications only; a pipe would block
    /// an open for reading, so it is never opened.
    @Test func canonicalNeverBlocksOnPipes() throws {
        let folder = try TemporaryFolder("filepath-pipe")
        defer { folder.remove() }
        let pipe = folder.path + "/leitung"
        try FileSystemTricks.makePipe(at: pipe)
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/verweis", withDestinationPath: "leitung")
        let resolved = OSAllocatedUnfairLock(initialState: [String]())
        #expect(FileSystemTricks.finishes(within: 2, releasing: pipe) {
            let paths = [FilePath.canonical(pipe), FilePath.canonical(folder.path + "/verweis")]
            resolved.withLock { $0 = paths }
        })
        #expect(resolved.withLock { $0 } == [pipe, pipe])
    }
}
