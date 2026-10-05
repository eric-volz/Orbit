import Contacts
import Foundation
import os

/// A contact as the tools see it.
struct ContactRecord: Sendable, Hashable, Codable {
    /// An e-mail address or phone number with its label.
    struct Value: Sendable, Hashable, Codable {
        /// As Contacts shows it ("Arbeit", "Mobil"), if the value has one.
        var label: String?
        var value: String

        init(label: String? = nil, value: String) {
            self.label = label
            self.value = value
        }
    }

    var identifier: String
    /// The full name, or the organization for a company card.
    var name: String
    var organization: String?
    var emails: [Value]
    var phones: [Value]

    init(identifier: String, name: String, organization: String? = nil, emails: [Value] = [], phones: [Value] = []) {
        self.identifier = identifier
        self.name = name
        self.organization = organization
        self.emails = emails
        self.phones = phones
    }
}

/// Whether Orbit may read the user's contacts.
enum ContactsAccess: Sendable, Hashable {
    case authorized
    /// The user has not decided yet.
    case notDetermined
    case denied
    /// Contacts cannot be used in this session (a DEBUG session restricted
    /// with ORBIT_DEBUG_FILE_SCOPE but without fake personal data).
    case unavailable
}

/// The user's contacts for the tools (`search_contacts`, names → e-mail
/// addresses for mail) and the user's own name for the system prompt.
/// Live: `LiveContactBook` over CNContactStore; tests and the DEBUG fake-data
/// mode use contacts in memory.
protocol ContactBook: Sendable {
    /// The current authorization. Cheap; never asks the user.
    func access() -> ContactsAccess
    /// Asks macOS for access when the user has not decided yet (the system
    /// prompt appears) and returns the access afterwards. Only for requests
    /// the user made (a tool call), never for background lookups.
    func requestAccess() async -> ContactsAccess
    /// Contacts whose name or organization matches `query`, or with this
    /// e-mail address (or part of one, with "@") or phone number; best first,
    /// at most `limit`. Empty without access.
    func search(_ query: String, limit: Int) async throws -> [ContactRecord]
    /// The user's own card ("My Card"); nil without one or without access.
    func me() async throws -> ContactRecord?
}

extension ContactBook {
    /// The name for the system prompt: the full name on "My Card", only when
    /// Orbit may already read contacts (it never asks for this).
    func userName() async -> String? {
        guard access() == .authorized else { return nil }
        guard let me = try? await me() else { return nil }
        let name = me.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// Contacts through the Contacts framework. Reads only with `.authorized`
/// (a limited authorization does not exist on macOS) and asks only in
/// `requestAccess()`. Fetches run on their own queue, never on the main thread,
/// and read at most `fetchLimit` contacts. Nothing about contacts is logged
/// except counts.
struct LiveContactBook: ContactBook {
    static let fetchLimit = 200
    private static let queue = DispatchQueue(label: "io.github.eric-volz.Orbit.contact-book", qos: .userInitiated)

    func access() -> ContactsAccess {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    func requestAccess() async -> ContactsAccess {
        guard access() == .notDetermined else { return access() }
        Log.permissions.info("Asking for access to Contacts")
        do {
            _ = try await CNContactStore().requestAccess(for: .contacts)
        } catch {
            Log.permissions.error("Asking for access to Contacts failed: \(String(describing: type(of: error)), privacy: .public)")
        }
        return access()
    }

    func search(_ query: String, limit: Int) async throws -> [ContactRecord] {
        guard access() == .authorized else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try Self.fetch(query, limit: limit) })
            }
        }
    }

    func me() async throws -> ContactRecord? {
        guard access() == .authorized else { return nil }
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result {
                    do {
                        return ContactMatching.record(for: try CNContactStore().unifiedMeContactWithKeys(toFetch: Self.keys))
                    } catch let error as CNError where error.code == .recordDoesNotExist {
                        return nil
                    }
                })
            }
        }
    }

    static var keys: [any CNKeyDescriptor] {
        [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as NSString,
            CNContactEmailAddressesKey as NSString,
            CNContactPhoneNumbersKey as NSString,
        ]
    }

    private static func fetch(_ query: String, limit: Int) throws -> [ContactRecord] {
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        let kind = ContactMatching.Kind(query)
        switch kind {
        case .name(let text): request.predicate = CNContact.predicateForContacts(matchingName: text)
        case .email(let address): request.predicate = CNContact.predicateForContacts(matchingEmailAddress: address)
        case .phone(let number): request.predicate = CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: number))
        case .partialEmail: request.predicate = nil
        }
        var records: [ContactRecord] = []
        var matched = 0
        try store.enumerateContacts(with: request) { contact, stop in
            guard let record = ContactMatching.record(for: contact) else { return }
            if case .partialEmail = kind, !ContactMatching.matches(record, kind) { return }
            records.append(record)
            matched += 1
            if matched >= fetchLimit { stop.pointee = true }
        }
        let ranked = ContactMatching.rank(records, for: kind, limit: limit)
        Log.tools.info("Contacts: \(records.count) read, \(ranked.count) returned")
        return ranked
    }
}

