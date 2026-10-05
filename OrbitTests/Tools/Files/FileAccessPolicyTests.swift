import Foundation
import os
import Testing
@testable import Orbit

@Suite("FileAccessPolicy")
struct FileAccessPolicyTests {
    typealias Denial = FileAccessPolicy.Denial

    let policy = FileAccessPolicy(homeDirectory: "/Users/test",
                                  orbitDataDirectory: "/Users/test/Library/Application Support/Orbit")

    @Test(arguments: [
        // Allowed
        ("/Users/test/Documents/Rechnung.pdf", nil),
        ("/Users/test/Desktop/Präsentation.key", nil), // a Keynote document (see isKeynoteDocument)
        ("/Users/test/Library/Mobile Documents/com~apple~CloudDocs/Plan.pdf", nil),
        ("/Users/test/Library/CloudStorage/OneDrive/Vertrag.docx", nil),
        ("/Users/test/.config/app/settings.json", nil),
        ("/Users/test/Code/projekt/.venv/lib/x.py", nil),
        ("/Users/test/Documents/Umwelt-Report.pdf", nil),
        ("/Users/test/Documents/Keynote-Vorlagen/Thema.key", nil),
        ("/Users/test/Documents/public.pem.txt", nil),
        ("/Volumes/USB/Fotos/1.jpg", nil),
        // Keychains and credentials
        ("/Users/test/Library/Keychains/login.keychain-db", Denial.secret),
        ("/Library/Keychains/System.keychain", .secret),
        ("/Users/test/Documents/alt.keychain", .secret),
        ("/Users/test/.ssh/id_ed25519", .secret),
        ("/Users/test/.ssh", .secret),
        ("/Users/test/Documents/Backup/id_rsa", .secret),
        ("/Users/test/.gnupg/private-keys-v1.d/x.key", .secret),
        ("/Users/test/.aws/credentials", .secret),
        ("/Users/test/.config/gcloud/credentials.db", .secret),
        ("/Users/test/.azure/accessTokens.json", .secret),
        ("/Users/test/.kube/config", .secret),
        ("/Users/test/.docker/config.json", .secret),
        ("/Users/test/.netrc", .secret),
        ("/Users/test/.npmrc", .secret),
        ("/Users/test/Code/web/.npmrc", .secret),
        ("/Users/test/.pypirc", .secret),
        ("/Users/test/.git-credentials", .secret),
        ("/Users/test/.config/gh/hosts.yml", .secret),
        ("/Users/test/.claude.json", .secret),
        // Password managers and browser profiles
        ("/Users/test/Documents/Passwörter.kdbx", .secret),
        ("/Users/test/Dropbox/1Password.opvault/default/profile.js", .secret),
        ("/Users/test/Documents/export.1pif", .secret),
        ("/Users/test/Documents/Tresor.agilekeychain/data.js", .secret),
        ("/Users/test/Library/Mobile Documents/iCloud~com~agilebits~onepassword/x.json", .secret),
        ("/Users/test/Documents/Bitwarden Export/vault.json", .secret),
        ("/Users/test/Backup/Google/Chrome/Default/Login Data", .secret),
        ("/Users/test/Backup/Firefox/Profiles/abc.default/logins.json", .secret),
        // Keys, certificates, environment files
        ("/Users/test/Code/server.pem", .secret),
        ("/Users/test/Documents/zertifikat.p12", .secret),
        ("/Users/test/Documents/zertifikat.PFX", .secret),
        ("/Users/test/Code/AuthKey_ABC123.p8", .secret),
        ("/Users/test/Code/server.key", .secret),
        ("/Users/test/Code/release.keystore", .secret),
        ("/Users/test/Code/web/.env", .secret),
        ("/Users/test/Code/web/.env.local", .secret),
        ("/Users/test/Code/web/production.env", .secret),
        ("/Users/test/Code/web/.envrc", .secret),
        // ~/Library and Orbit's data
        ("/Users/test/Library/Mail/V10/x.emlx", .library),
        ("/Users/test/Library/Safari/History.db", .library),
        ("/Users/test/Library", .library),
        ("/Users/test/Library/Application Support/Orbit/Orbit.sqlite", .orbitData),
        // Case does not matter (volumes are usually case-insensitive)
        ("/Users/test/.AWS/credentials", .secret),
        ("/USERS/TEST/.ssh/config", .secret),
        ("/Users/test/Documents/SERVER.PEM", .secret),
        ("/Users/test/LIBRARY/Mail/x.emlx", .library),
        ("/Users/test/library/mobile documents/com~apple~CloudDocs/a.pdf", nil),
        ("/Users/test/library/application support/orbit/Orbit.sqlite", .orbitData),
    ] as [(String, Denial?)])
    func readTable(path: String, denial: Denial?) {
        let keynote = path.hasSuffix("Präsentation.key") || path.hasSuffix("Thema.key")
        #expect(policy.rules(for: path, purpose: .read, isKeynoteDocument: keynote) == denial, "\(path)")
    }

