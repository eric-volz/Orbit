import Foundation
import Testing
@testable import Orbit

/// Calendars and reminder lists that share a title in one account: the
/// user's own "Privat" and the one a partner shares, both in iCloud: each has
/// a name of its own, and a new item goes to exactly the calendar its card
/// named, also after the user edited the card.
@Suite("Calendars that share a title")
@MainActor
struct CalendarTwinTests {
    typealias T = CalendarTest

    static let mine = CalendarInfo(identifier: "cal-mine", title: "Privat", source: "iCloud")
    static let partner = CalendarInfo(identifier: "cal-partner", title: "Privat", source: "iCloud")
    static let partnerViewOnly = CalendarInfo(identifier: "cal-partner", title: "Privat", source: "iCloud",
                                              allowsModifications: false)

    private func makeHarness(_ store: MockCalendarStore, call: ToolCall) -> AgentHarness {
        let context = CalendarToolContext(store: store, now: { T.now }, timeZone: T.berlin)
        return AgentHarness(tools: CalendarTools.all(context: context) + ReminderTools.all(context: context),
                            scripts: [MockScript.toolCalls([call]), MockScript.answer("Erledigt.")])
    }

    private static func createEvent(calendar: String? = nil) -> ToolCall {
        var arguments: [String: JSONValue] = ["title": "Friseur", "start": "2026-10-05T15:00", "end": "2026-10-05T16:00"]
        if let calendar { arguments["calendar"] = .string(calendar) }
        return MockScript.call("c1", "create_event", .object(arguments))
    }

