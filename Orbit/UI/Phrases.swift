import Foundation

/// Localized UI phrases with counts. Singular and plural are chosen in code, so
/// the strings work without plural rules in a String Catalog.
enum Phrases {
    static func files(_ count: Int) -> String {
        count == 1 ? String(localized: "1 file") : String(format: String(localized: "%lld files"), count)
    }

    static func fileNames(_ count: Int) -> String {
        count == 1 ? String(localized: "1 file name") : String(format: String(localized: "%lld file names"), count)
    }

    static func emails(_ count: Int) -> String {
        count == 1 ? String(localized: "1 email") : String(format: String(localized: "%lld emails"), count)
    }

    static func notes(_ count: Int) -> String {
        count == 1 ? String(localized: "1 note") : String(format: String(localized: "%lld notes"), count)
    }

    static func events(_ count: Int) -> String {
        count == 1 ? String(localized: "1 event") : String(format: String(localized: "%lld events"), count)
    }

    static func reminders(_ count: Int) -> String {
        count == 1 ? String(localized: "1 reminder") : String(format: String(localized: "%lld reminders"), count)
    }

    static func contacts(_ count: Int) -> String {
        count == 1 ? String(localized: "1 contact") : String(format: String(localized: "%lld contacts"), count)
    }

    static func photos(_ count: Int) -> String {
        count == 1 ? String(localized: "1 photo") : String(format: String(localized: "%lld photos"), count)
    }

    /// What a photo search sends: the photos' details (date, kind, size), never the pictures.
    static func photoDetails(_ count: Int) -> String {
        count == 1 ? String(localized: "details of 1 photo") : String(format: String(localized: "details of %lld photos"), count)
    }

    /// Selected text (a Finder selection counts as file names).
    static func selections(_ count: Int) -> String {
        count == 1 ? String(localized: "1 selected text") : String(format: String(localized: "%lld selected texts"), count)
    }

    /// The names of shortcuts (`list_shortcuts`).
    static func shortcutNames(_ count: Int) -> String {
        count == 1 ? String(localized: "name of 1 shortcut")
            : String(format: String(localized: "names of %lld shortcuts"), count)
    }

    /// What shortcuts returned (`run_shortcut`).
    static func shortcutOutputs(_ count: Int) -> String {
        count == 1 ? String(localized: "output of 1 shortcut")
            : String(format: String(localized: "output of %lld shortcuts"), count)
    }

    static func windowTitles(_ count: Int) -> String {
        count == 1 ? String(localized: "1 window title") : String(format: String(localized: "%lld window titles"), count)
    }

    static func calendarNames(_ count: Int) -> String {
        count == 1 ? String(localized: "name of 1 calendar")
            : String(format: String(localized: "names of %lld calendars"), count)
    }

    static func reminderListNames(_ count: Int) -> String {
        count == 1 ? String(localized: "name of 1 reminder list")
            : String(format: String(localized: "names of %lld reminder lists"), count)
    }

    /// Folders in Notes or in the Shortcuts app.
    static func folderNames(_ count: Int) -> String {
        count == 1 ? String(localized: "name of 1 folder")
            : String(format: String(localized: "names of %lld folders"), count)
    }

    static func mailboxNames(_ count: Int) -> String {
        count == 1 ? String(localized: "name of 1 mailbox")
            : String(format: String(localized: "names of %lld mailboxes"), count)
    }

    static func albumNames(_ count: Int) -> String {
        count == 1 ? String(localized: "name of 1 album")
            : String(format: String(localized: "names of %lld albums"), count)
    }

    /// "a", "a and b", "a, b, and c": the locale's list ("a, b und c" in
    /// German); nil for an empty list.
    static func list(_ parts: [String], locale: Locale = AppLanguage.locale) -> String? {
        guard !parts.isEmpty else { return nil }
        return parts.formatted(.list(type: .and).locale(locale))
    }
}

/// Builds the footnote that tells the user which content went to the LLM
/// provider, e.g. "3 emails, 1 file, and 2 notes sent to Claude".
enum DisclosurePhrase {
    /// nil when nothing was sent (empty list or zero counts). `providerName`
    /// as the chat stored it (`ProviderRecipient`).
    static func text(for items: [ContentDisclosure], providerName: String, locale: Locale = AppLanguage.locale) -> String? {
        var counts: [ContentDisclosure.Kind: Int] = [:]
        for item in items where item.count > 0 {
            counts[item.kind, default: 0] += item.count
        }
        let parts = ContentDisclosure.Kind.allCases.compactMap { kind in
            counts[kind].map { phrase(for: kind, count: $0) }
        }
        guard let list = Phrases.list(parts, locale: locale) else { return nil }
        let text = String(format: String(localized: "%1$@ sent to %2$@"), list, ProviderRecipient.shown(providerName))
        // The note is a sentence of its own: "Details of 30 photos sent to Claude".
        return String(text.prefix(1)).uppercased(with: locale) + text.dropFirst()
    }

    static func phrase(for kind: ContentDisclosure.Kind, count: Int) -> String {
        switch kind {
        case .fileNames: Phrases.fileNames(count)
        case .fileContents: Phrases.files(count)
        case .emails: Phrases.emails(count)
        case .notes: Phrases.notes(count)
        case .events: Phrases.events(count)
        case .reminders: Phrases.reminders(count)
        case .contacts: Phrases.contacts(count)
        case .photos: Phrases.photoDetails(count)
        case .selection: Phrases.selections(count)
        case .shortcuts: Phrases.shortcutNames(count)
        case .shortcutOutputs: Phrases.shortcutOutputs(count)
        case .windowTitles: Phrases.windowTitles(count)
        case .calendarNames: Phrases.calendarNames(count)
        case .reminderListNames: Phrases.reminderListNames(count)
        case .folderNames: Phrases.folderNames(count)
        case .mailboxNames: Phrases.mailboxNames(count)
        case .albumNames: Phrases.albumNames(count)
        }
    }
}
