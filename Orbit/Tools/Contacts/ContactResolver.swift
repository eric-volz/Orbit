import Foundation

/// An e-mail address a recipient could mean.
struct EmailCandidate: Sendable, Hashable {
    /// The name of the contact the address belongs to (Mail shows it instead
    /// of the address), never a name merely written before the address.
    var name: String?
    var address: String
    /// The address's label in Contacts ("Arbeit"), if any.
    var label: String?
}

/// What a recipient ("Lisa", "Lisa Müller", "lisa@example.com",
/// "Lisa <lisa@example.com>") stands for.
enum EmailResolution: Sendable, Hashable {
    /// Exactly one address: written as an address, or the only address of the
    /// one contact that matches (an exact full-name match wins over others).
    case resolved(EmailCandidate)
    /// Several contacts or addresses fit (possibly only one address, when the
    /// other matching contacts have none); the user has to choose, because Orbit
    /// never guesses.
    case ambiguous([EmailCandidate])
    /// Contacts match, but none of them has an e-mail address.
    case noAddress(contactNames: [String])
    /// No contact matches.
    case notFound
    /// Orbit may not read contacts (`.denied`, `.notDetermined` when it may
    /// not ask, or `.unavailable` in a restricted debug session).
    case contactsUnavailable(ContactsAccess)
}

/// Turns recipients into e-mail addresses through Contacts. The mail tools
/// use it for `to`, `cc` and senders.
protocol EmailAddressResolving: Sendable {
    func resolve(_ recipient: String) async throws -> EmailResolution
}

/// Resolves recipients with a `ContactBook`.
struct ContactResolver: EmailAddressResolving {
    /// Candidates returned for an ambiguous recipient at most.
    static let candidateLimit = 10
    /// Contacts looked at per recipient.
    static let searchLimit = 25

    let book: any ContactBook
    /// Whether to ask macOS for access when the user has not decided yet
    /// (for tool calls the user started, never for background work).
    var requestsAccess = true

    func resolve(_ recipient: String) async throws -> EmailResolution {
        let text = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = EmailAddress.parse(text) {
            // "Lisa Beispiel <lisa@evil.example>": Mail would show only the name. It is
            // kept only as the name of the contact who has exactly this address.
            let name = parsed.name == nil ? nil : try await contactName(of: parsed.address)
            return .resolved(EmailCandidate(name: name, address: parsed.address))
        }
        guard !text.isEmpty else { return .notFound }
        var access = book.access()
        if access == .notDetermined, requestsAccess {
            access = await book.requestAccess()
        }
        guard access == .authorized else { return .contactsUnavailable(access) }
        let contacts = try await book.search(text, limit: Self.searchLimit)
        return Self.decide(recipient: text, contacts: contacts)
    }

    /// The name of the one contact that has exactly `address`, only when Orbit
    /// may already read Contacts (this never asks); nil otherwise, also when
    /// several contacts have it or the lookup fails.
    private func contactName(of address: String) async throws -> String? {
        guard book.access() == .authorized else { return nil }
        let contacts: [ContactRecord]
        do {
            contacts = try await book.search(address, limit: 2)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        let owners = contacts.filter { contact in
            contact.emails.contains { $0.value.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(address) == .orderedSame }
        }
        guard owners.count == 1 else { return nil }
        return owners[0].name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// The decision for the contacts found for `recipient` (best first). The
    /// recipient is one contact only when exactly one contact was found, or
    /// exactly one has the full name as written (case and accents ignored);
    /// that contact must then have exactly one address. Everything else is
    /// ambiguous, also several contacts of which only one has an address.
    static func decide(recipient: String, contacts: [ContactRecord]) -> EmailResolution {
        guard !contacts.isEmpty else { return .notFound }
        let wanted = folded(recipient)
        let exact = contacts.filter { folded($0.name) == wanted }
        let chosen: ContactRecord? = exact.count == 1 ? exact[0] : (contacts.count == 1 ? contacts[0] : nil)
        let pool = chosen.map { [$0] } ?? (exact.isEmpty ? contacts : exact)
        let candidates = Self.candidates(of: pool)
        guard !candidates.isEmpty else {
            var seen = Set<String>()
            return .noAddress(contactNames: pool.map(\.name).filter { seen.insert($0).inserted })
        }
        if chosen != nil, candidates.count == 1 {
            return .resolved(candidates[0])
        }
        return .ambiguous(Array(candidates.prefix(candidateLimit)))
    }

    /// Every address of the contacts, each address once.
    private static func candidates(of contacts: [ContactRecord]) -> [EmailCandidate] {
        var seen = Set<String>()
        var result: [EmailCandidate] = []
        for contact in contacts {
            for email in contact.emails where seen.insert(email.value.lowercased()).inserted {
                result.append(EmailCandidate(name: contact.name, address: email.value, label: email.label))
            }
        }
        return result
    }

    /// Case-, accent- and width-insensitive, whitespace collapsed.
    private static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
