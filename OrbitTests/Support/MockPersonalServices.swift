import Foundation
import os
@testable import Orbit

/// An AppleScript runner for tests: records every run (script and
/// arguments) and answers from a closure, by default with
/// `AppleScriptError.disabled`. Never starts osascript.
final class MockAppleScriptRunner: AppleScriptRunning, Sendable {
    typealias Responder = @Sendable (AppleScript, [String]) throws -> String

    struct Run: Sendable, Hashable {
        var script: String
        var arguments: [String]
    }

    private let state: OSAllocatedUnfairLock<(runs: [Run], responder: Responder)>

    init(_ responder: @escaping Responder = { _, _ in throw AppleScriptError.disabled }) {
        state = OSAllocatedUnfairLock(initialState: ([], responder))
    }

    /// Answers every run with `output`.
    convenience init(output: String) {
        self.init { _, _ in output }
    }

    var runs: [Run] { state.withLock { $0.runs } }

    func respond(_ responder: @escaping Responder) {
        state.withLock { $0.responder = responder }
    }

    func run(_ script: AppleScript, arguments: [String]) async throws -> String {
        let responder = state.withLock { state in
            state.runs.append(Run(script: script.name, arguments: arguments))
            return state.responder
        }
        try Task.checkCancellation()
        return try responder(script, arguments)
    }
}

/// Contacts from a list (never the Contacts framework), matched like the
/// live and fake books. Records searches and access requests; asking for
/// access turns `.notDetermined` into `grantOnRequest ? .authorized : .denied`.
final class MockContactBook: ContactBook, Sendable {
    private struct State: Sendable {
        var contacts: [ContactRecord]
        var meIdentifier: String?
        var access: ContactsAccess
        var grantOnRequest: Bool
        var queries: [String] = []
        var accessRequests = 0
        var meLookups = 0
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ contacts: [ContactRecord] = [], me: String? = nil, access: ContactsAccess = .authorized,
         grantOnRequest: Bool = true) {
        state = OSAllocatedUnfairLock(initialState: State(contacts: contacts, meIdentifier: me, access: access,
                                                          grantOnRequest: grantOnRequest))
    }

    var queries: [String] { state.withLock { $0.queries } }
    var accessRequests: Int { state.withLock { $0.accessRequests } }
    var meLookups: Int { state.withLock { $0.meLookups } }

    func access() -> ContactsAccess {
        state.withLock { $0.access }
    }

    func requestAccess() async -> ContactsAccess {
        state.withLock { state in
            state.accessRequests += 1
            if state.access == .notDetermined { state.access = state.grantOnRequest ? .authorized : .denied }
            return state.access
        }
    }

    func search(_ query: String, limit: Int) async throws -> [ContactRecord] {
        let (contacts, access) = state.withLock { state in
            state.queries.append(query)
            return (state.contacts, state.access)
        }
        guard access == .authorized else { return [] }
        let kind = ContactMatching.Kind(query)
        return ContactMatching.rank(contacts.filter { ContactMatching.matches($0, kind) }, for: kind, limit: limit)
    }

    func me() async throws -> ContactRecord? {
        let (contacts, id, access) = state.withLock { state in
            state.meLookups += 1
            return (state.contacts, state.meIdentifier, state.access)
        }
        guard access == .authorized, let id else { return nil }
        return contacts.first { $0.identifier == id }
    }
}

/// Invented contacts for tests.
enum SampleContacts {
    static let lisaBeispiel = ContactRecord(
        identifier: "c-lisa-b", name: "Lisa Beispiel", organization: "Beispiel GmbH",
        emails: [.init(label: "Arbeit", value: "lisa.beispiel@example.com"), .init(label: "Privat", value: "lisa@example.org")],
        phones: [.init(label: "Mobil", value: "+49 170 0000001")]
    )
    static let lisaMuster = ContactRecord(
        identifier: "c-lisa-m", name: "Lisa Muster", emails: [.init(label: "Privat", value: "lisa.muster@example.net")]
    )
    static let max = ContactRecord(
        identifier: "c-max", name: "Max Mustermann", emails: [.init(label: nil, value: "max@example.com")],
        phones: [.init(label: "Arbeit", value: "030 0000 0002")]
    )
    static let erika = ContactRecord(identifier: "c-erika", name: "Erika Mustermann",
                                     emails: [.init(label: "Privat", value: "erika@example.org")])
    static let noMail = ContactRecord(identifier: "c-jonas", name: "Jonas Ohnemail",
                                      phones: [.init(label: "Mobil", value: "0151 0000003")])
    static let all = [lisaBeispiel, lisaMuster, max, erika, noMail]
}
