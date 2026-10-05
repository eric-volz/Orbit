import Contacts
import Foundation
import os

/// A contact found by name.
struct ContactHit: Sendable, Hashable {
    var identifier: String
    var name: String
    /// An e-mail address or the organization, shown under the name.
    var detail: String?
}

/// Finds contacts by name for instant search. Live: `LiveContactSearch`;
/// tests use a mock (they never call the Contacts framework).
protocol ContactSearching: Sendable {
    /// Contacts whose name matches `text`, best first, at most `limit`. Empty
    /// when Orbit may not read contacts.
    func search(_ text: String, limit: Int) async throws -> [ContactHit]
}

/// Contacts through the Contacts framework, only when the user has already
/// allowed access; it never asks for it. Runs on its own queue, never on the
/// main thread, and reads at most `fetchLimit` matches (the best of them are
/// shown). A limited authorization does not exist on macOS (the SDK marks
/// `CNAuthorizationStatus.limited` unavailable), so only `.authorized` counts.
struct LiveContactSearch: ContactSearching {
    static let fetchLimit = 50
    private static let queue = DispatchQueue(label: "io.github.eric-volz.Orbit.contact-search", qos: .userInitiated)

    func search(_ text: String, limit: Int) async throws -> [ContactHit] {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try Self.fetch(text, limit: limit) })
            }
        }
    }

    private static func fetch(_ text: String, limit: Int) throws -> [ContactHit] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
        let keys: [any CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as NSString,
            CNContactEmailAddressesKey as NSString,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.predicate = CNContact.predicateForContacts(matchingName: text)
        var hits: [ContactHit] = []
        try CNContactStore().enumerateContacts(with: request) { contact, stop in
            if let hit = Self.hit(for: contact) { hits.append(hit) }
            if hits.count >= fetchLimit { stop.pointee = true }
        }
        return ContactRanking.rank(hits, query: FuzzyMatcher.Query(text), limit: limit)
    }

    /// The full name (or the organization), with the first e-mail address or the organization below.
    private static func hit(for contact: CNContact) -> ContactHit? {
        let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
        guard !name.isEmpty else { return nil }
        let organization = name == contact.organizationName ? "" : contact.organizationName
        let email = contact.emailAddresses.first.map { $0.value as String }
        return ContactHit(identifier: contact.identifier, name: name, detail: email ?? (organization.isEmpty ? nil : organization))
    }
}

/// Instant search without contacts (debug sessions restricted to a folder).
struct NoContactSearch: ContactSearching {
    func search(_ text: String, limit: Int) async throws -> [ContactHit] { [] }
}

enum ContactRanking {
    /// Best name match first (contacts the framework found by another name
    /// field last), then by name.
    static func rank(_ hits: [ContactHit], query: FuzzyMatcher.Query, limit: Int) -> [ContactHit] {
        let scored = hits.map { hit in
            (hit, FuzzyMatcher.match(query, in: FuzzyMatcher.Name(hit.name))?.rank ?? 0)
        }
        return scored.sorted { lhs, rhs in
            SearchOrder.precedes(rank: lhs.1, name: lhs.0.name, id: lhs.0.identifier,
                                 rank: rhs.1, name: rhs.0.name, id: rhs.0.identifier)
        }
        .prefix(max(0, limit)).map(\.0)
    }

    /// `addressbook://<identifier>` opens the contact in Contacts.
    static func url(forContact identifier: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
        guard !identifier.isEmpty,
              let encoded = identifier.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "addressbook://" + encoded)
    }
}
