import Foundation
import Testing
@testable import Orbit

@Suite("Mail text rules")
struct MailTextTests {
    @Test(arguments: [
        // Terms: each in the subject or the sender, inside words, case and accents ignored.
        (["projekt"], [], [], true), (["PROJEKT", "lisa"], [], [], true), (["kartons"], [], [], true),
        (["nachste"], [], [], true), (["projekt", "rechnung"], [], [], false), (["example.com"], [], [], true),
        // Sender words: each starts a word of the sender's name (or each one of its address); addresses: the sender's.
        ([], ["lisa"], [], true), ([], ["Beispiel", "Lisa"], [], true), ([], ["lisa", "muster"], [], false),
        ([], [], ["LISA.BEISPIEL@example.com"], true), ([], ["max"], ["lisa.beispiel@example.com"], true),
        ([], ["max"], ["max@example.com"], false), (["projekt"], ["max"], [], false),
    ] as [([String], [String], [String], Bool)])
    func messagesMatch(terms: [String], words: [String], addresses: [String], expected: Bool) {
        let matches = MailText.matches(subject: "Projekt Orbit \u{2013} nächste Schritte (Umzugskartons)",
                                       sender: "Lisa Beispiel <lisa.beispiel@example.com>", terms: terms,
                                       fromWords: words, fromAddresses: addresses)
        #expect(matches == expected)
    }

    @Test func foldingMatchesWhatTheScriptsCompare() {
        #expect(MailText.contains("Straße 1", "strasse"))
        #expect(MailText.contains("Müller", "MULLER"))
        #expect(MailText.contains("Ｌｉｓａ", "lisa"), "width")
        #expect(!MailText.contains("abc", ""), "an empty term never matches")
    }

    @Test(arguments: [
        ("Lisa", ["Lisa"], []), ("Lisa Beispiel", ["Lisa", "Beispiel"], []), ("Beispiel, Lisa", ["Beispiel", "Lisa"], []),
        ("lisa@example.com", [], ["lisa@example.com"]), ("Lisa <lisa@example.com>", [], ["lisa@example.com"]),
        ("\"Lisa\"  lisa", ["Lisa"], []), ("  ", [], []), ("@example.com", ["@example.com"], []),
        // As results show senders and contacts to the model.
        ("Lisa Beispiel ‹lisa@example.com›", [], ["lisa@example.com"]), ("‹lisa@example.com›", [], ["lisa@example.com"]),
        ("lisa@example.org (Privat)", [], ["lisa@example.org"]),
    ] as [(String, [String], [String])])
    func senderFilters(text: String, words: [String], addresses: [String]) {
        let filter = MailText.senderFilter(text)
        #expect(filter.words == words)
        #expect(filter.addresses == addresses)
    }

    /// `from`: a message is from the person asked for when its address is one
    /// of the contact's addresses, or when every word of the name starts a word
    /// of the sender's display name, or of its address, but only for a single
    /// word (companies by domain) or a sender without a display name.
    @Test(arguments: [
        // Every word of the name starts a word of the display name: any address, any order.
        ("Lisa Beispiel <lisa.beispiel@firma.example>", ["Lisa", "Beispiel"], [], true),
        ("\"Beispiel, Lisa\" <lb@kanzlei.example>", ["Lisa", "Beispiel"], [], true),
        ("Lisa M. Beispiel <lmb@example.net>", ["lisa", "BEISPIEL"], [], true),
        ("Lisa Müller <lisa.mueller@example.com>", ["Lisa", "Beispiel"], [], false),
        ("Annalisa Beispielmann <annalisa.beispielmann@example.net>", ["Lisa", "Beispiel"], [], false),
        ("Annalisa Beispielmann <annalisa.beispielmann@example.net>", ["Beispiel"], [], true),
        ("Elisabeth Meier <elisabeth.meier@example.com>", ["Lisa"], [], false),
        ("Lisa Müller <mueller@beispiel.example>", ["Lisa", "Beispiel"], [], false),
        ("Jürgen Müller <j@example.com>", ["jurgen", "MULLER"], [], true),
        // … or of the address, for a single word (companies by their domain) …
        ("Max Mustermann <max.mustermann@telekom.example>", ["Telekom"], [], true),
        ("Kundenservice <service@telekom.example>", ["telekom"], [], true),
        ("Lisa Müller <lisa.mueller@beispiel.example>", ["Beispiel"], [], true),
        ("Telekom Deutschland <rechnung@telekom.example>", ["@telekom.example"], [], true),
        ("Telekom Deutschland <rechnung@telekom.example>", ["telekom.example"], [], true),
        ("Telekom Deutschland <rechnung@telekom.example>", ["lekom"], [], false),
        // … and for a sender without a display name, …
        ("rechnung@vodafone.example", ["Vodafone"], [], true),
        ("<noreply@telekom.example>", ["Telekom"], [], true),
        ("max.weber@weber-gmbh.example", ["Max", "Weber"], [], true),
        ("<max.weber@weber-gmbh.example>", ["max", "WEBER"], [], true),
        ("\"\" <max.weber@weber-gmbh.example>", ["Max", "Weber"], [], true),
        ("max.weber@weber-gmbh.example", ["Max", "Schmidt"], [], false),
        // … but two or more words never match another person's address: only the display name counts.
        ("Lisa Müller <lisa.mueller@beispiel.example>", ["Lisa", "Beispiel"], [], false),
        ("Max Schmidt <max.schmidt@weber-gmbh.example>", ["Max", "Weber"], [], false),
        ("Lisa Müller <lisa.mueller@beispiel.example>", ["Lisa", "Beispiel"], ["lisa.mueller@beispiel.example"], true),
        // Addresses: the sender's address, ignoring case, not one that only contains it.
        ("Lisa <LISA@example.com>", [], ["lisa@example.com"], true),
        ("Elisa <elisa@example.com>", [], ["lisa@example.com"], false),
        ("L. B. <lisa@example.org>", ["Lisa", "Beispiel"], ["lisa@example.org"], true),
        // A sender Orbit cannot take apart is looked at as a whole.
        ("lisa@example.com (Lisa Beispiel)", ["Beispiel"], [], true),
        ("lisa@example.com (Lisa Beispiel)", [], ["lisa@example.com"], true),
    ] as [(String, [String], [String], Bool)])
    func sendersAreThePersonAskedFor(sender: String, words: [String], addresses: [String], expected: Bool) {
        #expect(MailText.isFrom(sender, words: words, addresses: addresses) == expected)
        #expect(MailText.matches(subject: "Betreff", sender: sender, terms: [], fromWords: words, fromAddresses: addresses) == expected)
    }

