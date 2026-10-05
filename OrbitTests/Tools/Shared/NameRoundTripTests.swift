import Foundation
import Testing
@testable import Orbit

/// Names the model was shown can be named back: lists show the user's names
/// without invisible format characters (the joiners inside emoji such as
/// 🧑‍💻) and with < > as ‹ ›, and the shortcut, folder, album, calendar and
/// list matchers accept exactly that form; an ambiguous one stays ambiguous.
@Suite("Names as the model was shown them")
struct NameRoundTripTests {
    typealias T = CalendarTest

    static let coder = ShortcutInfo(name: "🧑‍💻 Arbeit starten", identifier: "C0DE")
    static let project = ShortcutInfo(name: "Notiz <Projekt>", identifier: "P1")

    /// The line list_shortcuts gives with `word`, without its "- ".
    private func listed(_ word: String, in service: MockShortcuts) async throws -> String {
        let text = try await ListShortcutsTool(context: ShortcutToolsTests.context(service)).run(arguments: ToolArguments()).text
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("- ") && $0.contains(word) })
        return String(line.dropFirst(2))
    }

    @Test func aShortcutRunsByTheNameTheListShowed() async throws {
        let service = MockShortcuts([Self.coder, Self.project, ShortcutInfo(name: "Wetter heute", identifier: "W")])
        let shownCoder = try await listed("Arbeit starten", in: service)
        #expect(shownCoder == "🧑💻 Arbeit starten" && shownCoder != Self.coder.name, "the joiner is not shown")
        let shownProject = try await listed("Notiz", in: service)
        #expect(shownProject == "Notiz ‹Projekt›")

        let tool = RunShortcutTool(context: ShortcutToolsTests.context(service))
        let prepared = try await tool.prepareForConfirmation(ToolArguments(["name": .string(shownCoder)]))
        #expect(prepared["name"] == .string(Self.coder.name), "the card names the shortcut as it is")
        _ = try await tool.run(arguments: prepared)
        #expect(service.runs.map(\.identifier) == ["C0DE"])
        #expect(ShortcutMatching.resolve(shownProject, in: [Self.project]) == .found(Self.project))
        #expect(ShortcutMatching.resolve("notiz ‹projekt›", in: [Self.project]) == .found(Self.project), "case is ignored")
        #expect(ShortcutMatching.resolve("Notiz Projekt", in: [Self.project]) == .notFound, "still never a guess")
    }

    @Test func namesThatLookTheSameStayAmbiguous() {
        let joiner = ShortcutInfo(name: "🧑\u{200D}💻 Arbeit", identifier: "a")
        let wordJoiner = ShortcutInfo(name: "🧑\u{2060}💻 Arbeit", identifier: "b")
        #expect(ShortcutMatching.resolve("🧑💻 Arbeit", in: [joiner, wordJoiner]) == .ambiguous([joiner, wordJoiner]))
        #expect(ShortcutMatching.resolve(joiner.name, in: [joiner, wordJoiner]) == .found(joiner), "the exact name wins")
    }

    @Test func aFolderByTheNameTheListShowed() async throws {
        let folder = ShortcutFolder(name: "🏳️‍🌈 Pride <2025>", identifier: "F")
        let service = MockShortcuts([Self.coder], folders: [folder], members: [folder.name: [Self.coder.name]])
        let all = try await ListShortcutsTool(context: ShortcutToolsTests.context(service)).run(arguments: ToolArguments()).text
        let shown = TurnContext.inline(folder.name, maxCharacters: 100)
        #expect(all.contains("Folders: \"\(shown)\"."))
        #expect(ShortcutMatching.folder(shown, in: [folder]) == folder)
        let inFolder = try await ListShortcutsTool(context: ShortcutToolsTests.context(service))
            .run(arguments: ToolArguments(["folder": .string(shown)]))
        #expect(inFolder.text.contains("- 🧑💻 Arbeit starten"))
    }

    @Test func anAlbumByTheNameTheModelWasShown() {
        let family = PhotoAlbum(identifier: "a", title: "👨‍👩‍👧 Urlaub", kind: .user)
        let other = PhotoAlbum(identifier: "b", title: "Rezepte <alt>", kind: .user)
        let shownFamily = CalendarText.inline(family.title, maxCharacters: 100)
        #expect(shownFamily != family.title)
        #expect(PhotoAlbumMatching.resolve(shownFamily, in: [family, other]) == .found([family]))
        #expect(PhotoAlbumMatching.resolve("Rezepte ‹alt›", in: [family, other]) == .found([other]))
    }

    @Test func aCalendarAndAListByTheNameTheModelWasShown() async throws {
        let family = CalendarInfo(identifier: "cal-family", title: "👨‍👩‍👧 Familie", source: "iCloud")
        let store = MockCalendarStore(calendars: [T.privat, family], lists: [T.erinnerungen, family],
                                      events: [T.event("e1", "Elternabend", "2026-10-05T19:00", "2026-10-05T20:00", calendar: family)])
        // What the model reads when it names a calendar that does not exist …
        let listing = CalendarMatching.notFoundMessage("x", among: [T.privat, family], entity: .events, withoutIt: "…")
        let shown = CalendarText.inline(family.title, maxCharacters: 100)
        #expect(listing.contains("\"\(shown)\""))
        // … names it back.
        let prepared = try await T.tool(CreateEventTool.self, store).prepareForConfirmation(ToolArguments([
            "title": "Ausflug", "start": "2026-10-10", "end": "2026-10-10", "calendar": .string(shown),
        ]))
        #expect(prepared["_calendar_id"] == "cal-family")
        let events = try await T.tool(ListEventsTool.self, store).run(arguments: ToolArguments([
            "from": "2026-10-05", "to": "2026-10-05", "calendar": .string(shown),
        ]))
        #expect(events.text.contains("Elternabend"))
        let reminder = try await T.tool(CreateReminderTool.self, store).prepareForConfirmation(ToolArguments([
            "title": "Kuchen backen", "list": .string(shown),
        ]))
        #expect(reminder["_calendar_id"] == "cal-family")
    }
}
