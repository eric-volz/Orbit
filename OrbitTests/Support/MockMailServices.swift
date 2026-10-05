import Foundation
import os
@testable import Orbit

/// Spotlight for mail in tests: whether it is available and what it finds
/// come from the test; every check and query is recorded. Never touches the
/// real index.
final class MockMailSpotlight: MailSpotlightSearching, Sendable {
    typealias Responder = @Sendable (MailSpotlightQuery) throws -> MailSpotlightResults

    private struct State: Sendable {
        var available: Bool
        var responder: Responder
        var queries: [MailSpotlightQuery] = []
        var checks = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(available: Bool = true, _ responder: @escaping Responder = { _ in MailSpotlightResults(items: [], totalCount: 0, isComplete: true) }) {
        state = OSAllocatedUnfairLock(initialState: State(available: available, responder: responder))
    }

    /// Answers with these items (newest first, as Spotlight sorts them).
    convenience init(items: [MailSpotlightItem]) {
        self.init { _ in MailSpotlightResults(items: items, totalCount: items.count, isComplete: true) }
    }

    var queries: [MailSpotlightQuery] { state.withLock { $0.queries } }
    var availabilityChecks: Int { state.withLock { $0.checks } }

    func isAvailable() async -> Bool {
        state.withLock { state in
            state.checks += 1
            return state.available
        }
    }

    var lastKnownAvailability: Bool? {
        state.withLock { $0.checks > 0 ? $0.available : nil }
    }

    func search(_ query: MailSpotlightQuery, timeout: Duration) async throws -> MailSpotlightResults {
        let responder = state.withLock { state in
            state.queries.append(query)
            return state.responder
        }
        try Task.checkCancellation()
        return try responder(query)
    }
}

/// A clipboard for tests: records what was written, never the user's
/// clipboard; with `fails` every write fails.
final class RecordingPasteboard: PasteboardWriting, Sendable {
    private let state: OSAllocatedUnfairLock<(texts: [String], fails: Bool)>

    init(fails: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: ([], fails))
    }

    /// What was written, oldest first (failed writes are not recorded).
    var texts: [String] { state.withLock { $0.texts } }

    func write(_ text: String) async -> Bool {
        state.withLock { state in
            if !state.fails { state.texts.append(text) }
            return !state.fails
        }
    }
}

/// What happened, in order, across mocks (script runs, the panel's hand-off,
/// clipboard writes).
final class EventLog: Sendable {
    private let state = OSAllocatedUnfairLock<[String]>(initialState: [])

    var events: [String] { state.withLock { $0 } }

    func append(_ event: String) {
        state.withLock { $0.append(event) }
    }
}

/// What a tool told the panel about another app's window taking the keyboard
/// (Mail's reply window): "begin <app>", "end opened" / "end failed", also into
/// `log` when one is given. Hands out a new id per hand-off.
final class RecordingKeyboardHandoff: KeyboardHandoffAnnouncing, Sendable {
    private let state = OSAllocatedUnfairLock<(events: [String], ids: [UUID])>(initialState: ([], []))
    let log: EventLog?

    init(log: EventLog? = nil) {
        self.log = log
    }

    var events: [String] { state.withLock { $0.events } }
    /// The ids handed out, and those ended, in order.
    var ids: [UUID] { state.withLock { $0.ids } }

    func beginKeyboardHandoff(to app: String) async -> UUID? {
        let id = UUID()
        record("begin \(app)", id: id)
        return id
    }

    func endKeyboardHandoff(_ handoff: UUID?, opened: Bool) async {
        record(opened ? "end opened" : "end failed", id: handoff)
    }

    private func record(_ event: String, id: UUID?) {
        state.withLock { state in
            state.events.append(event)
            if let id { state.ids.append(id) }
        }
        log?.append(event)
    }
}