    @Test func purposes() {
        let mail = "/Users/test/Library/Mail/V10/x.emlx"
        let data = "/Users/test/Library/Application Support/Orbit"
        for purpose in [FileAccessPolicy.Purpose.read, .open, .list] {
            #expect(policy.rules(for: mail, purpose: purpose) == .library)
            #expect(policy.rules(for: data, purpose: purpose) == .orbitData)
        }
        // Revealing shows a location in Finder and discloses nothing.
        #expect(policy.rules(for: mail, purpose: .reveal) == nil)
        #expect(policy.rules(for: data, purpose: .reveal) == nil)
        // … but never secrets.
        #expect(policy.rules(for: "/Users/test/.ssh/id_rsa", purpose: .reveal) == .secret)
        #expect(policy.rules(for: "/Users/test/Library/Keychains/login.keychain-db", purpose: .reveal) == .secret)
        #expect(policy.allowsListing("/Users/test/Documents/a.pdf"))
        #expect(!policy.allowsListing("/Users/test/Code/.env"))
    }

    @Test func messagesForTheModel() {
        #expect(Denial.secret.modelMessage.hasPrefix("Access denied: this file may contain passwords"))
        #expect(Denial.library.modelMessage.contains("~/Library"))
        #expect(Denial.orbitData.modelMessage.contains("Orbit's own data"))
        #expect(Denial.outsideScope.modelMessage.contains("outside the folder"))
        #expect(Denial.outsideScope.modelMessage.contains("Use search_files to find files in the allowed folder."))
        #expect(Denial.systemPath.modelMessage.contains("usual path"))
    }

    // MARK: Alias spellings

    @Test(arguments: [
        "/System/Volumes/Data/Users/test/Documents/a.pdf", "/System/Volumes/Data", "/SYSTEM/VOLUMES/data/Users/test/.aws",
        "/dev/fd/3", "/dev/stdin", "/.vol/16777231/2/Users/test/a.pdf", "/.nofollow/Users/test/a.pdf",
        "/.resolve/1/Users/test/a.pdf", "/.anything/Users/test/a.pdf",
    ])
    func systemAliasPathsAreRefused(path: String) {
        for purpose in [FileAccessPolicy.Purpose.read, .open, .reveal, .list] {
            #expect(policy.rules(for: path, purpose: purpose) == .systemPath, "\(purpose)")
        }
    }

    @Test func usualPathsAreNoSystemPaths() {
        #expect(policy.rules(for: "/Volumes/USB/Fotos/1.jpg", purpose: .read) == nil)
        #expect(policy.rules(for: "/Users/test/Documents/.versteckt/a.txt", purpose: .read) == nil)
        #expect(policy.rules(for: "/System/Library/Fonts/x.ttf", purpose: .read) == nil)
        #expect(policy.rules(for: "/Users/test/dev/notiz.txt", purpose: .read) == nil)
    }