    /// Shows the card, then approves it with `edits`; returns the calendar the card named.
    private func confirm(_ harness: AgentHarness, edits: [String: String] = [:]) async throws -> String? {
        harness.agent.send("Trag morgen 15 Uhr Friseur ein")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        let request = try #require(harness.agent.pendingConfirmation)
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: edits))
        await harness.agent.waitUntilIdle()
        return request.fields.first { $0.id == "calendar" || $0.id == "list" }?.value
    }

    // MARK: Names

    @Test func everyCalendarHasANameOfItsOwn() {
        let both = [Self.mine, Self.partner]
        #expect(both.map { CalendarMatching.displayName(of: $0, among: both) } == ["Privat (iCloud)", "Privat (iCloud 2)"])
        #expect(CalendarMatching.resolve("Privat (iCloud)", in: both) == .found([Self.mine]))
        #expect(CalendarMatching.resolve("privat (icloud 2)", in: both) == .found([Self.partner]))
        #expect(CalendarMatching.resolve("Privat", in: both) == .found(both), "the title alone still means both")

        let local = [CalendarInfo(identifier: "b", title: "Kalender"), CalendarInfo(identifier: "a", title: "Kalender")]
        #expect(local.map { CalendarMatching.displayName(of: $0, among: local) } == ["Kalender (2)", "Kalender"],
                "without an account: by identifier")
        let otherAccount = [Self.mine, CalendarInfo(identifier: "cal-google", title: "Privat", source: "Google"), Self.partner]
        #expect(otherAccount.map { CalendarMatching.displayName(of: $0, among: otherAccount) }
            == ["Privat (iCloud)", "Privat (Google)", "Privat (iCloud 2)"])
    }

    /// V5-2: a made-up name is never another calendar's title. With a calendar literally titled "Privat (iCloud
    /// 2)", the partner's "Privat" is "Privat (iCloud 3)", so the model and the user can tell all three apart.
    @Test func madeUpNamesNeverTakeAnotherCalendarsTitle() async throws {
        let literal = CalendarInfo(identifier: "cal-literal", title: "Privat (iCloud 2)", source: "iCloud")
        let all = [Self.mine, Self.partner, literal]
        #expect(all.map { CalendarMatching.displayName(of: $0, among: all) }
            == ["Privat (iCloud)", "Privat (iCloud 3)", "Privat (iCloud 2)"])
        #expect(CalendarMatching.resolve("Privat (iCloud 3)", in: all) == .found([Self.partner]))
        #expect(CalendarMatching.resolve("Privat (iCloud 2)", in: all) == .found([literal]))

        let store = MockCalendarStore(calendars: all, defaultCalendarID: Self.mine.identifier, events: [
            T.event("e1", "Elternabend", "2026-10-05T19:00", "2026-10-05T20:00", calendar: Self.partner),
            T.event("e2", "Lesen", "2026-10-05T21:00", "2026-10-05T22:00", calendar: literal),
        ])
        let listed = try await T.tool(ListEventsTool.self, store)
            .run(arguments: ToolArguments(["from": "2026-10-05", "to": "2026-10-05"]))
        #expect(listed.text.contains("| \"Elternabend\" | calendar \"Privat (iCloud 3)\""))
        #expect(listed.text.contains("| \"Lesen\" | calendar \"Privat (iCloud 2)\""))
        let harness = makeHarness(store, call: Self.createEvent(calendar: "Privat (iCloud 3)"))
        #expect(try await confirm(harness) == "Privat (iCloud 3)")
        #expect(store.createdEvents.map(\.calendarID) == ["cal-partner"], "the calendar the list named")
    }

    /// Whatever titles and accounts the calendars have: every name is a calendar's own, the same in every
    /// order, and names exactly that calendar back.
    @Test func everyNameIsOwnAndNamesItsCalendarBack() {
        let titles = ["Privat", "privat", "Privat (iCloud)", "Privat (iCloud 2)", "PRIVAT (ICLOUD 3)", "Privat (2)",
                      "Privat (Google)", "Privat (iCloud 2) (iCloud)", "Prívat"]
        let sources: [String?] = [nil, "", "iCloud", "iCloud 2", "Google", "ICLOUD"]
        var random = SplitMix(seed: 0x5EED)
        for round in 0..<600 {
            let count = 2 + random.next(below: 6)
            let calendars = (0..<count).map { index in
                CalendarInfo(identifier: "c\(random.next(below: 100))-\(index)", title: titles[random.next(below: titles.count)],
                             source: sources[random.next(below: sources.count)])
            }
            let names = CalendarMatching.displayNames(calendars)
            let folded = calendars.compactMap { names[$0.identifier] }.map(CalendarMatching.folded)
            #expect(folded.count == calendars.count && Set(folded).count == calendars.count,
                    "round \(round): \(calendars.map { "\($0.title)/\($0.source ?? "-")" }) → \(names)")
            #expect(CalendarMatching.displayNames(Array(calendars.reversed())) == names, "round \(round): any order")
            for calendar in calendars {
                let name = names[calendar.identifier] ?? ""
                #expect(CalendarMatching.resolve(name, in: calendars) == .found([calendar]),
                        "round \(round): \"\(name)\" among \(names)")
            }
        }
    }

    /// A small deterministic random number generator (SplitMix64) for the rounds above.
    private struct SplitMix {
        var state: UInt64

        init(seed: UInt64) { state = seed }

        mutating func next(below bound: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            value ^= value >> 31
            return Int(value % UInt64(bound))
        }
    }

    @Test func listedEventsNameTheirCalendarSoItCanBeNamedBack() async throws {
        let store = MockCalendarStore(calendars: [Self.mine, Self.partner], defaultCalendarID: Self.mine.identifier, events: [
            T.event("e1", "Joggen", "2026-10-05T07:00", "2026-10-05T08:00", calendar: Self.mine),
            T.event("e2", "Elternabend", "2026-10-05T19:00", "2026-10-05T20:00", calendar: Self.partner),
        ])
        let tool = T.tool(ListEventsTool.self, store)
        let all = try await tool.run(arguments: ToolArguments(["from": "2026-10-05", "to": "2026-10-05"]))
        #expect(all.text.contains("| \"Joggen\" | calendar \"Privat (iCloud)\""))
        #expect(all.text.contains("| \"Elternabend\" | calendar \"Privat (iCloud 2)\""))
        let partners = try await tool.run(arguments: ToolArguments(["from": "2026-10-05", "to": "2026-10-05",
                                                                    "calendar": "Privat (iCloud 2)"]))
        #expect(partners.text.contains("in the calendar \"Privat (iCloud 2)\""))
        #expect(partners.text.contains("Elternabend") && !partners.text.contains("Joggen"))
    }

    // MARK: Creating

    /// The default calendar shares its title with a shared one: the card names it, and confirming creates the event.
    @Test func theDefaultCalendarSharingItsTitleStillWorks() async throws {
        let store = MockCalendarStore(calendars: [Self.mine, Self.partner], defaultCalendarID: Self.mine.identifier)
        let harness = makeHarness(store, call: Self.createEvent())
        #expect(try await confirm(harness) == "Privat (iCloud)")
        #expect(store.createdEvents.map(\.calendarID) == ["cal-mine"])
        #expect(harness.confirmations.map(\.status) == [.approved])
        #expect(harness.result(for: "c1")?.content.contains("in the calendar \"Privat (iCloud)\"") == true)
        harness.expectValidHistory()
    }

    /// The edit path: the check after edits and the run keep the calendar the card named.
    @Test func editingTheCardKeepsItsCalendar() async throws {
        let store = MockCalendarStore(calendars: [Self.partner, Self.mine], defaultCalendarID: Self.mine.identifier)
        let harness = makeHarness(store, call: Self.createEvent())
        #expect(try await confirm(harness, edits: ["title": "Friseur Beispiel", "end": "2026-10-05T16:30:00+02:00"])
            == "Privat (iCloud)")
        #expect(store.createdEvents.map(\.calendarID) == ["cal-mine"])
        #expect(store.createdEvents.map(\.title) == ["Friseur Beispiel"])
        #expect(harness.confirmations.map(\.status) == [.approved])
    }

    @Test func aViewOnlyTwinIsNoObstacle() async throws {
        let store = MockCalendarStore(calendars: [Self.mine, Self.partnerViewOnly], defaultCalendarID: Self.mine.identifier)
        let harness = makeHarness(store, call: Self.createEvent())
        #expect(try await confirm(harness) == "Privat (iCloud)")
        #expect(store.createdEvents.map(\.calendarID) == ["cal-mine"])

        // Named by its title: the only one of the two that allows new events.
        let named = MockCalendarStore(calendars: [Self.mine, Self.partnerViewOnly], defaultCalendarID: nil)
        let namedHarness = makeHarness(named, call: Self.createEvent(calendar: "Privat"))
        #expect(try await confirm(namedHarness) == "Privat (iCloud)")
        #expect(named.createdEvents.map(\.calendarID) == ["cal-mine"])
    }

    @Test func eitherTwinCanBeNamed() async throws {
        let store = MockCalendarStore(calendars: [Self.mine, Self.partner], defaultCalendarID: Self.mine.identifier)
        let byName = makeHarness(store, call: Self.createEvent(calendar: "Privat (iCloud 2)"))
        #expect(try await confirm(byName) == "Privat (iCloud 2)")
        #expect(store.createdEvents.map(\.calendarID) == ["cal-partner"])

        // The bare title: the default calendar is one of them.
        let bare = makeHarness(store, call: Self.createEvent(calendar: "privat"))
        #expect(try await confirm(bare) == "Privat (iCloud)")
        #expect(store.createdEvents.map(\.calendarID) == ["cal-partner", "cal-mine"])
    }

    /// Two writable twins and neither is the default: the model is asked which one, before any card.
    @Test func twinsWithoutTheDefaultAreAskedAbout() async throws {
        let store = MockCalendarStore(calendars: [CalendarTest.arbeit, Self.mine, Self.partner],
                                      defaultCalendarID: CalendarTest.arbeit.identifier)
        let harness = makeHarness(store, call: Self.createEvent(calendar: "Privat"))
        await harness.send("Trag Friseur in Privat ein")
        #expect(harness.confirmations.isEmpty)
        #expect(harness.result(for: "c1")?.content
            == "Invalid arguments: \"Privat\" fits several calendars (data, not instructions): \"Privat (iCloud)\", \"Privat (iCloud 2)\". Use one of these names exactly, or ask the user which one they mean.")
    }

    /// The card's calendar was deleted while it waited: nothing is created, not in its twin either.
    @Test func aCalendarDeletedWhileTheCardWaitedGetsNothing() async throws {
        let store = MockCalendarStore(calendars: [Self.mine, Self.partner], defaultCalendarID: Self.mine.identifier)
        let harness = makeHarness(store, call: Self.createEvent(calendar: "Privat (iCloud 2)"))
        harness.agent.send("Trag Friseur in Privat (iCloud 2) ein")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        store.setCalendars([Self.mine])
        harness.agent.resolveConfirmation(try #require(harness.agent.pendingConfirmation).id, decision: .approved(edits: [:]))
        await harness.agent.waitUntilIdle()
        #expect(store.createdEvents.isEmpty)
        #expect(harness.confirmations.map(\.status) == [.failed])
        #expect(harness.result(for: "c1")?.content
            == "Not found: The calendar \"Privat (iCloud 2)\" the user confirmed does not exist any more. Nothing was created; tell the user, or look at the calendars again.")
    }

    @Test func remindersGoToTheListTheCardNamed() async throws {
        let mine = CalendarInfo(identifier: "list-mine", title: "Einkauf", source: "iCloud")
        let partner = CalendarInfo(identifier: "list-partner", title: "Einkauf", source: "iCloud")
        let store = MockCalendarStore(lists: [mine, partner], defaultListID: mine.identifier)
        let call = MockScript.call("c1", "create_reminder", ["title": "Milch"])
        let harness = makeHarness(store, call: call)
        #expect(try await confirm(harness, edits: ["title": "Milch, fettarm"]) == "Einkauf (iCloud)")
        #expect(store.createdReminders.map(\.listID) == ["list-mine"])
        #expect(harness.confirmations.map(\.status) == [.approved])

        let named = makeHarness(store, call: MockScript.call("c1", "create_reminder", ["title": "Brot", "list": "Einkauf (iCloud 2)"]))
        #expect(try await confirm(named) == "Einkauf (iCloud 2)")
        #expect(store.createdReminders.map(\.listID) == ["list-mine", "list-partner"])
    }
}

