import Foundation
import Testing
import UniformTypeIdentifiers
@testable import Orbit

@Suite("open_file and reveal_in_finder")
struct OpenFileToolTests {
    typealias Refusal = OpenFileSafety.Refusal

    func open(_ path: String, workspace: MockWorkspace, root: String = FileFixtures.root) async throws -> ToolResult {
        let tool = OpenFileTool(context: FileFixtures.context(root: root, workspace: workspace))
        return try await tool.run(arguments: ToolArguments(["path": .string(path)]))
    }

    func reveal(_ path: String, workspace: MockWorkspace, root: String = FileFixtures.root) async throws -> ToolResult {
        let tool = RevealInFinderTool(context: FileFixtures.context(root: root, workspace: workspace))
        return try await tool.run(arguments: ToolArguments(["path": .string(path)]))
    }

    // MARK: open_file

    @Test func opensDocumentsAndFolders() async throws {
        let workspace = MockWorkspace()
        let result = try await open("~/Rechnungen/Rechnung-Telekom-2026-08.pdf", workspace: workspace)
        #expect(result.text == "Opened ~/Rechnungen/Rechnung-Telekom-2026-08.pdf in its default app.")
        #expect(result.summary == "Opened “Rechnung-Telekom-2026-08.pdf”")
        #expect(result.card == nil)
        #expect(result.disclosure == nil)
        _ = try await open("~/Dokumente", workspace: workspace)
        _ = try await open("~/iWork/Alt-Bericht.pages", workspace: workspace)
        _ = try await open("~/iWork/Alt-Präsentation.key", workspace: workspace)
        #expect(workspace.opened.map(\.path) == [
            FileFixtures.path("Rechnungen/Rechnung-Telekom-2026-08.pdf"), FileFixtures.path("Dokumente"),
            FileFixtures.path("iWork/Alt-Bericht.pages"), FileFixtures.path("iWork/Alt-Präsentation.key"),
        ])
    }

    @Test(arguments: [
        ("~/Programme/Rechner.app", Refusal.application),
        ("~/Programme/Rechner.app/Contents/MacOS/Rechner", .executable),
        ("~/Skripte/aufräumen.command", .script),
        ("~/Skripte/backup", .executable),
        ("~/Skripte/Link.webloc", .link),
        ("~/Skripte/Installer.pkg", .installer),
    ])
    func refusesWhatCouldRunCode(path: String, refusal: Refusal) async throws {
        let workspace = MockWorkspace()
        let result = try await open(path, workspace: workspace)
        #expect(result.isError)
        #expect(result.text == refusal.modelMessage)
        #expect(result.text.contains("reveal_in_finder"))
        #expect(result.summary == "Not opened for security reasons")
        #expect(workspace.opened.isEmpty)
    }

    @Test func refusesSymlinksToPrograms() async throws {
        let folder = try TemporaryFolder("open-link")
        defer { folder.remove() }
        try folder.write("werkzeug", "#!/bin/sh\necho hi\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path + "/werkzeug")
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/Rechnung.pdf", withDestinationPath: "werkzeug")
        let workspace = MockWorkspace()
        let result = try await open("~/Rechnung.pdf", workspace: workspace, root: folder.path)
        #expect(result.text == Refusal.executable.modelMessage)
        #expect(workspace.opened.isEmpty)
    }

    @Test func refusesDeniedPaths() async throws {
        let workspace = MockWorkspace()
        #expect(try await open("~/Geheim/server.pem", workspace: workspace).text == FileAccessPolicy.Denial.secret.modelMessage)
        #expect(try await open("/Library/Orbit-Test-Nothing/Rechner.app", workspace: workspace).text
            == FileAccessPolicy.Denial.outsideScope.modelMessage)
        #expect(workspace.opened.isEmpty)
    }

    /// Other spellings of protected files (no debug scope, like a release build).
    @Test func aliasSpellingsCannotOpenOrRevealProtectedFiles() async throws {
        let fake = try FakeHome()
        defer { fake.remove() }
        let workspace = MockWorkspace()
        let context = fake.context(workspace: workspace)
        for prefix in FileSystemTricks.aliasPrefixes {
            let open = try await OpenFileTool(context: context)
                .run(arguments: ToolArguments(["path": .string(prefix + fake.home + "/.aws/credentials")]))
            let reveal = try await RevealInFinderTool(context: context)
                .run(arguments: ToolArguments(["path": .string(prefix + fake.home + "/.ssh/work_key")]))
            #expect(open.isError, "\(prefix)")
            #expect(reveal.isError, "\(prefix)")
        }
        #expect(workspace.opened.isEmpty)
        #expect(workspace.revealed.isEmpty)
    }

    // MARK: Finder aliases

    /// macOS opens a Finder alias's target, so the target is checked, and opened.
    @Test func aliasesOpenTheirTargetOnlyWhenItMayBeOpened() async throws {
        let folder = try TemporaryFolder("open-alias")
        defer { folder.remove() }
        let outside = try TemporaryFolder("open-alias-outside")
        defer { outside.remove() }
        let script = try folder.write("Skripte/aufraeumen.command", "#!/bin/sh\necho test\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try folder.makeFolder("Programme/Werkzeug.app/Contents")
        let secret = try folder.write("Geheim/server.pem", "-----BEGIN PRIVATE KEY-----\n")
        let document = try folder.write("Dokumente/Plan.pdf", "%PDF-1.4")
        let gone = try folder.write("Dokumente/weg.txt", "x")
        let elsewhere = try outside.write("Plan.pdf", "%PDF-1.4")
        let aliases = folder.url.appendingPathComponent("Dokumente")
        try FileSystemTricks.makeFinderAlias(to: script, at: aliases.appendingPathComponent("Notizen"))
        try FileSystemTricks.makeFinderAlias(to: script, at: aliases.appendingPathComponent("Rechnung.pdf"))
        try FileSystemTricks.makeFinderAlias(to: folder.url.appendingPathComponent("Programme/Werkzeug.app"),
                                             at: aliases.appendingPathComponent("Werkzeug"))
        try FileSystemTricks.makeFinderAlias(to: secret, at: aliases.appendingPathComponent("Schlüssel"))
        try FileSystemTricks.makeFinderAlias(to: elsewhere, at: aliases.appendingPathComponent("Anderswo"))
        try FileSystemTricks.makeFinderAlias(to: gone, at: aliases.appendingPathComponent("Kaputt"))
        try FileManager.default.removeItem(at: gone)
        try FileSystemTricks.makeFinderAlias(to: document, at: aliases.appendingPathComponent("Plan-Alias"))

        let workspace = MockWorkspace()
        let refused: [(name: String, text: String)] = [
            ("Notizen", Refusal.script.modelMessage), ("Rechnung.pdf", Refusal.script.modelMessage),
            ("Werkzeug", Refusal.application.modelMessage), ("Kaputt", Refusal.link.modelMessage),
            ("Schlüssel", FileAccessPolicy.Denial.secret.modelMessage),
            ("Anderswo", FileAccessPolicy.Denial.outsideScope.modelMessage),
        ]
        for (name, text) in refused {
            let result = try await open("~/Dokumente/" + name, workspace: workspace, root: folder.path)
            #expect(result.isError, "\(name)")
            #expect(result.text == text, "\(name)")
        }
        #expect(workspace.opened.isEmpty)

        let result = try await open("~/Dokumente/Plan-Alias", workspace: workspace, root: folder.path)
        #expect(result.text == "Opened ~/Dokumente/Plan-Alias in its default app.")
        #expect(workspace.opened.map(\.path) == [document.path], "the checked target is what opens")
        // Symlinks are no aliases: a link to a document still opens.
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/Dokumente/Plan-Link.pdf", withDestinationPath: "Plan.pdf")
        _ = try await open("~/Dokumente/Plan-Link.pdf", workspace: workspace, root: folder.path)
        #expect(workspace.opened.map(\.path) == [document.path, document.path])
    }

    @Test func aliasesAreOnlyRecognizedByTheirTypeOrFlag() throws {
        let folder = try TemporaryFolder("alias-kind")
        defer { folder.remove() }
        let document = try folder.write("Plan.pdf", "%PDF-1.4")
        let alias = try FileSystemTricks.makeFinderAlias(to: document, at: folder.url.appendingPathComponent("Plan.pdf alias"))
        try FileManager.default.createSymbolicLink(atPath: folder.path + "/Link.pdf", withDestinationPath: "Plan.pdf")
        #expect(OpenFileSafety.isFinderAlias(atPath: alias.path))
        #expect(!OpenFileSafety.isFinderAlias(atPath: folder.path + "/Link.pdf"))
        #expect(!OpenFileSafety.isFinderAlias(atPath: document.path))
        #expect(OpenFileSafety.aliasTarget(ofPath: alias.path) == document.path)
    }

    @Test func reportsWhenMacOSCannotOpenIt() async throws {
        let workspace = MockWorkspace()
        workspace.failOpening()
        await #expect(throws: ToolError.failed("macOS could not open ~/Binaer/daten.bin; there may be no app for this file type. Offer reveal_in_finder instead.")) {
            _ = try await open("~/Binaer/daten.bin", workspace: workspace)
        }
    }

    @Test(arguments: [
        // Extensions
        ("app", UTType.applicationBundle, false, Refusal?.some(.application)),
        ("prefPane", nil, false, .application),
        ("command", nil, false, .script),
        ("tool", nil, false, .script),
        ("sh", nil, false, .script),
        ("py", nil, false, .script),
        ("applescript", nil, false, .script),
        ("terminal", nil, false, .script),
        ("term", nil, false, .script),
        ("workflow", nil, false, .script),
        ("shortcut", nil, false, .script),
        ("wflow", nil, false, .script),
        ("pkg", nil, false, .installer),
        ("mpkg", nil, false, .installer),
        ("webloc", nil, false, .link),
        ("inetloc", nil, false, .link),
        ("fileloc", nil, false, .link),
        ("url", nil, false, .link),
        ("mobileconfig", nil, false, .configuration),
        ("jar", nil, false, .executable),
        // Types without a telling extension
        ("", UTType.unixExecutable, true, .executable),
        ("", UTType.applicationBundle, false, .application),
        ("x", UTType.shellScript, false, .script),
        ("", UTType("com.apple.web-internet-location"), false, .link),
        ("", UTType("com.apple.installer-package-archive"), false, .installer),
        // Terminal opens legacy session files (.term) and may run the command they hold.
        ("", UTType(filenameExtension: "term"), false, .script),
        ("", UTType(filenameExtension: "wflow"), false, .script),
        // The x bit on a file without a document type
        ("", UTType.data, true, .executable),
        ("", nil, true, .executable),
        ("xyzq", UTType(filenameExtension: "xyzq"), true, .executable),
        // Documents
        ("pdf", UTType.pdf, false, nil),
        ("txt", UTType.plainText, true, nil),
        ("pages", UTType(filenameExtension: "pages", conformingTo: .directory), false, nil),
        ("key", UTType(filenameExtension: "key"), false, nil),
        ("", UTType.folder, false, nil),
        ("dmg", UTType(filenameExtension: "dmg"), false, nil),
        ("png", UTType.png, false, nil),
        ("", UTType.data, false, nil),
    ] as [(String, UTType?, Bool, Refusal?)])
    func refusalTable(pathExtension: String, type: UTType?, executable: Bool, refusal: Refusal?) {
        #expect(OpenFileSafety.refusal(contentType: type, pathExtension: pathExtension,
                                       isRegularFileWithExecuteBit: executable) == refusal,
                "\(pathExtension) \(type?.identifier ?? "nil") x=\(executable)")
    }

    @Test func openDefinition() {
        let tool = OpenFileTool(context: FileFixtures.context())
        #expect(tool.name == "open_file")
        #expect(tool.displayName == "Open file")
        #expect(tool.riskLevel == .draft)
        #expect(tool.category == .files)
        #expect(tool.statusText(for: ToolArguments(["path": "~/a/Plan.pdf"])) == "Opening “Plan.pdf”…")
        guard case let .object(properties, required, _) = tool.inputSchema else { Issue.record("not an object"); return }
        #expect(Array(properties.keys) == ["path"])
        #expect(required == ["path"])
        guard case let .string(pathDescription, _, _, _, _)? = properties["path"] else { Issue.record("path"); return }
        #expect(pathDescription == FileToolContext.pathDescription(of: "file or folder"))
        #expect(pathDescription?.contains("call search_files first; do not guess paths") == true)
    }

    // MARK: reveal_in_finder

    @Test func revealsFilesFoldersAndEvenPrograms() async throws {
        let workspace = MockWorkspace()
        let result = try await reveal("~/Rechnungen/Vodafone-Invoice-2026-08.pdf", workspace: workspace)
        #expect(result.text == "Showed ~/Rechnungen/Vodafone-Invoice-2026-08.pdf in Finder.")
        #expect(result.summary == "Shown in Finder")
        #expect(!result.isError)
        _ = try await reveal("~/Rechnungen", workspace: workspace)
        _ = try await reveal("~/Skripte/aufräumen.command", workspace: workspace)
        _ = try await reveal("~/Programme/Rechner.app", workspace: workspace)
        #expect(workspace.revealed.map(\.path) == [
            FileFixtures.path("Rechnungen/Vodafone-Invoice-2026-08.pdf"), FileFixtures.path("Rechnungen"),
            FileFixtures.path("Skripte/aufräumen.command"), FileFixtures.path("Programme/Rechner.app"),
        ])
        #expect(workspace.opened.isEmpty)
    }

    @Test func revealingRespectsSecretsAndTheScope() async throws {
        let workspace = MockWorkspace()
        #expect(try await reveal("~/Geheim/.env", workspace: workspace).text == FileAccessPolicy.Denial.secret.modelMessage)
        #expect(try await reveal("/Users", workspace: workspace).text == FileAccessPolicy.Denial.outsideScope.modelMessage)
        #expect(workspace.revealed.isEmpty)
        await #expect(throws: ToolError.self) { _ = try await reveal("~/fehlt.pdf", workspace: workspace) }
    }

    @Test func revealingInLibraryIsAllowedButOpeningNot() async throws {
        let folder = try TemporaryFolder("reveal-library")
        defer { folder.remove() }
        try folder.write("Library/Application Support/Programm/daten.json", "{}")
        let workspace = MockWorkspace()
        let path = "~/Library/Application Support/Programm/daten.json"
        #expect(try await reveal(path, workspace: workspace, root: folder.path).summary == "Shown in Finder")
        #expect(try await open(path, workspace: workspace, root: folder.path).text == FileAccessPolicy.Denial.library.modelMessage)
        #expect(workspace.revealed.count == 1)
        #expect(workspace.opened.isEmpty)
    }

    @Test func revealDefinition() {
        let tool = RevealInFinderTool(context: FileFixtures.context())
        #expect(tool.name == "reveal_in_finder")
        #expect(tool.displayName == "Show in Finder")
        #expect(tool.riskLevel == .draft)
        #expect(tool.statusText(for: ToolArguments(["path": "/a/Plan.pdf"])) == "Showing “Plan.pdf” in Finder…")
        guard case let .object(properties, _, _) = tool.inputSchema,
              case let .string(pathDescription, _, _, _, _)? = properties["path"] else { Issue.record("path"); return }
        #expect(pathDescription?.contains("call search_files first; do not guess paths") == true)
    }
}