    /// Files protected only by their location, reached through spellings the
    /// kernel accepts for the same item.
    @Test func aliasSpellingsOfProtectedFilesAreDenied() throws {
        let fake = try FakeHome()
        defer { fake.remove() }
        #expect(fake.policy.check(fake.home + "/Documents/brief.txt", purpose: .read) == nil)
        for (relative, denial) in FakeHome.protectedFiles {
            let path = fake.home + "/" + relative
            #expect(fake.policy.check(path, purpose: .read) == denial, "\(relative)")
            for prefix in FileSystemTricks.aliasPrefixes {
                #expect(FileManager.default.fileExists(atPath: prefix + path), "\(prefix): the kernel accepts this spelling")
                for purpose in [FileAccessPolicy.Purpose.read, .open, .reveal, .list] {
                    #expect(fake.policy.check(prefix + path, purpose: purpose) != nil, "\(prefix) \(relative) \(purpose)")
                }
            }
        }
    }

    /// The item decides, however a link spells its target.
    @Test func linksToAliasSpellingsAreResolved() throws {
        let fake = try FakeHome()
        defer { fake.remove() }
        let link = fake.home + "/Documents/notiz.txt"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "/System/Volumes/Data" + fake.home + "/.aws/credentials")
        #expect(FilePath.canonical(link) == fake.home + "/.aws/credentials")
        #expect(fake.policy.check(link, purpose: .read) == .secret)
        // An open file descriptor of a secret leads to it too.
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: fake.home + "/.kube/config"))
        defer { try? handle.close() }
        #expect(FilePath.canonical("/dev/fd/\(handle.fileDescriptor)") == fake.home + "/.kube/config")
        #expect(fake.policy.check("/dev/fd/\(handle.fileDescriptor)", purpose: .read) != nil)
    }

    /// The repository's fixtures, read-only, through the data volume's firmlink
    /// (a real /Users path in the repository, /private/tmp in a copy).
    @Test func theFixturesThroughTheFirmlinkKeepTheirRules() {
        let root = FileFixtures.root
        let policy = FileAccessPolicy(homeDirectory: root, orbitDataDirectory: root + "/Dokumente")
        #expect(policy.check(root + "/Dokumente/Notizen.md", purpose: .read) == .orbitData)
        let aliased = "/System/Volumes/Data" + root + "/Dokumente/Notizen.md"
        #expect(FilePath.canonical(aliased) == root + "/Dokumente/Notizen.md")
        #expect(policy.check(aliased, purpose: .read) != nil)
    }

    // MARK: File system

    @Test func keynoteDocumentsAreToldApartFromPrivateKeys() throws {
        let folder = try TemporaryFolder("policy-key")
        defer { folder.remove() }
        let zip = try folder.write("Vortrag.key", data: Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00]))
        let pem = try folder.write("server.key", "-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n")
        let package = try folder.makeFolder("Paket.key")
        try folder.write("Paket.key/Index.zip", data: Data([0x50, 0x4B, 0x03, 0x04]))
        for mayDownload in [false, true] {
            #expect(FileAccessPolicy.isKeynoteDocument(atPath: zip.path, mayDownload: mayDownload) == true)
            #expect(FileAccessPolicy.isKeynoteDocument(atPath: pem.path, mayDownload: mayDownload) == false)
            #expect(FileAccessPolicy.isKeynoteDocument(atPath: package.path, mayDownload: mayDownload) == true)
            #expect(FileAccessPolicy.isKeynoteDocument(atPath: folder.path + "/fehlt.key", mayDownload: mayDownload) == false)
        }

        let home = FileAccessPolicy(homeDirectory: "/Users/test", orbitDataDirectory: "/Users/test/Library/Application Support/Orbit")
        #expect(home.check(zip.path, purpose: .read) == nil)
        #expect(home.check(pem.path, purpose: .read) == .secret)
        #expect(home.check(package.path, purpose: .read) == nil)
        #expect(home.check(package.path + "/Index.zip", purpose: .read) == nil)
    }

    // MARK: *.key files: decided without downloading or blocking

    @Test(arguments: [
        (S_IFDIR, 0, false, false, FileAccessPolicy.KeynoteDecision.keynote),
        (S_IFIFO, 10, false, true, .notKeynote),
        (S_IFCHR, 0, false, true, .notKeynote),
        (S_IFSOCK, 0, false, true, .notKeynote),
        (S_IFREG, 300_000, false, false, .keynote),
        // Not downloaded (iCloud Drive, cloud storage): its size still tells, reading it would download it.
        (S_IFREG, 300_000, true, false, .keynote),
        (S_IFREG, 3_000, true, false, .undecided),
        (S_IFREG, 3_000, true, true, .readFirstBytes),
        (S_IFREG, 3_000, false, false, .readFirstBytes),
    ] as [(mode_t, Int64, Bool, Bool, FileAccessPolicy.KeynoteDecision)])
    func keynoteDecisions(type: mode_t, size: Int64, isDataless: Bool, mayDownload: Bool,
                          decision: FileAccessPolicy.KeynoteDecision) {
        #expect(FileAccessPolicy.keynoteDecision(type: type, size: size, isDataless: isDataless, mayDownload: mayDownload)
            == decision)
    }

    @Test func keyFilesAreDecidedFromMetadataFirst() throws {
        let folder = try TemporaryFolder("policy-key-metadata")
        defer { folder.remove() }
        // A pipe stands in for a file whose content is not on the Mac: reading it blocks.
        let pipe = folder.path + "/Präsentation.key"
        try FileSystemTricks.makePipe(at: pipe)
        let answer = OSAllocatedUnfairLock(initialState: [Bool?]())
        #expect(FileSystemTricks.finishes(within: 2, releasing: pipe) {
            let isKeynote = FileAccessPolicy.isKeynoteDocument(atPath: pipe, mayDownload: true)
            answer.withLock { $0 = [isKeynote] }
        }, "a pipe is never opened")
        #expect(answer.withLock { $0 } == [false])

        // A large file is a presentation by its size: this one is not even readable.
        let large = try folder.write("Gross.key", "-----BEGIN PRIVATE KEY-----\n")
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 300_000)
        try handle.close()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: large.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: large.path) }
        #expect(FileAccessPolicy.isKeynoteDocument(atPath: large.path, mayDownload: false) == true)
    }

    /// Listing a search result and revealing an item never wait for a `*.key`
    /// file's content.
    @Test func listingAndRevealingNeverWaitForKeyFiles() throws {
        let folder = try TemporaryFolder("policy-key-listing")
        defer { folder.remove() }
        let pipe = folder.path + "/Projekt Präsentation.key"
        try FileSystemTricks.makePipe(at: pipe)
        let context = FileFixtures.context(root: folder.path)
        let item = SpotlightItem(path: pipe, contentType: "com.apple.iwork.keynote.sffkey",
                                 contentTypeTree: ["com.apple.iwork.keynote.sffkey", "public.data", "public.item"])
        let answers = OSAllocatedUnfairLock(initialState: (listable: Bool?.none, reveal: Denial?.none))
        #expect(FileSystemTricks.finishes(within: 2, releasing: pipe) {
            let listable = context.isListable(item)
            let reveal = context.policy.check(pipe, purpose: .reveal)
            answers.withLock { $0 = (listable, reveal) }
        })
        #expect(answers.withLock { $0.listable } == false)
        #expect(answers.withLock { $0.reveal } == .secret, "a pipe is no Keynote document")
    }

    /// Listing applies the rules before it reads a `*.key` file's first bytes:
    /// one the rules deny anyway is not read at all. Reading moves a file's
    /// access time forward when it lies before the modification, so it is set
    /// into the past first.
    @Test func listingReadsNoKeyFileTheRulesDeny() throws {
        let folder = try TemporaryFolder("policy-key-rules-first")
        defer { folder.remove() }
        let zip = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00])
        let denied = try folder.write("Bitwarden Export/Tresor.key", data: zip)
        let allowed = try folder.write("Vorträge/Plan.key", data: zip)
        let context = FileFixtures.context(root: folder.path)
        let past = 1_577_833_200
        for file in [denied, allowed] {
            var times = [timespec(tv_sec: past, tv_nsec: 0), timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))]
            try #require(utimensat(AT_FDCWD, file.path, &times, 0) == 0)
        }
        func accessTime(_ file: URL) -> Int {
            var info = stat()
            return stat(file.path, &info) == 0 ? info.st_atimespec.tv_sec : -1
        }
        let type = (contentType: "com.apple.iwork.keynote.sffkey", tree: ["com.apple.iwork.keynote.sffkey", "public.data"])
        #expect(!context.isListable(SpotlightItem(path: denied.path, contentType: type.contentType, contentTypeTree: type.tree)))
        #expect(accessTime(denied) == past, "not read")
        #expect(context.isListable(SpotlightItem(path: allowed.path, contentType: type.contentType, contentTypeTree: type.tree)))
        #expect(accessTime(allowed) != past, "read to tell a Keynote document from a private key")
    }

    @Test func symlinksAreResolvedAndBothEndsChecked() throws {
        let folder = try TemporaryFolder("policy-links")
        defer { folder.remove() }
        try folder.write("Geheim/server.pem", "-----BEGIN PRIVATE KEY-----\n")
        try folder.write("Dokumente/brief.txt", "Hallo")
        let manager = FileManager.default
        try manager.createSymbolicLink(atPath: folder.path + "/Dokumente/harmlos.txt", withDestinationPath: "../Geheim/server.pem")
        try manager.createSymbolicLink(atPath: folder.path + "/Dokumente/Tresor", withDestinationPath: "../Geheim")
        try manager.createSymbolicLink(atPath: folder.path + "/Geheim/link.pem", withDestinationPath: "../Dokumente/brief.txt")
        try manager.createSymbolicLink(atPath: folder.path + "/Dokumente/system.txt", withDestinationPath: "/Library/Keychains/System.keychain")

        let policy = FileAccessPolicy(homeDirectory: "/Users/test", orbitDataDirectory: "/Users/test/Library/Application Support/Orbit")
        #expect(policy.check(folder.path + "/Dokumente/brief.txt", purpose: .read) == nil)
        #expect(policy.check(folder.path + "/Dokumente/harmlos.txt", purpose: .read) == .secret, "target is a private key")
        #expect(policy.check(folder.path + "/Dokumente/Tresor/server.pem", purpose: .read) == .secret)
        #expect(policy.check(folder.path + "/Geheim/link.pem", purpose: .read) == .secret, "the link itself looks like a key")
        #expect(policy.check(folder.path + "/Dokumente/system.txt", purpose: .reveal) == .secret, "points into the keychains")
    }

    @Test func theDebugScopeIsCheckedOnTheResolvedPath() throws {
        let folder = try TemporaryFolder("policy-scope")
        defer { folder.remove() }
        let outside = try TemporaryFolder("policy-outside")
        defer { outside.remove() }
        try folder.write("innen.txt", "x")
        try outside.write("aussen.txt", "x")
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/ausweg.txt", withDestinationPath: outside.path + "/aussen.txt")

        let policy = FileAccessPolicy(homeDirectory: "/Users/test", orbitDataDirectory: "/Users/test/Library/Application Support/Orbit",
                                      restriction: folder.path)
        #expect(policy.check(folder.path + "/innen.txt", purpose: .read) == nil)
        // The same folder spelled through the /var → /private/var symlink.
        #expect(policy.check(folder.path.replacingOccurrences(of: "/private/var/", with: "/var/") + "/innen.txt", purpose: .read) == nil)
        #expect(policy.check(outside.path + "/aussen.txt", purpose: .read) == .outsideScope)
        #expect(policy.check(folder.path + "/ausweg.txt", purpose: .reveal) == .outsideScope, "a symlink out of the scope")
        #expect(policy.check(folder.path + "/../x", purpose: .read) == .outsideScope)
        #expect(policy.check("/Users/test/Documents/a.pdf", purpose: .list) == .outsideScope)
        let invalid = FileAccessPolicy(homeDirectory: "/Users/test", orbitDataDirectory: "/x",
                                       restriction: FileSearchScope.invalidRestriction)
        #expect(invalid.check(folder.path + "/innen.txt", purpose: .read) == .outsideScope)
        // Alias spellings are refused as written, before they are resolved, inside the scope or not.
        for prefix in FileSystemTricks.aliasPrefixes {
            #expect(policy.check(prefix + outside.path + "/aussen.txt", purpose: .read) == .systemPath, "\(prefix)")
            #expect(policy.check(prefix + folder.path + "/innen.txt", purpose: .read) == .systemPath, "\(prefix)")
        }
    }

    /// Resolving a path opens the item (`FilePath.canonical`), so a path the
    /// rules deny as written is denied before that: here the protected
    /// folders lead out of the debug scope, and the answer still comes from
    /// the path as written, not from where it leads. `*.key` items are
    /// decided from the item itself.
    @Test func aPathDeniedAsWrittenIsDeniedBeforeItIsResolved() throws {
        let home = try TemporaryFolder("policy-written")
        defer { home.remove() }
        let elsewhere = try TemporaryFolder("policy-written-elsewhere")
        defer { elsewhere.remove() }
        try elsewhere.write("keys/work_key", "FAKE")
        try elsewhere.write("Library/Containers/app/Data/notiz.txt", "x")
        let manager = FileManager.default
        try manager.createSymbolicLink(atPath: home.path + "/.ssh", withDestinationPath: elsewhere.path + "/keys")
        try manager.createSymbolicLink(atPath: home.path + "/Library", withDestinationPath: elsewhere.path + "/Library")
        try home.write("Vortrag.key", "PK\u{3}\u{4}")
        try home.write("server.key", "-----BEGIN PRIVATE KEY-----\n")
        let policy = FileAccessPolicy(homeDirectory: home.path, orbitDataDirectory: home.path + "/Library/Application Support/Orbit",
                                      restriction: home.path)
        #expect(FilePath.canonical(home.path + "/.ssh/work_key") == elsewhere.path + "/keys/work_key", "it leads out of the scope")
        for purpose in [FileAccessPolicy.Purpose.read, .open, .reveal, .list] {
            #expect(policy.check(home.path + "/.ssh/work_key", purpose: purpose) == .secret, "\(purpose)")
            #expect(policy.check(home.path + "/.ssh/fehlt", purpose: purpose) == .secret, "\(purpose)")
        }
        #expect(policy.check(home.path + "/Library/Containers/app/Data/notiz.txt", purpose: .read) == .library)
        #expect(policy.check(home.path + "/Library/Containers/app/Data/notiz.txt", purpose: .reveal) == .outsideScope,
                "revealing is allowed in ~/Library, so the item is resolved and its scope decides")
        #expect(policy.check(home.path + "/Vortrag.key", purpose: .read) == nil, "a Keynote document")
        #expect(policy.check(home.path + "/server.key", purpose: .read) == .secret, "a private key")
    }

    @Test func fixturesAreClassifiedAsIntended() {
        let policy = FileFixtures.context().policy
        #expect(policy.check(FileFixtures.path("Dokumente/Notizen.md"), purpose: .read) == nil)
        #expect(policy.check(FileFixtures.path("Geheim/.env"), purpose: .read) == .secret)
        #expect(policy.check(FileFixtures.path("Geheim/server.pem"), purpose: .read) == .secret)
        #expect(policy.check(FileFixtures.path("Geheim/privat.key"), purpose: .read) == .secret)
        #expect(policy.check(FileFixtures.path("Dokumente/Notiz-Verknuepfung.txt"), purpose: .read) == .secret)
        #expect(policy.check(FileFixtures.path("iWork/Alt-Präsentation.key"), purpose: .read) == nil)
    }
}