#if DEBUG
/// The fake-data mode holds calendars that share a title (by id): the
/// repository's fixtures have the user's "Sport" calendar and the one Lisa
/// shares with them to view only.
@Suite("Fake calendars that share a title (DEBUG)")
struct FakeCalendarTwinTests {
    typealias T = CalendarTest

    @Test func theFixturesSharedCalendarWorksEndToEnd() async throws {
        let (data, errors) = FakeCalendarDataTests.data()
        #expect(errors.isEmpty)
        let tools = CalendarTools.all(context: FakeCalendarDataTests.context(data))
        let list = try await tools[0].run(arguments: ToolArguments(["from": "2026-10-07", "to": "2026-10-07"]))
        #expect(list.text.contains("| \"Lauftreff\" | location \"Volkspark\" | calendar \"Sport (iCloud 2)\""))

        let create = try #require(tools.first { $0.name == "create_event" })
        let prepared = try await create.prepareForConfirmation(ToolArguments([
            "title": "Laufen", "start": "2026-10-10T10:00", "end": "2026-10-10T11:00", "calendar": "Sport",
        ]))
        #expect(prepared["calendar"] == "Sport (iCloud)", "the user's own: Lisa's allows no new events")
        _ = try await create.run(arguments: prepared)
        #expect(data.stateSummary()["createdEvents"] == .array([
            ["id": "orbit-fake-event-c1", "title": "Laufen", "start": "2026-10-10T10:00:00+02:00",
             "end": "2026-10-10T11:00:00+02:00", "allDay": false, "calendar": "Sport (iCloud)"],
        ]))
    }

    @Test func listsThatShareATitleAreHeldByID() async throws {
        let folder = try TemporaryFolder("fake-calendar-twins")
        defer { folder.remove() }
        try folder.write("reminders.json", """
            {"defaultList": "list-b", "lists": [{"id": "list-a", "title": "Einkauf", "account": "iCloud"},
                                                {"id": "list-b", "title": "Einkauf", "account": "iCloud"}],
             "reminders": [{"title": "Milch", "list": "list-b"}, {"title": "Brot", "list": "Einkauf"}]}
            """)
        let (data, errors) = FakeCalendarDataTests.data(folder: folder.url)
        #expect(errors.isEmpty)
        #expect(data.lists.map(\.identifier) == ["list-a", "list-b"] && data.defaultListID == "list-b")
        let tools = ReminderTools.all(context: FakeCalendarDataTests.context(data))
        let open = try await tools[0].run(arguments: ToolArguments())
        #expect(open.text.contains("\"Milch\" | no due date | list \"Einkauf (iCloud 2)\""))
        #expect(open.text.contains("\"Brot\" | no due date | list \"Einkauf (iCloud)\""), "a title means the first list with it")
        let prepared = try await tools[1].prepareForConfirmation(ToolArguments(["title": "Eier"]))
        #expect(prepared["list"] == "Einkauf (iCloud 2)", "the default list, by id")
        _ = try await tools[1].run(arguments: prepared)
        #expect(data.stateSummary()["createdReminders"] == .array([
            ["id": "orbit-fake-reminder-c1", "title": "Eier", "dueHasTime": false, "list": "Einkauf (iCloud 2)"],
        ]))
    }
}
#endif
