import Foundation
import os
import Testing
@testable import Orbit

/// Folder lines name folders like Finder: localized, iCloud Drive and its app
/// folders, cloud storage by provider, with names from a fake here (the live
/// one reads the disk).
@Suite("FolderNames")
struct FolderNamesTests {
    /// Finder's names on a German Mac; every other folder keeps its name.
    static let finderNames: [String: String] = [
        "/Users/lisa": "lisa",
        "/Users/lisa/Documents": "Dokumente",
        "/Users/lisa/Desktop": "Schreibtisch",
        "/Users/lisa/Library/CloudStorage/OneDrive-Persönlich": "OneDrive",
        "/Users/lisa/Library/Mobile Documents/com~apple~CloudDocs/Documents": "Dokumente",
        "/Volumes/Daten": "Daten",
        "/": "Macintosh HD",
    ]

    static let names = FolderNames(homeDirectory: "/Users/lisa") { finderNames[$0] ?? FilePath.lastComponent($0) }

    @Test(arguments: [
        ("/Users/lisa/Documents/Rechnungen/Telekom.pdf", ["Dokumente", "Rechnungen"]),
        ("/Users/lisa/Desktop/Notiz.txt", ["Schreibtisch"]),
        ("/Users/lisa/Documents/Rechnungen", ["Dokumente"]),
        ("/Users/lisa/Notiz.txt", ["lisa"]),
        ("/Users/lisa/Library/Mobile Documents/com~apple~CloudDocs/Steuer/Bescheid.pdf", ["iCloud Drive", "Steuer"]),
        ("/Users/lisa/Library/Mobile Documents/com~apple~CloudDocs/Plan.pdf", ["iCloud Drive"]),
        ("/Users/lisa/Library/Mobile Documents/com~apple~CloudDocs/Documents/Brief.pages", ["iCloud Drive", "Dokumente"]),
        ("/Users/lisa/Library/Mobile Documents/com~apple~Keynote/Documents/Quartal.key", ["iCloud Drive", "Keynote"]),
        ("/Users/lisa/Library/Mobile Documents/iCloud~com~example~Notizen/Documents/Ideen/a.txt",
         ["iCloud Drive", "Notizen", "Ideen"]),
        ("/Users/lisa/Library/CloudStorage/OneDrive-Persönlich/Verträge/Miete.pdf", ["OneDrive", "Verträge"]),
        ("/Volumes/Daten/Projekte/Plan.pdf", ["Daten", "Projekte"]),
        ("/Plan.pdf", ["Macintosh HD"]),
        ("/private/tmp/a.txt", ["private", "tmp"]),
        ("/Users/lisa2/Documents/a.txt", ["Users", "lisa2", "Documents"]),
    ])
    func namesFoldersLikeFinder(path: String, expected: [String]) {
        #expect(Self.names.names(ofFolderContaining: path) == expected)
    }

    @Test func appFoldersInICloudDriveUseTheNameTheSystemGivesThem() {
        let named = FolderNames(homeDirectory: "/Users/lisa") { path in
            path.hasSuffix("com~apple~Keynote") ? "Keynote-Präsentationen" : FilePath.lastComponent(path)
        }
        #expect(named.names(ofFolderContaining: "/Users/lisa/Library/Mobile Documents/com~apple~Keynote/Documents/a.key")
                == ["iCloud Drive", "Keynote-Präsentationen"])
        #expect(FolderNames.appFolderName("com~apple~Numbers", shown: "com~apple~Numbers") == "Numbers")
        #expect(FolderNames.appFolderName("com~apple~Numbers", shown: "") == "Numbers")
    }

    @Test func shownWithTrianglesSpokenWithCommas() {
        #expect(FolderNames.shown(["Dokumente", "Rechnungen"]) == "Dokumente ▸ Rechnungen")
        #expect(FolderNames.spoken(["Dokumente", "Rechnungen"]) == "Dokumente, Rechnungen")
    }

    /// The live names come from the disk: a ".localized" folder shows without the suffix.
    @Test func liveNamesComeFromTheDisk() throws {
        let folder = try TemporaryFolder("folder-names")
        defer { folder.remove() }
        let file = try folder.write("Belege.localized/2026/Quittung.pdf", "%PDF")
        #expect(FolderNames.live(homeDirectory: folder.path).names(ofFolderContaining: file.path) == ["Belege", "2026"])
    }

    @Test func eachFolderIsLookedUpOnce() {
        let path = "/orbit-test-\(UUID().uuidString)/Belege"
        let lookups = OSAllocatedUnfairLock(initialState: 0)
        func lookup(_ path: String) -> String {
            lookups.withLock { $0 += 1 }
            return "Belege"
        }
        #expect(FolderNames.cachedName(of: path, lookup: lookup) == "Belege")
        #expect(FolderNames.cachedName(of: path, lookup: lookup) == "Belege")
        #expect(lookups.withLock { $0 } == 1)
    }
}