/// The invented mail fixtures (OrbitTests/Fixtures/Mail, made by make-fixtures.sh):
/// .emlx files in the layout of Mail's store.
enum MailFixtures {
    static let root: String = {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return FilePath.canonical(tests.appendingPathComponent("Fixtures/Mail").path)
    }()

    static let privateAccount = "0A1B2C3D-0000-4000-8000-0000000000A1"
    static let workAccount = "0A1B2C3D-0000-4000-8000-0000000000B2"
    static let store = "5E6F7A8B-0000-4000-8000-00000000C0DE"

    /// The file of a message: `account` "" for "On My Mac".
    static func path(account: String, mailbox: [String], file: String) -> String {
        let accountFolder = account.isEmpty ? "Mailboxes" : account
        let boxes = mailbox.map { $0 + ".mbox" }.joined(separator: "/")
        return "\(root)/V10/\(accountFolder)/\(boxes)/\(store)/Data/Messages/\(file)"
    }

    static func inbox(_ file: String, account: String = privateAccount) -> String {
        path(account: account, mailbox: ["INBOX"], file: file)
    }

    static func data(_ path: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path))
    }
}

/// Helpers for the mail tools: a context on mocks with a fixed clock.
enum MailTest {
    static let berlin = TimeZone(identifier: "Europe/Berlin")!
    /// 2026-10-03 12:00 in Berlin.
    static let now = FlexibleDate.parse("2026-10-03T12:00:00+02:00")!.date
    static let german = Locale(identifier: "de_DE")

    static func context(_ runner: MockAppleScriptRunner = MockAppleScriptRunner(),
                        spotlight: any MailSpotlightSearching = UnavailableMailSpotlight(),
                        contacts: any ContactBook = MockContactBook(),
                        pasteboard: any PasteboardWriting = RecordingPasteboard(),
                        keyboardHandoff: any KeyboardHandoffAnnouncing = NoKeyboardHandoff(),
                        readFile: @escaping @Sendable (String) -> Data? = { _ in nil }) -> MailToolContext {
        MailToolContext(mail: MailService(runner: runner), spotlight: spotlight, contacts: contacts, pasteboard: pasteboard,
                        keyboardHandoff: keyboardHandoff, now: { now }, timeZone: berlin, locale: german,
                        spotlightTimeout: .seconds(5), readMessageFile: readFile)
    }

    static func tool<T: Tool>(_ type: T.Type, _ context: MailToolContext) -> T {
        MailTools.all(context: context).compactMap { $0 as? T }.first!
    }

    static func json(_ value: some Encodable) -> String {
        String(decoding: try! JSONEncoder().encode(value), as: UTF8.self)
    }

    static func date(_ text: String) -> Date {
        FlexibleDate.parse(text)!.date
    }

    /// One mailbox's batch from `mail-search`.
    static func batch(account: String = MailFixtures.privateAccount, mailbox: [String] = ["INBOX"],
                      _ messages: [(id: Int, date: String, subject: String, sender: String)]) -> MailCandidates.Batch {
        MailCandidates.Batch(account: account, mailbox: mailbox, ids: messages.map(\.id),
                             dates: messages.map { date($0.date).timeIntervalSince1970 },
                             subjects: messages.map(\.subject), senders: messages.map(\.sender))
    }

    static let accounts = [MailCandidates.Account(id: MailFixtures.privateAccount, name: "Privat"),
                           MailCandidates.Account(id: MailFixtures.workAccount, name: "Arbeit")]

    /// A runner that answers `mail-search` with `candidates` and `mail-summaries` from `summaries`.
    static func runner(candidates: MailCandidates,
                       summaries: @escaping @Sendable ([String]) -> MailSummaries = { _ in MailSummaries(rows: []) })
        -> MockAppleScriptRunner {
        MockAppleScriptRunner { script, arguments in
            switch script.name {
            case MailService.searchScript.name: return json(candidates)
            case MailService.summariesScript.name:
                return json(summaries(FakePersonalData.lines(arguments[0])))
            default: throw AppleScriptError.disabled
            }
        }
    }
}
