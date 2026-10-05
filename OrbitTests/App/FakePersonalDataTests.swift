import Foundation
import Testing
@testable import Orbit

/// The DEBUG fake-data mode on the invented fixtures in
/// OrbitTests/Fixtures/PersonalData, also the folder for end-to-end runs.
@Suite("Fake personal data (DEBUG)")
struct FakePersonalDataTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/PersonalData", isDirectory: true)
    static let launch = Date(timeIntervalSince1970: 1_790_000_000)

    static func data() -> FakePersonalData {
        FakePersonalData(directory: fixtures.path, now: { launch })
    }

    static func notes(_ data: FakePersonalData) -> NotesService {
        NotesService(runner: FakeAppleScriptRunner(data: data), trashFolderNames: ["Recently Deleted"])
    }

    @Test func loadsTheInventedData() throws {
        let data = Self.data()
        #expect(data.errors.isEmpty)
        #expect(data.contacts.count == 6)
        #expect(data.meIdentifier == "orbit-fake-erika")
        #expect(data.defaultFolder == "Notizen")
        #expect(data.folders == ["Notizen", "Rezepte", "Arbeit", "Privat", "Zuletzt gelöscht"])
        #expect(data.contacts.first { $0.name == "Beispiel Handwerk" }?.organization == nil)
        let state = data.stateSummary()
        #expect(state["notes"] == 7)
        #expect(state["contacts"] == 6)
        #expect(state["errors"] == .array([]))
    }

    @Test func relativeAndAbsoluteDates() {
        var errors: [String] = []
        let now = Self.launch
        #expect(FakePersonalData.date("-2d", now: now, errors: &errors) == now.addingTimeInterval(-2 * 86_400))
        #expect(FakePersonalData.date("-3h", now: now, errors: &errors) == now.addingTimeInterval(-3 * 3_600))
        #expect(FakePersonalData.date("+15m", now: now, errors: &errors) == now.addingTimeInterval(15 * 60))
        #expect(FakePersonalData.date("now", now: now, errors: &errors) == now)
        #expect(FakePersonalData.date(nil, now: now, errors: &errors) == now)
        #expect(FakePersonalData.date("2026-09-28T18:30:00+02:00", now: now, errors: &errors)
            == Date(timeIntervalSince1970: 1_790_613_000))
        #expect(errors.isEmpty)
        #expect(FakePersonalData.date("gestern", now: now, errors: &errors) == now)
        #expect(errors.count == 1)
    }

    // MARK: Notes scripts

    @Test func searchesLikeTheScriptNewestFirstWithoutTheTrash() async throws {
        let notes = Self.notes(Self.data())
        let umzug = try await notes.search(terms: ["umzug"], folder: nil, limit: 20, startCharacters: 400)
        #expect(umzug.notes.map(\.name) == ["Einkaufsliste", "Umzug Checkliste"], "the note in the trash is never found")
        #expect(umzug.total == 2)
        #expect(umzug.notes[0].modified == Self.launch.addingTimeInterval(-3_600))
        #expect(umzug.notes[1].start.hasPrefix("Umzug Checkliste\nKartons bestellen"))
        let both = try await notes.search(terms: ["umzug", "kartons"], folder: nil, limit: 20, startCharacters: 400)
        #expect(both.notes.map(\.name) == ["Einkaufsliste", "Umzug Checkliste"])
        let recipes = try await notes.search(terms: [], folder: "rezepte", limit: 20, startCharacters: 10)
        #expect(recipes.notes.map(\.name) == ["Apfelkuchen"])
        #expect(recipes.notes[0].start == "Apfelkuche")
        let all = try await notes.search(terms: [], folder: nil, limit: 3, startCharacters: 0)
        #expect(all.total == 6)
        #expect(all.notes.count == 3)
    }

    /// "Was steht in meiner Rezept-Notiz?" on the fixtures: no note has the word, but "Apfelkuchen" sits in
    /// the folder "Rezepte": the answer names the folders, and listing that folder finds it.
    @Test func aNoteNamedByItsFolderIsFoundThroughTheFolders() async throws {
        let notes = Self.notes(Self.data())
        let nothing = try await notes.search(terms: ["Rezept"], folder: nil, limit: 20, startCharacters: 400)
        #expect(nothing.notes.isEmpty && nothing.folders == ["Notizen", "Rezepte", "Arbeit", "Privat"], "never the trash")
        #expect(try await notes.search(terms: ["umzug"], folder: nil, limit: 20, startCharacters: 400).folders == nil,
                "only when nothing was found")
        #expect(try await notes.search(terms: ["Rezept"], folder: "Arbeit", limit: 20, startCharacters: 400).folders == nil,
                "only for all folders")

        let search = try #require(NotesTools.all(context: NotesToolContext(notes: notes)).first { $0.name == "search_notes" })
        let first = try await search.run(arguments: ToolArguments(["query": "Rezept"]))
        #expect(first.text.contains("The folder \"Rezepte\" fits the words: if the user means the notes in it, list them with folder \"Rezepte\" and query \"*\"."))
        let second = try await search.run(arguments: ToolArguments(["query": "*", "folder": "Rezepte"]))
        #expect(second.summary == "Found 1 note" && second.text.contains("Apfelkuchen"))
    }

    @Test func lockedNotesAreListedButNeverRead() async throws {
        let notes = Self.notes(Self.data())
        let diary = try await notes.search(terms: ["tagebuch"], folder: nil, limit: 20, startCharacters: 400)
        #expect(diary.notes.map(\.isLocked) == [true])
        #expect(diary.notes[0].start == "")
        #expect(try await notes.search(terms: ["gesperrt"], folder: nil, limit: 20, startCharacters: 400).notes.isEmpty)
        let content = try await notes.read(id: "x-coredata://ORBIT-FAKE/ICNote/p5", maxBodyCharacters: 10_000)
        #expect(content.isLocked)
        #expect(content.body == "")
    }

    @Test func createdNotesAreRecordedAndFoundAfterwards() async throws {
        let data = Self.data()
        let notes = Self.notes(data)
        let created = try await notes.create(html: NoteText.html(title: "Geschenkideen", body: "Buch für Max"), folder: "privat")
        #expect(created == CreatedNote(id: "x-coredata://ORBIT-FAKE/ICNote/c1", name: "Geschenkideen", folder: "Privat"))
        let found = try await notes.search(terms: ["geschenk"], folder: nil, limit: 20, startCharacters: 400)
        #expect(found.notes.map(\.id) == ["x-coredata://ORBIT-FAKE/ICNote/c1"])
        try await notes.open(id: created.id)
        let state = data.stateSummary()
        #expect(state["createdNotes"] == .array([["id": "x-coredata://ORBIT-FAKE/ICNote/c1", "name": "Geschenkideen",
                                                   "folder": "Privat", "text": "Geschenkideen\nBuch für Max"]]))
        #expect(state["openedNotes"] == .array([["id": "x-coredata://ORBIT-FAKE/ICNote/c1", "name": "Geschenkideen"]]))
        #expect(state["scriptRuns"] == .array(["notes-create", "notes-search", "notes-open"]))
    }

    @Test func unknownFoldersAndNotesAnswerLikeTheScripts() async throws {
        let notes = Self.notes(Self.data())
        await #expect(throws: NotesFailure.folderNotFound("Rezpte", existing: ["Notizen", "Rezepte", "Arbeit", "Privat", "Zuletzt gelöscht"])) {
            try await notes.search(terms: [], folder: "Rezpte", limit: 5, startCharacters: 5)
        }
        await #expect(throws: NotesFailure.folderNotFound("Zuletzt gelöscht", existing: ["Notizen", "Rezepte", "Arbeit", "Privat"])) {
            try await notes.create(html: "<div>x</div>", folder: "Zuletzt gelöscht")
        }
        await #expect(throws: NotesFailure.noteNotFound) {
            try await notes.read(id: "x-coredata://ORBIT-FAKE/ICNote/p404", maxBodyCharacters: 10)
        }
    }

    @Test func embeddedImagesAreReadLikeTheScriptReadsThem() async throws {
        let folder = try ClaudeCodeTest.makeDirectory("orbit-fake")
        defer { ClaudeCodeTest.removeDirectory(folder) }
        let photo = "data:image/jpeg;base64," + String(repeating: "QUJD", count: 75_000)
        let html = "<div><h1>Rezept</h1></div><div><img src=\\\"\(photo)\\\"></div><div>Zutaten</div>"
        try #"{"notes": [{"id": "x-coredata://ORBIT-FAKE/ICNote/p1", "body": "\#(html)"}]}"#
            .write(to: folder.appendingPathComponent("notes.json"), atomically: true, encoding: .utf8)
        let notes = Self.notes(FakePersonalData(directory: folder.path))
        let content = try await notes.read(id: "x-coredata://ORBIT-FAKE/ICNote/p1", maxBodyCharacters: ReadNoteTool.maxBodyCharacters)
        #expect(content.body == "<div><h1>Rezept</h1></div><div><img src=\"\"></div><div>Zutaten</div>")
        #expect(content.bodyLength == content.body.count)
    }

    @Test func deniedAutomationIsSimulated() async throws {
        let folder = try ClaudeCodeTest.makeDirectory("orbit-fake")
        defer { ClaudeCodeTest.removeDirectory(folder) }
        try #"{"automation": "denied", "notes": [{"text": "Geheim"}]}"#.write(to: folder.appendingPathComponent("notes.json"),
                                                                           atomically: true, encoding: .utf8)
        let data = FakePersonalData(directory: folder.path)
        let tools = NotesTools.all(context: NotesToolContext(notes: Self.notes(data)))
        let search = try #require(tools.first { $0.name == "search_notes" })
        await #expect(throws: ToolError.permissionDenied(.automationNotes)) {
            try await search.run(arguments: ToolArguments(["query": "*"]))
        }
    }

    @Test func theToolsWorkEndToEndOnTheFakeData() async throws {
        let services = AppServices.live(environment: [FakePersonalData.variable: Self.fixtures.path],
                                        orbitDataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("orbit-fake-data"))
        let tools = AppEnvironment.makeTools(services: services)
        let search = try #require(tools.first { $0.name == "search_notes" })
        let found = try await search.run(arguments: ToolArguments(["query": "apfelkuchen"]))
        #expect(found.summary == "Found 1 note")
        let read = try #require(tools.first { $0.name == "read_note" })
        let text = try await read.run(arguments: ToolArguments(["id": "x-coredata://ORBIT-FAKE/ICNote/p4"])).text
        #expect(text.contains("Siehe Projektseite (https://example.com/orbit)"))
        let contacts = try #require(tools.first { $0.name == "search_contacts" })
        #expect(try await contacts.run(arguments: ToolArguments(["query": "Lisa"])).summary == "Found 2 contacts")
        #expect(await services.contactBook.userName() == "Erika Mustermann")
        let hits = try await services.contacts.search("max", limit: 2)
        #expect(hits.map(\.name) == ["Max Mustermann"])
        #expect(services.debugPersonalDataState?()["scriptRuns"] == .array(["notes-search", "notes-read"]))
    }

    // MARK: Contacts

    @Test func contactsAccessCanBeUndecidedAndIsGrantedOnRequest() async throws {
        let folder = try ClaudeCodeTest.makeDirectory("orbit-fake")
        defer { ClaudeCodeTest.removeDirectory(folder) }
        try #"{"access": "notDetermined", "contacts": [{"name": "Max Mustermann", "emails": [{"value": "max@example.com"}], "isMe": true}]}"#
            .write(to: folder.appendingPathComponent("contacts.json"), atomically: true, encoding: .utf8)
        let data = FakePersonalData(directory: folder.path)
        let book = FakeContactBook(data: data)
        #expect(await book.userName() == nil, "the name never asks for access")
        #expect(try await book.search("Max", limit: 5).isEmpty)
        #expect(try await FakeContactSearch(data: data).search("Max", limit: 2).isEmpty)
        let result = try await SearchContactsTool(context: ContactToolContext(book: book)).run(arguments: ToolArguments(["query": "Max"]))
        #expect(result.summary == "Found 1 contact")
        #expect(data.stateSummary()["contactsAccess"] == "authorized")
        #expect(data.stateSummary()["contactsAccessRequests"] == 1)
        #expect(await book.userName() == "Max Mustermann")
    }

    // MARK: Safety

    @Test func anInvalidFolderGivesEmptyDataNeverTheRealData() async throws {
        for value in ["relative/path", "/nonexistent/orbit-fake-\(UUID().uuidString)"] {
            let data = FakePersonalData(directory: value)
            #expect(data.errors.count == 1)
            #expect(data.contacts.isEmpty)
            let notes = Self.notes(data)
            #expect(try await notes.search(terms: [], folder: nil, limit: 5, startCharacters: 5).total == 0)
        }
        let services = AppServices.live(environment: [FakePersonalData.variable: "/nonexistent/orbit-fake"],
                                        orbitDataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("orbit-fake-data"))
        #expect(services.appleScripts is FakeAppleScriptRunner)
        #expect(services.contactBook is FakeContactBook)
        #expect(services.contacts is FakeContactSearch)
    }

    @Test func brokenFilesAreReported() throws {
        let folder = try ClaudeCodeTest.makeDirectory("orbit-fake")
        defer { ClaudeCodeTest.removeDirectory(folder) }
        try "{ kaputt".write(to: folder.appendingPathComponent("notes.json"), atomically: true, encoding: .utf8)
        let data = FakePersonalData(directory: folder.path)
        #expect(data.errors.count == 1)
        #expect(data.errors.first?.hasPrefix("notes.json could not be read") == true)
    }

    @Test func withoutTheVariableNothingIsFake() {
        #expect(FakePersonalData.fromEnvironment([:]) == nil)
        #expect(FakePersonalData.fromEnvironment([FakePersonalData.variable: "  "]) == nil)
    }

    @Test func theDebugFileScopeAloneKeepsNotesMailAndContactsOff() throws {
        let folder = try TemporaryFolder("fake-scope")
        defer { folder.remove() }
        let services = AppServices.live(environment: [FileSearchScope.debugScopeVariable: folder.path],
                                        orbitDataDirectory: folder.url.appendingPathComponent("Daten"))
        #expect(services.appleScripts is DisabledAppleScriptRunner)
        #expect(services.contactBook is UnavailableContactBook)
        #expect(services.contacts is NoContactSearch)
        #expect(services.debugPersonalDataState == nil)
        let both = AppServices.live(environment: [FileSearchScope.debugScopeVariable: folder.path,
                                                  FakePersonalData.variable: Self.fixtures.path],
                                    orbitDataDirectory: folder.url.appendingPathComponent("Daten"))
        #expect(both.appleScripts is FakeAppleScriptRunner)
        #expect(both.contactBook is FakeContactBook)
    }
}