    @Test func wordStarts() {
        #expect(MailText.startsAWord(of: "Lisa Beispiel", "beisp"))
        #expect(MailText.startsAWord(of: "Müller-Lüdenscheidt", "ludenscheidt"), "after a hyphen")
        #expect(MailText.startsAWord(of: "Annalisa Lisa", "lisa"), "the second occurrence starts a word")
        #expect(!MailText.startsAWord(of: "Annalisa", "lisa"))
        #expect(!MailText.startsAWord(of: "Lisa", ""))
        #expect(!MailText.startsAWord(of: "", "a"))
        #expect(MailText.startsAWord(of: "Ｌｉｓａ Beispiel", "lisa"), "width")
    }

    @Test func previewsLeaveOutQuotesAndSignatures() {
        let text = """
            Hallo Erika,

            ja, Donnerstag passt.
            Am 14.09.2026 um 20:00 schrieb Erika:
            > Wer kommt?
            > Gruß
            Noch was danach.
            --\u{20}
            Lisa Beispiel
            Telefon 0000
            """
        #expect(MailText.preview(from: text, maxCharacters: 200) == "Hallo Erika, ja, Donnerstag passt. Noch was danach.")
        #expect(MailText.preview(from: "> nur Zitat", maxCharacters: 200) == nil)
        #expect(MailText.preview(from: String(repeating: "Wort ", count: 100), maxCharacters: 20) == "Wort Wort Wort Wort…")
        #expect(MailText.preview(from: "A\r\nB\rC", maxCharacters: 50) == "A B C")
    }

    @Test func bodiesForTheModel() {
        #expect(MailText.cleanedBody("Hallo  \r\n\r\n\r\n\r\nWelt\t \n\u{0007}\n\n") == "Hallo\n\nWelt")
        #expect(MailText.cleanedBody("\n\nText") == "Text")
        #expect(MailText.draftText("  Hallo\r\n\r\n\r\nTschüss \u{0} ") == "Hallo\n\n\nTschüss", "blank lines inside stay")
    }

    @Test(arguments: [
        ("Projekt", "Re: Projekt"), ("Re: Projekt", "Re: Projekt"), ("RE:Projekt", "RE:Projekt"), ("AW: Projekt", "AW: Projekt"),
        ("Antw: Projekt", "Antw: Projekt"), ("Fwd: Projekt", "Re: Fwd: Projekt"), ("", "Re:"), ("  Zeile\nzwei ", "Re: Zeile zwei"),
        ("Wichtig: Termin", "Re: Wichtig: Termin"),
    ])
    func replySubjects(subject: String, expected: String) {
        #expect(MailText.replySubject(subject) == expected)
    }

    @Test func mailboxNames() {
        #expect(MailboxNames.contains(MailboxNames.excludedFromAll, "papierkorb"))
        #expect(MailboxNames.contains(MailboxNames.excludedFromAll, "Gelöschte Objekte"))
        #expect(MailboxNames.contains(MailboxNames.excludedFromAll, "JUNK"))
        #expect(!MailboxNames.contains(MailboxNames.excludedFromAll, "Archiv"))
        #expect(!MailboxNames.contains(MailboxNames.excludedFromAll, "Sent Messages"), "sent mail stays searchable")
        #expect(MailboxNames.contains(MailboxNames.inboxNames, "inbox"))
        #expect(MailboxNames.path(["Archiv", "Rechnungen"], isNamed: "rechnungen"))
        #expect(MailboxNames.path(["Archiv", "Rechnungen"], isNamed: "Archiv/Rechnungen"))
        #expect(!MailboxNames.path(["Archiv", "Rechnungen"], isNamed: "Archiv"))
        #expect(!MailboxNames.path([], isNamed: "Archiv"))
    }

    @Test func searchTermsSplitLikeNotes() {
        #expect(SearchTerms.split("Rechnung \"Projekt Orbit\" rechnung *") == ["Rechnung", "Projekt Orbit"])
        #expect(SearchNotesTool.terms(from: "a b") == SearchTerms.split("a b"))
    }
}
