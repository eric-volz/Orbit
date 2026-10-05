import Foundation
import Testing
@testable import Orbit

/// Result rows show names neutralized for the model (invisible format
/// characters removed, < and > as ‹ ›), so the path the model copies back can
/// differ from the name on disk. The tools match it back to the item, and
/// check that item in full.
@Suite("File paths round-trip")
struct PathRoundTripTests {
    static let names: [(label: String, relative: String)] = [
        ("zero-width joiner", "Pictures/Familie \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}/Angebot Urlaub.txt"),
        ("joiner in a folder", "Documents/Arbeit \u{1F469}\u{200D}\u{1F4BB}/Angebot.txt"),
        ("angle brackets", "Documents/Angebot <final>.txt"),
        ("zero-width non-joiner", "Documents/\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0647}\u{0645} Angebot.txt"),
        ("soft hyphen", "Documents/Ange\u{00AD}bot Möbel.txt"),
        ("left-to-right mark", "Documents/Angebot \u{200E}2026.txt"),
    ]

    @Test(arguments: 0..<names.count)
    func pathsFromSearchResultsWorkInEveryTool(index: Int) async throws {
        let (label, relative) = Self.names[index]
        let home = try TemporaryFolder("roundtrip")
        defer { home.remove() }
        let file = try home.write(relative, "Angebot für Möbel")
        let item = SpotlightItem(path: file.path, contentType: "public.plain-text",
                                 contentTypeTree: ["public.plain-text", "public.text"], modified: Date(), size: 18)
        let spotlight = MockSpotlight { _ in SpotlightResults(items: [item], totalCount: 1, isComplete: true) }
        let workspace = MockWorkspace()
        let context = FileFixtures.context(root: home.path, spotlight: spotlight, workspace: workspace)
        let found = try await SearchFilesTool(context: context).run(arguments: ToolArguments(["query": "Angebot"]))
        let row = try #require(found.text.split(separator: "\n").first { $0.hasPrefix("1. ") })
        let shownPath = try #require(row.split(separator: "|").dropFirst().first).trimmingCharacters(in: .whitespaces)
        #expect(shownPath != "~/" + relative, "\(label): the row shows the path neutralized")

        let read = try await ReadFileTool(context: context).run(arguments: ToolArguments(["path": .string(shownPath)]))
        #expect(read.text.contains("Angebot für Möbel"), "\(label)")
        _ = try await OpenFileTool(context: context).run(arguments: ToolArguments(["path": .string(shownPath)]))
        _ = try await RevealInFinderTool(context: context).run(arguments: ToolArguments(["path": .string(shownPath)]))
        #expect(workspace.opened.map(\.path) == [file.path], "\(label)")
        #expect(workspace.revealed.map(\.path) == [file.path], "\(label)")

        // The folder of that path can be searched too.
        let folder = (shownPath as NSString).deletingLastPathComponent
        _ = try await SearchFilesTool(context: context).run(arguments: ToolArguments(["query": "*", "folder": .string(folder)]))
        #expect(spotlight.queries.last?.scopes.map(\.path) == [file.deletingLastPathComponent().path], "\(label)")
    }