/// No contacts (a DEBUG session restricted with ORBIT_DEBUG_FILE_SCOPE but
/// without fake personal data must not reach the user's contacts).
struct UnavailableContactBook: ContactBook {
    func access() -> ContactsAccess { .unavailable }
    func requestAccess() async -> ContactsAccess { .unavailable }
    func search(_ query: String, limit: Int) async throws -> [ContactRecord] { [] }
    func me() async throws -> ContactRecord? { nil }
}

/// Pure contact matching, shared by the live book (ranking), the fake and
/// the tests: what a query is, which records match it, in which order.
enum ContactMatching {
    /// What a search text is.
    enum Kind: Sendable, Hashable {
        /// A name or organization.
        case name(String)
        /// A complete e-mail address.
        case email(String)
        /// Part of an e-mail address ("@example.com", "lisa@").
        case partialEmail(String)
        /// A phone number (digits with spaces, +, -, /, parentheses or dots).
        case phone(String)

        init(_ query: String) {
            let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.contains("@") {
                self = EmailAddress.isValid(text) ? .email(text) : .partialEmail(text.lowercased())
                return
            }
            let digits = text.filter(\.isASCIIDigit)
            let allowed = Set("0123456789 +-/().")
            if digits.count >= 3, text.allSatisfy({ allowed.contains($0) }) {
                self = .phone(text)
                return
            }
            self = .name(text)
        }
    }

    /// Whether `record` matches (the fake book; the live book only checks
    /// partial addresses, the framework matches the rest).
    static func matches(_ record: ContactRecord, _ kind: Kind) -> Bool {
        switch kind {
        case .name(let text):
            let query = FuzzyMatcher.Query(text)
            return nameRank(record, query) > 0
        case .email(let address):
            return record.emails.contains { $0.value.caseInsensitiveCompare(address) == .orderedSame }
        case .partialEmail(let fragment):
            return record.emails.contains { $0.value.lowercased().contains(fragment) }
        case .phone(let number):
            let wanted = String(number.filter(\.isASCIIDigit).suffix(9))
            guard wanted.count >= 3 else { return false }
            return record.phones.contains { $0.value.filter(\.isASCIIDigit).hasSuffix(wanted) }
        }
    }

    /// Best match first: for names by how well the name or organization
    /// matches (then by name), otherwise by name.
    static func rank(_ records: [ContactRecord], for kind: Kind, limit: Int) -> [ContactRecord] {
        let scored: [(ContactRecord, Double)]
        if case .name(let text) = kind {
            let query = FuzzyMatcher.Query(text)
            scored = records.map { ($0, nameRank($0, query)) }
        } else {
            scored = records.map { ($0, 0) }
        }
        return scored.sorted { lhs, rhs in
            SearchOrder.precedes(rank: lhs.1, name: lhs.0.name, id: lhs.0.identifier,
                                 rank: rhs.1, name: rhs.0.name, id: rhs.0.identifier)
        }
        .prefix(max(0, limit)).map(\.0)
    }

    private static func nameRank(_ record: ContactRecord, _ query: FuzzyMatcher.Query) -> Double {
        let byName = FuzzyMatcher.match(query, in: FuzzyMatcher.Name(record.name))?.rank ?? 0
        let byOrganization = record.organization.flatMap { FuzzyMatcher.match(query, in: FuzzyMatcher.Name($0))?.rank } ?? 0
        return max(byName, byOrganization)
    }

