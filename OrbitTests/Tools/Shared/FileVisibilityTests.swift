import Foundation
import Testing
@testable import Orbit

@Suite("FileVisibility")
struct FileVisibilityTests {
    let visibility = FileVisibility(homeDirectory: "/Users/test")

    @Test(arguments: [
        ("/Users/test/Documents/Rechnung.pdf", true),
        ("/Users/test/Desktop/Ordner", true),
        ("/Users/test/Documents/Bericht.pages", true),
        ("/Users/test/Library/Mobile Documents/com~apple~CloudDocs/Plan.numbers", true),
        ("/Users/test/Library/CloudStorage/Dropbox/Vertrag.pdf", true),
        ("/Volumes/Backup/Fotos/Urlaub.jpg", true),
        ("/Users/test/Documents/Library/Buch.pdf", true),
        ("/Users/test/.Trash/alt.pdf", false),
        ("/Users/test/.ssh/id_rsa", false),
        ("/Users/test/Code/projekt/.git/config", false),
        ("/Users/test/Documents/.versteckt.txt", false),
        ("/Users/test/Library/Mail/V10/x.emlx", false),
        ("/Users/test/Library/Application Support/Orbit/Orbit.sqlite", false),
        ("/Users/test/Library", false),
        ("/Users/test/Library/Mobile Documents/.Trash/weg.txt", false),
        ("/Users/test/Applications/Tool.app/Contents/Info.plist", false),
        ("/Users/test/Documents/Bericht.pages/Data/bild.jpg", false),
        ("/Users/test/Pictures/Fotos.photoslibrary/originals/1.heic", false),
        ("/Users/test/Documents/Notizen.rtfd/TXT.rtf", false),
        ("/Users/test/Documents/Version 2.0/notes.txt", true),
        ("/Volumes/Backup/.Trashes/501/alt.pdf", false),
        ("/", false),
    ])
    func table(path: String, visible: Bool) {
        #expect(visibility.isVisible(path) == visible, "\(path)")
    }

    @Test func packageNames() {
        #expect(FileVisibility.isPackageName("Keynote.app"))
        #expect(FileVisibility.isPackageName("Bericht.pages"))
        #expect(FileVisibility.isPackageName("Notizen.rtfd"))
        #expect(!FileVisibility.isPackageName("Ordner"))
        #expect(!FileVisibility.isPackageName("Version 2.0"))
        #expect(!FileVisibility.isPackageName(".app"))
        #expect(!FileVisibility.isPackageName("Projekt.v2"))
    }
}

@Suite("FileSearchScope")
struct FileSearchScopeTests {
    @Test func defaultFoldersAreTheVisibleHomeFoldersAndTheCloudFolders() {
        let folders = FileSearchScope.defaultDirectories(
            homeDirectory: "/Users/test",
            topLevelFolders: ["Desktop", "Documents", "Downloads", "Library", ".config", "Code", "Documents", ""],
            existingLibraryFolders: ["Mobile Documents", "CloudStorage", "Mail"]
        )
        #expect(folders == ["/Users/test/Desktop", "/Users/test/Documents", "/Users/test/Downloads", "/Users/test/Code",
                            "/Users/test/Library/Mobile Documents", "/Users/test/Library/CloudStorage"])
    }

    @Test func aScopeListsTheHomeFoldersEachTime() {
        let scope = FileSearchScope(homeDirectory: "/Users/test/", listHomeFolders: { ["Documents", "Music"] })
        #expect(scope.homeDirectory == "/Users/test")
        #expect(scope.restriction == nil)
        #expect(scope.defaultDirectories().map(\.path) == ["/Users/test/Documents", "/Users/test/Music"])
        #expect(scope.allows("/anything"))
    }

    @Test func aRestrictedScopeSearchesOnlyItsFolder() throws {
        let folder = try TemporaryFolder("scope")
        defer { folder.remove() }
        let scope = FileSearchScope.restricted(to: folder.path, homeDirectory: "/Users/test")
        #expect(scope.defaultDirectories().map(\.path) == [folder.path])
        #expect(scope.allows(folder.path + "/a/b.pdf"))
        #expect(scope.allows(folder.path))
        #expect(!scope.allows("/Users/test/Documents/a.pdf"))
        #expect(!scope.allows(folder.path + "-other/a.pdf"))
    }

    @Test func theDebugVariableRestrictsTheLiveScope() throws {
        let folder = try TemporaryFolder("debug-scope")
        defer { folder.remove() }
        // The symlinked spelling (/tmp → /private/tmp) resolves to the same folder.
        let spelled = folder.path.replacingOccurrences(of: "/private/var/", with: "/var/")
        let scope = FileSearchScope.live(environment: [FileSearchScope.debugScopeVariable: spelled])
        #expect(scope.restriction == folder.path)
        #expect(scope.defaultDirectories().map(\.path) == [folder.path])
        #expect(scope.homeDirectory == FilePath.normalize(NSHomeDirectory()))
    }

    @Test(arguments: ["relative/folder", "/does/not/exist/orbit", "/etc/hosts"])
    func anInvalidDebugScopeRestrictsToNothing(value: String) {
        let scope = FileSearchScope.live(environment: [FileSearchScope.debugScopeVariable: value])
        #expect(scope.restriction == FileSearchScope.invalidRestriction)
        #expect(scope.defaultDirectories().isEmpty, "nothing is searched, never the real home folder")
        #expect(!scope.allows("/Users"))
        #expect(!scope.allows(NSHomeDirectory() + "/Documents/a.pdf"))
    }

    @Test func fakeServicesReachNothing() async throws {
        let services = AppServices.fake()
        #expect(services.fileScope.defaultDirectories().isEmpty)
        #expect(services.fileAccess.check(NSHomeDirectory() + "/Documents/x.pdf", purpose: .read) == .outsideScope)
        #expect(services.spotlight is MockSpotlight)
        #expect(services.workspace is MockWorkspace)
        #expect(services.quickLookPanel is FakeQuickLookPanel, "no preview window can appear")
        #expect(services.announcer is RecordingAnnouncer, "tests never speak through VoiceOver")
    }
}