    /// The item a path is matched to gets the full check: symlinks resolved,
    /// secrets and the debug scope. A denied match is not found, like no match.
    @Test func aMatchedItemIsCheckedInFull() async throws {
        let home = try TemporaryFolder("roundtrip-policy")
        defer { home.remove() }
        let outside = try TemporaryFolder("roundtrip-outside")
        defer { outside.remove() }
        try home.write("Geheim/server.pem", "-----BEGIN PRIVATE KEY-----\n")
        try home.makeFolder("Dokumente")
        try outside.write("aussen.txt", "draußen")
        let manager = FileManager.default
        try manager.createSymbolicLink(atPath: home.path + "/Dokumente/Notiz <alt>.txt", withDestinationPath: "../Geheim/server.pem")
        try manager.createSymbolicLink(atPath: home.path + "/Dokumente/Ablage <x>", withDestinationPath: outside.path)
        let workspace = MockWorkspace()
        let context = FileFixtures.context(root: home.path, workspace: workspace)

        await #expect(throws: Self.notFound("~/Dokumente/Notiz ‹alt›.txt")) {
            _ = try await ReadFileTool(context: context).run(arguments: ToolArguments(["path": "~/Dokumente/Notiz ‹alt›.txt"]))
        }
        await #expect(throws: Self.notFound("~/Dokumente/Ablage ‹x›/aussen.txt")) {
            _ = try await OpenFileTool(context: context).run(arguments: ToolArguments(["path": "~/Dokumente/Ablage ‹x›/aussen.txt"]))
        }
        await #expect(throws: Self.folderNotFound("~/Dokumente/Ablage ‹x›")) {
            _ = try await SearchFilesTool(context: context).run(arguments: ToolArguments(["query": "*", "folder": "~/Dokumente/Ablage ‹x›"]))
        }
        #expect(workspace.opened.isEmpty)
    }

    /// A protected path disguised with an invisible character passes the
    /// first check and is matched back to the protected item, which must not
    /// tell whether a guessed item exists: an existing one and a missing one
    /// get the answer of a path that matches nothing.
    @Test func disguisedProtectedPathsDoNotTellWhetherTheyExist() async throws {
        let fake = try FakeHome()
        defer { fake.remove() }
        try fake.folder.makeFolder(".ssh/alt")
        let workspace = MockWorkspace()
        let spotlight = MockSpotlight()
        let context = fake.context(spotlight: spotlight, workspace: workspace)
        let hidden = "\u{200B}"
        // (existing, missing): the same disguise, a guessed name that exists and one that does not.
        let paths = [
            ("~/.ss\(hidden)h/work_key", "~/.ss\(hidden)h/nope_key"),
            ("~/.a\(hidden)ws/credentials", "~/.a\(hidden)ws/config"),
            ("~/.ss\(hidden)h", "~/.gn\(hidden)upg"),
            ("~/Libra\(hidden)ry/Preferences/x.txt", "~/Libra\(hidden)ry/Preferences/y.txt"),
            ("~/Libra\(hidden)ry/Application Support/Orbit/notes.txt", "~/Libra\(hidden)ry/Application Support/Orbit/nope.txt"),
        ]
        for (existing, missing) in paths {
            for path in [existing, missing] {
                await #expect(throws: Self.notFound(path), "\(path)") {
                    _ = try await ReadFileTool(context: context).run(arguments: ToolArguments(["path": .string(path)]))
                }
                await #expect(throws: Self.notFound(path), "\(path)") {
                    _ = try await OpenFileTool(context: context).run(arguments: ToolArguments(["path": .string(path)]))
                }
            }
        }
        // Revealing is allowed in ~/Library, never for secrets.
        for path in ["~/.ss\(hidden)h/work_key", "~/.ss\(hidden)h/nope_key", "~/.ku\(hidden)be/config", "~/.ku\(hidden)be/nope"] {
            await #expect(throws: Self.notFound(path), "\(path)") {
                _ = try await RevealInFinderTool(context: context).run(arguments: ToolArguments(["path": .string(path)]))
            }
        }
        for folder in ["~/.ss\(hidden)h/alt", "~/.ss\(hidden)h/neu", "~/Libra\(hidden)ry/Preferences", "~/Libra\(hidden)ry/Prefs"] {
            await #expect(throws: Self.folderNotFound(folder), "\(folder)") {
                _ = try await SearchFilesTool(context: context).run(arguments: ToolArguments(["query": "*", "folder": .string(folder)]))
            }
        }
        #expect(workspace.opened.isEmpty)
        #expect(workspace.revealed.isEmpty)
        #expect(spotlight.queries.isEmpty)
    }

    /// Matching lists only folders the policy allows for the purpose: never a
    /// secret folder, and ~/Library only to reveal an item.
    @Test func foldersThePolicyDeniesAreNotListed() throws {
        let fake = try FakeHome()
        defer { fake.remove() }
        let context = fake.context()
        let hidden = "\u{200B}"
        // Each needs the protected folder listed to match its second disguised component.
        let key = fake.home + "/.ss\(hidden)h/work\(hidden)_key"
        let preferences = fake.home + "/Libra\(hidden)ry/Prefe\(hidden)rences/x.txt"
        for purpose in [FileAccessPolicy.Purpose.read, .open, .reveal, .list] {
            #expect(context.itemShown(as: key, purpose: purpose) == nil, "\(purpose)")
        }
        for purpose in [FileAccessPolicy.Purpose.read, .open, .list] {
            #expect(context.itemShown(as: preferences, purpose: purpose) == nil, "\(purpose)")
        }
        #expect(context.itemShown(as: preferences, purpose: .reveal) == fake.home + "/Library/Preferences/x.txt")
        #expect(context.itemShown(as: fake.home + "/Docu\(hidden)ments/brief.txt", purpose: .read) == fake.home + "/Documents/brief.txt")
    }

    private static func notFound(_ path: String) -> ToolError {
        .notFound("There is no file or folder at \(FileToolFormat.inline(path, maxCharacters: 1_000)). Use search_files to find it.")
    }

    private static func folderNotFound(_ path: String) -> ToolError {
        .notFound("There is no folder at \(FileToolFormat.inline(path, maxCharacters: 1_000)). \(FileToolContext.folderNamesNote)")
    }

    @Test func anAmbiguousPathIsNotGuessed() async throws {
        let home = try TemporaryFolder("roundtrip-ambiguous")
        defer { home.remove() }
        try home.write("Dokumente/Plan\u{200B}A.txt", "eins")
        try home.write("Dokumente/Plan\u{200C}A.txt", "zwei")
        let context = FileFixtures.context(root: home.path)
        await #expect(throws: ToolError.notFound("There is no file or folder at ~/Dokumente/PlanA.txt. Use search_files to find it.")) {
            _ = try await ReadFileTool(context: context).run(arguments: ToolArguments(["path": "~/Dokumente/PlanA.txt"]))
        }
    }

    @Test func rowsAndMatchingNeutralizeNamesAlike() {
        #expect(FileToolFormat.shownName("Familie \u{1F468}\u{200D}\u{1F469}") == "Familie \u{1F468}\u{1F469}")
        #expect(FileToolFormat.shownName("Angebot <final>.txt") == "Angebot ‹final›.txt")
        #expect(FileToolFormat.shownName("Zeile\nzwei ") == "Zeile zwei")
        let path = "/Users/me/Familie \u{1F468}\u{200D}\u{1F469}/Angebot <final>.txt"
        let shown = FileToolFormat.inline(path, maxCharacters: 1_000)
        #expect(shown == path.split(separator: "/").map { FileToolFormat.shownName(String($0)) }.reduce("") { $0 + "/" + $1 })
    }
}
