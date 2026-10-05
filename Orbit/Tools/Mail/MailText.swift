import Foundation

/// Text rules of the mail tools: how messages match a search, previews,
/// message bodies for the model, the text of drafts and the subject of a
/// reply. Pure.
enum MailText {
    /// Case-, accent- and width-insensitive ("muller" finds "Müller", "strasse"
    /// "Straße"): the same comparison Orbit's mail scripts make.
    static let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Whether `text` contains `part` (never for an empty part).
    static func contains(_ text: String, _ part: String) -> Bool {
        !part.isEmpty && text.range(of: part, options: matchOptions) != nil
    }

    /// Whether a message matches a search: every term occurs in the subject
    /// or the sender (name and address; also inside longer words: "kartons"
    /// finds "Umzugskartons"); with sender words or addresses, also the sender
    /// is the one asked for (`isFrom`).
    static func matches(subject: String, sender: String, terms: [String], fromWords: [String],
                        fromAddresses: [String]) -> Bool {
        for term in terms where !(contains(subject, term) || contains(sender, term)) {
            return false
        }
        guard !fromWords.isEmpty || !fromAddresses.isEmpty else { return true }
        return isFrom(sender, words: fromWords, addresses: fromAddresses)
    }

    /// Whether `sender` ("Lisa Beispiel <lisa@example.com>", as Mail gives it)
    /// is the sender a search asks for: its address is one of `addresses`
    /// (ignoring case), or every word starts a word of its name ("Lisa
    /// Beispiel" finds "Beispiel, Lisa" and "Lisa M. Beispiel", not "Lisa
    /// Müller" or "Annalisa Beispiel"). Words of the address count only for a
    /// single word ("telekom" finds "Kundenservice <service@telekom.example>") and
    /// for a sender without a display name ("Max Weber" finds
    /// "max.weber@firma.example"): two or more words never match another person's
    /// address ("Lisa Beispiel" does not find "Lisa Müller
    /// <lisa.mueller@beispiel.example>"). `MailSpotlightPredicate` asks Spotlight the same.
    static func isFrom(_ sender: String, words: [String], addresses: [String]) -> Bool {
        let parsed = EmailAddress.parse(sender)
        if let address = parsed?.address {
            if addresses.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) { return true }
        } else if addresses.contains(where: { contains(sender, $0) }) {
            return true
        }
        guard !words.isEmpty else { return false }
        // A sender Orbit cannot take apart is looked at as a whole.
        let name = parsed.map { $0.name ?? "" } ?? sender
        if words.allSatisfy({ startsAWord(of: name, $0) }) { return true }
        guard let parsed, words.count == 1 || parsed.name == nil else { return false }
        return words.allSatisfy { startsAWord(of: parsed.address, $0) }
    }

    /// Whether `part` occurs in `text` at the start of a word (after the
    /// start or a character that is no letter or digit, as in Spotlight's word
    /// matching), ignoring case, accents and width. A part that begins with
    /// such a character ("@example.com") may occur anywhere.
    static func startsAWord(of text: String, _ part: String) -> Bool {
        guard let first = part.first else { return false }
        let needsWordStart = first.isLetter || first.isNumber
        var searchStart = text.startIndex
        while let found = text.range(of: part, options: matchOptions, range: searchStart..<text.endIndex) {
            guard needsWordStart, let before = text[..<found.lowerBound].last, before.isLetter || before.isNumber else {
                return true
            }
            let next = text.index(after: found.lowerBound)
            guard next > searchStart, next < text.endIndex else { return false }
            searchStart = next
        }
        return false
    }

    /// The sender filter in `from`: an address ("lisa@example.com", "Lisa
    /// <lisa@example.com>", also as Orbit shows it: "Lisa ‹lisa@example.com›")
    /// is matched as an address; anything else as words that must all start
    /// words of the sender's name (`isFrom`: "Lisa Beispiel" also finds "Beispiel, Lisa <…>").
    static func senderFilter(_ text: String) -> (words: [String], addresses: [String]) {
        let cleaned = EmailAddress.normalizedModelInput(NoteText.singleLine(text))
        if let parsed = EmailAddress.parse(cleaned) {
            return ([], [parsed.address])
        }
        let edges = CharacterSet(charactersIn: "\"'„“”‚‘’<>()[],;:")
            .union(.whitespacesAndNewlines)
        var seen = Set<String>()
        let words = cleaned.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: edges) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return (words, [])
    }

    /// A Message-ID without angle brackets and whitespace.
    static func bareMessageID(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n"))
    }

    // MARK: Previews and bodies

    /// A one-line preview of a message's text for result rows and cards:
    /// quoted lines ("> …") and the line introducing them, and everything from
    /// the signature separator ("-- ") on, are left out; whitespace is
    /// collapsed; at most `maxCharacters` (cut at a word, with "…"). nil when
    /// nothing is left.
    static func preview(from text: String, maxCharacters: Int) -> String? {
        var lines: [String] = []
        for rawLine in MIMEText.normalizingLineBreaks(text).split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line == "-- " || line == "--" { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") {
                // "Am … schrieb Lisa:" / "On …, Lisa wrote:" introduces the quote.
                if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasSuffix(":") { lines.removeLast() }
                continue
            }
            lines.append(line)
        }
        return NoteText.excerpt(from: NoteText.cleaned(lines.joined(separator: "\n")), title: "",
                                maxCharacters: maxCharacters)
    }

    /// A message body for the model: line breaks as "\n", no control
    /// characters (except tabs), no trailing spaces, at most one empty line in
    /// a row, trimmed.
    static func cleanedBody(_ text: String) -> String {
        var lines: [String] = []
        var emptyRun = 0
        for rawLine in NoteText.cleaned(MIMEText.normalizingLineBreaks(text)).split(separator: "\n", omittingEmptySubsequences: false) {
            var line = Substring(rawLine)
            while let last = line.last, last == " " || last == "\t" || last == "\u{00A0}" { line = line.dropLast() }
            if line.isEmpty {
                emptyRun += 1
                if emptyRun == 1, !lines.isEmpty { lines.append("") }
            } else {
                emptyRun = 0
                lines.append(String(line))
            }
        }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Replies

    /// Prefixes that already mark a reply (case ignored): Re, AW (German),
    /// Antw, SV/VS (Nordic), Ref/Réf/Rif/RES (Romance), Odp (Polish).
    static let replyPrefixes: Set<String> = ["re", "aw", "antw", "antwort", "sv", "vs", "ref", "réf", "rif", "res", "odp"]

    /// "Re: <subject>", unless the subject already starts with a reply prefix:
    /// what Mail's reply window shows (for the card when Mail does not tell).
    static func replySubject(_ subject: String) -> String {
        let trimmed = NoteText.singleLine(subject)
        if let colon = trimmed.firstIndex(of: ":"), trimmed.distance(from: trimmed.startIndex, to: colon) <= 8 {
            let prefix = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if replyPrefixes.contains(prefix) { return trimmed }
        }
        return trimmed.isEmpty ? "Re:" : "Re: \(trimmed)"
    }

    /// Text for a draft as written: line breaks as "\n", no control characters
    /// (except tabs), no empty lines or spaces around it; blank lines inside stay.
    static func draftText(_ text: String) -> String {
        MIMEText.normalizingLineBreaks(NoteText.cleaned(text)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Mailbox names Orbit knows by convention (Mail's own names, common server
/// names and their German, French, Spanish, Italian, Dutch and Nordic forms).
enum MailboxNames {
    /// Mailboxes `mailbox: "all"` leaves out: trash, junk, drafts and outbox.
    /// Compared with the mailbox's own name (the last part of its path).
    static let excludedFromAll: [String] = [
        "Trash", "Deleted Messages", "Deleted Items", "Bin", "Papierkorb", "Gelöschte Objekte",
        "Gelöschte Elemente", "Gelöschte Nachrichten", "Corbeille", "Éléments supprimés", "Papelera",
        "Elementos eliminados", "Cestino", "Posta eliminata", "Prullenbak", "Verwijderde items", "Papperskorgen",
        "Junk", "Junk E-mail", "Junk Email", "Junk-E-Mail", "Spam", "Bulk Mail", "Werbung", "Courrier indésirable",
        "Indésirables", "Correo no deseado", "Posta indesiderata", "Ongewenste e-mail", "Skräppost",
        "Drafts", "Entwürfe", "Brouillons", "Borradores", "Bozze", "Concepten", "Utkast",
        "Outbox", "Postausgang", "Boîte d'envoi", "Bandeja de salida", "Posta in uscita", "Postvak UIT", "Utkorg",
    ]

    /// Top-level mailboxes that are an account's inbox in Mail's store.
    static let inboxNames: [String] = [
        "INBOX", "Posteingang", "Boîte de réception", "Bandeja de entrada", "Posta in arrivo", "Postvak IN",
        "Inkorgen", "Indbakke", "Innboks", "Saapuneet",
    ]

    /// Whether `name` is one of `names` (case and accents ignored).
    static func contains(_ names: [String], _ name: String) -> Bool {
        names.contains { $0.compare(name, options: MailText.matchOptions) == .orderedSame }
    }

    /// Whether a mailbox path names the mailbox `wanted`: its own name, or the
    /// whole path with "/" between the names ("Archiv/Rechnungen").
    static func path(_ path: [String], isNamed wanted: String) -> Bool {
        guard let last = path.last else { return false }
        return contains([wanted], last) || contains([wanted], path.joined(separator: "/"))
    }
}
