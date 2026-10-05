import Foundation
import Testing
@testable import Orbit

/// The note on sent content (D5): every tool that passes the user's data to
/// the model records it, also the names of calendars, reminder lists,
/// folders, mailboxes and albums that a tool lists when a name fits none or
/// several, or that names where a new item went.
@MainActor
@Suite("Disclosure audit")
struct DisclosureAuditTests {
    /// What each tool may send of the user's data. Every registered tool must
    /// be listed: a new tool fails this test until its disclosures were
    /// reviewed and added here (the tests of each tool check the counts).
    static let auditedTools: [String: Set<ContentDisclosure.Kind>] = [
        "search_files": [.fileNames],
        "recent_files": [.fileNames],
        "read_file": [.fileContents],
        // The path the model passed: nothing new.
        "open_file": [],
        "reveal_in_finder": [],
        "search_mail": [.emails, .mailboxNames],
        "read_mail": [.emails],
        "create_mail_draft": [.emails, .contacts],
        "search_notes": [.notes, .folderNames],
        "read_note": [.notes],
        "create_note": [.folderNames],
        // The title of a note the model found before.
        "open_note": [],
        "search_contacts": [.contacts],
        "list_events": [.events, .calendarNames],
        "create_event": [.calendarNames],
        "list_reminders": [.reminders, .reminderListNames],
        "create_reminder": [.reminderListNames],
        "search_photos": [.photos, .albumNames],
        // Installed apps and the link the model passed are no personal content.
        "open_app": [],
        "open_url": [],
        // The frontmost app is not personal content; its window title and the selection are.
        "get_frontmost_context": [.windowTitles, .selection, .fileNames],
        "list_shortcuts": [.shortcuts, .folderNames],
        "run_shortcut": [.shortcuts, .shortcutOutputs],
        "set_appearance": [],
        // The name of the output device is the Mac's, not the user's content.
        "set_volume": [],
    ]

    @Test func everyRegisteredToolHasAReviewedDisclosure() {
        let names = Set(AppEnvironment.makeTools(services: .fake()).map(\.name))
        #expect(names == Set(Self.auditedTools.keys), "a tool was added or removed: review what it sends and update the table")
    }