    /// A record for a fetched contact; nil when it has neither a name nor an organization.
    static func record(for contact: CNContact) -> ContactRecord? {
        let formatted = CNContactFormatter.string(from: contact, style: .fullName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let organization = contact.isKeyAvailable(CNContactOrganizationNameKey)
            ? contact.organizationName.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let name = formatted.isEmpty ? organization : formatted
        guard !name.isEmpty else { return nil }
        let emails = contact.isKeyAvailable(CNContactEmailAddressesKey)
            ? contact.emailAddresses.map { ContactRecord.Value(label: label($0.label), value: $0.value as String) } : []
        let phones = contact.isKeyAvailable(CNContactPhoneNumbersKey)
            ? contact.phoneNumbers.map { ContactRecord.Value(label: label($0.label), value: $0.value.stringValue) } : []
        return ContactRecord(identifier: contact.identifier, name: name,
                             organization: organization.isEmpty || organization == name ? nil : organization,
                             emails: emails, phones: phones)
    }

    /// Contacts' label as the user sees it ("Arbeit" for _$!<Work>!$_); custom labels as they are.
    private static func label(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let localized = CNLabeledValue<NSString>.localizedString(forLabel: raw)
        return localized.isEmpty ? nil : localized
    }
}

/// Plain e-mail addresses ("lisa@example.com") and the "Name <address>" form.
enum EmailAddress {
    /// "<" and its look-alikes (full-width, small, angle brackets), which Orbit
    /// shows the model as ‹ (see `TurnContext.neutralizeMarkup`), and ‹ itself.
    private static let openingBrackets: Set<Unicode.Scalar> = ["‹", "<", "\u{FF1C}", "\u{FE64}", "\u{2329}", "\u{3008}"]
    /// ">" and its look-alikes, shown as ›.
    private static let closingBrackets: Set<Unicode.Scalar> = ["›", ">", "\u{FF1E}", "\u{FE65}", "\u{232A}", "\u{3009}"]

    /// A single plain address: one "@", something before it, a domain with a
    /// dot after it, no spaces, brackets (also the look-alikes Orbit shows the
    /// model), quotes or control characters.
    static func isValid(_ text: String) -> Bool {
        guard text.count <= 254 else { return false }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, let local = parts.first, let domain = parts.last, !local.isEmpty,
              domain.contains("."), !domain.hasPrefix("."), !domain.hasSuffix(".") else { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            .union(CharacterSet(charactersIn: "\"(),;:[]\\"))
        return text.unicodeScalars.allSatisfy { scalar in
            !forbidden.contains(scalar) && !openingBrackets.contains(scalar) && !closingBrackets.contains(scalar)
        }
    }

    /// A recipient or sender the model wrote, ready for `parse`. Results show
    /// addresses as "Lisa Beispiel ‹lisa@example.com›", often with the label
    /// from Contacts after them ("lisa@example.org (Privat)"); copied back, the
    /// brackets are "<" and ">" again and such a label is left out.
    static func normalizedModelInput(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(openingBrackets.contains(scalar) ? "<" : closingBrackets.contains(scalar) ? ">" : scalar)
        }
        let normalized = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard parse(normalized) == nil, normalized.hasSuffix(")"), let open = normalized.lastIndex(of: "(") else {
            return normalized
        }
        let withoutLabel = normalized[..<open].trimmingCharacters(in: .whitespaces)
        return parse(withoutLabel) == nil ? normalized : withoutLabel
    }

    /// The address (and name) in "lisa@example.com", "<lisa@example.com>" or
    /// "Lisa Müller <lisa@example.com>"; nil when the text is no address.
    static func parse(_ text: String) -> (name: String?, address: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isValid(trimmed) { return (nil, trimmed) }
        guard trimmed.hasSuffix(">"), let open = trimmed.lastIndex(of: "<") else { return nil }
        let address = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
            .trimmingCharacters(in: .whitespaces)
        guard isValid(address) else { return nil }
        let name = trimmed[..<open].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
        return (name.isEmpty ? nil : name, address)
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