@Suite("Folder lines")
struct FolderLineTests {
    @Test func cardRowsShowFinderNamesAndVoiceOverReadsThemWithoutTriangles() {
        let now = FlexibleDate.parse("2026-09-30T12:00:00+02:00")!.date
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let german = Locale(identifier: "de_DE")
        let file = FileItem(path: "/Users/lisa/Library/Mobile Documents/com~apple~CloudDocs/Steuer/Bescheid.pdf",
                            name: "Bescheid.pdf", modified: FlexibleDate.parse("2026-08-15T09:30:00+02:00")!.date,
                            size: 2_300_000, folderNames: ["iCloud Drive", "Steuer"])
        #expect(FileCardFormat.folder(of: file, homeDirectory: "/Users/lisa") == "iCloud Drive ▸ Steuer")
        #expect(FileCardFormat.accessibilityValue(for: file, now: now, calendar: berlin, locale: german,
                                                  homeDirectory: "/Users/lisa") == "iCloud Drive, Steuer, 15. Aug., 2,3 MB")
        #expect(FileCardFormat.announcement(for: file, now: now, calendar: berlin, locale: german, homeDirectory: "/Users/lisa")
                == "Bescheid.pdf, iCloud Drive, Steuer, 15. Aug., 2,3 MB")

        // Cards in chats saved before show the path.
        let old = FileItem(path: "/Users/lisa/Documents/Rechnungen/Telekom.pdf", name: "Telekom.pdf")
        #expect(FileCardFormat.folder(of: old, homeDirectory: "/Users/lisa") == "~/Documents/Rechnungen")
        #expect(FileCardFormat.accessibilityValue(for: old, homeDirectory: "/Users/lisa") == "~/Documents/Rechnungen")
    }

    @Test func instantResultsShowFinderNames() {
        let results = SearchResults.files([
            FileHit(path: "/Users/lisa/Documents/Rechnungen/Telekom.pdf", name: "Telekom.pdf",
                    folderNames: ["Dokumente", "Rechnungen"]),
            FileHit(path: "/Users/lisa/Downloads/Plan.pdf", name: "Plan.pdf"),
        ], homeDirectory: "/Users/lisa")
        #expect(results.map(\.subtitle) == ["Dokumente ▸ Rechnungen", "~/Downloads"])
        #expect(results.map(\.spokenSubtitle) == ["Dokumente, Rechnungen", nil])
    }

    /// Chats saved before folder names existed still load.
    @Test func savedCardsWithoutFolderNamesStillDecode() throws {
        let old = #"{"path":"/Users/lisa/Documents/a.pdf","name":"a.pdf","isDirectory":false}"#
        let item = try JSONDecoder().decode(FileItem.self, from: Data(old.utf8))
        #expect(item.folderNames == nil)
        #expect(item.path == "/Users/lisa/Documents/a.pdf")

        let named = FileItem(path: "/Users/lisa/Documents/a.pdf", name: "a.pdf", folderNames: ["Dokumente"])
        let decoded = try JSONDecoder().decode(FileItem.self, from: JSONEncoder().encode(named))
        #expect(decoded == named)
    }
}