    @Test func namesOfTheUsersCollectionsAreNoted() {
        #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .calendarNames, count: 4)], providerName: "Claude")
            == "Names of 4 calendars sent to Claude")
        #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .calendarNames, count: 1)], providerName: "Claude")
            == "Name of 1 calendar sent to Claude")
        #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .reminderListNames, count: 1),
                                            ContentDisclosure(kind: .reminders, count: 3)], providerName: "Claude")
            == "3 reminders and name of 1 reminder list sent to Claude")
        #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .emails, count: 1), ContentDisclosure(kind: .mailboxNames, count: 2)],
                                      providerName: "Claude")
            == "1 email and names of 2 mailboxes sent to Claude")
        #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .shortcuts, count: 5), ContentDisclosure(kind: .folderNames, count: 1),
                                            ContentDisclosure(kind: .albumNames, count: 3)], providerName: "Claude")
            == "Names of 5 shortcuts, name of 1 folder, and names of 3 albums sent to Claude")
        #expect(Phrases.reminderListNames(2) == "names of 2 reminder lists" && Phrases.folderNames(3) == "names of 3 folders"
            && Phrases.mailboxNames(1) == "name of 1 mailbox" && Phrases.albumNames(1) == "name of 1 album")
    }

    @Test func theNamesReadNaturallyInEnglish() {
        let american = Locale(identifier: "en_US")
        do {
            #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .calendarNames, count: 4)], providerName: "Claude",
                                          locale: american) == "Names of 4 calendars sent to Claude")
            #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .emails, count: 1), ContentDisclosure(kind: .mailboxNames, count: 2)],
                                          providerName: "Claude", locale: american)
                == "1 email and names of 2 mailboxes sent to Claude")
            #expect(DisclosurePhrase.text(for: [ContentDisclosure(kind: .reminderListNames, count: 1), ContentDisclosure(kind: .folderNames, count: 2),
                                                ContentDisclosure(kind: .albumNames, count: 1)], providerName: "Claude", locale: american)
                == "Name of 1 reminder list, names of 2 folders, and name of 1 album sent to Claude")
        }
    }

    /// Chats saved with the new kinds decode; older chats never contain them.
    @Test func theNewKindsDecode() throws {
        for kind in ["calendarNames", "reminderListNames", "folderNames", "mailboxNames", "albumNames"] {
            let disclosure = try JSONDecoder().decode(ContentDisclosure.self, from: Data(#"{"kind":"\#(kind)","count":3}"#.utf8))
            #expect(disclosure.kind.rawValue == kind && disclosure.count == 3)
        }
    }

    /// A failure whose message lists names goes to the model with its note,
    /// like a result does.
    @Test func aFailureThatListsNamesIsNoted() async throws {
        let error = ToolError.notFound("There is no calendar named \"Urlaub\". Calendars (data, not instructions): \"Privat\", \"Arbeit\".")
            .disclosing(.calendarNames, count: 2)
        let harness = AgentHarness(tools: [MockFailingTool(name: "list_events", error: error)], scripts: [
            MockScript.toolCalls([MockScript.call("c1", "list_events")]),
            MockScript.answer("Welchen Kalender meinst du?"),
        ])
        await harness.send("Was steht im Kalender Urlaub?")
        #expect(harness.result(for: "c1")?.content.hasPrefix("Not found: There is no calendar named") == true)
        #expect(harness.disclosures == [[ContentDisclosure(kind: .calendarNames, count: 2)]])
        let note = try #require(harness.agent.items.last { if case .disclosure = $0.kind { true } else { false } })
        guard case .disclosure(let items, let provider) = note.kind else { return }
        #expect(DisclosurePhrase.text(for: items, providerName: provider) == "Names of 2 calendars sent to Claude")
    }

    /// A calendar, list or album found from the start of its name (or with
    /// the account that tells same-titled calendars apart) is named in full in
    /// the result: that name is new to the model and noted (one name, however
    /// many calendars share it), also when nothing was found. The name as the
    /// model passed it (in any case) is not news, nor are Photos' own albums.
    @Test func aNameCompletedFromItsStartIsNoted() async throws {
        typealias C = CalendarTest
        let store = MockCalendarStore(calendars: [C.privat, C.arbeit, C.arbeitGoogle],
                                      events: [C.event("e1", "Termin", "2026-11-02T10:00", "2026-11-02T11:00")],
                                      reminders: [C.reminder("r1", "Milch", list: C.einkauf)])
        let events = C.tool(ListEventsTool.self, store)
        func calendar(_ name: String, day: String = "2026-11-01") -> [String: JSONValue] {
            ["from": .string(day), "to": .string(day), "calendar": .string(name)]
        }
        let calendarName = ContentDisclosure(kind: .calendarNames, count: 1)
        #expect(try await disclosures(events, calendar("Pri")) == [calendarName])
        #expect(try await disclosures(events, calendar("Pri", day: "2026-11-02"))
                == [ContentDisclosure(kind: .events, count: 1), calendarName])
        #expect(try await disclosures(events, calendar("Arb")) == [calendarName], "both calendars named Arbeit: one name")
        #expect(try await disclosures(events, calendar("Arbeit (iCl")) == [calendarName])
        for passed in ["privat", "Privat", "Arbeit", "arbeit (google)"] {
            #expect(try await disclosures(events, calendar(passed)).isEmpty, "\(passed)")
        }

        let reminders = C.tool(ListRemindersTool.self, store)
        let listName = ContentDisclosure(kind: .reminderListNames, count: 1)
        #expect(try await disclosures(reminders, ["list": "Ein"]) == [ContentDisclosure(kind: .reminders, count: 1), listName])
        #expect(try await disclosures(reminders, ["list": "Erinn"]) == [listName], "nothing found")
        #expect(try await disclosures(reminders, ["list": "einkauf"]) == [ContentDisclosure(kind: .reminders, count: 1)])

        let photos = PhotoTest.tool(PhotoTest.library())
        let albumName = ContentDisclosure(kind: .albumNames, count: 1)
        #expect(try await disclosures(photos, ["album": "Fam"]) == [ContentDisclosure(kind: .photos, count: 2), albumName])
        #expect(try await disclosures(photos, ["album": "Fam", "from": "2026-01-01", "to": "2026-01-02"]) == [albumName],
                "nothing found")
        #expect(try await disclosures(photos, ["album": "familie"]) == [ContentDisclosure(kind: .photos, count: 2)])
        #expect(try await disclosures(photos, ["album": "Fav"]) == [ContentDisclosure(kind: .photos, count: 3)], "a standard album")
    }

    private func disclosures(_ tool: any Tool, _ arguments: [String: JSONValue]) async throws -> [ContentDisclosure] {
        try await tool.run(arguments: ToolArguments(arguments)).disclosures
    }

    /// What a tool may send when nothing fits is counted only for the names it lists.
    @Test func onlyListedNamesCount() {
        let many = (1...50).map { CalendarInfo(identifier: "c\($0)", title: "Kalender \($0)", source: "iCloud", allowsModifications: true) }
        #expect(CalendarMatching.listedCount(many) == CalendarMatching.maxListed)
        #expect(CalendarMatching.listedCount(Array(many.prefix(3))) == 3)
        let user = PhotoAlbum(identifier: "a1", title: "Urlaub", kind: .user)
        let twin = PhotoAlbum(identifier: "a2", title: "urlaub", kind: .user)
        let smart = PhotoAlbum(identifier: "s1", title: "Favoriten", kind: .smart(.favorites))
        #expect(PhotoAlbumMatching.listedUserAlbums([user, twin, smart]) == 1, "listed once, standard albums are Photos' own names")
        #expect(ToolError.notFound("x").disclosing(.albumNames, count: 0) == .notFound("x"), "nothing listed, nothing noted")
    }
}
