import Foundation

/// Where a message is in Mail: its account, its mailbox and Mail's number for
/// it (the message's `id` in AppleScript, also the name of its file in Mail's
/// store). Mail finds a message quickly with these; they change when the
/// message is moved to another mailbox.
struct MailLocator: Sendable, Hashable, Codable {
    /// Mail's number of the message, unique in the user's mail library.
    var messageNumber: Int
    /// The account's id (a UUID); empty for mailboxes "On My Mac" or when unknown.
    var accountID: String
    /// The mailbox's names from the top level down, e.g. ["Archiv", "Rechnungen"].
    /// Empty when unknown.
    var mailboxPath: [String]

    init(messageNumber: Int, accountID: String, mailboxPath: [String]) {
        self.messageNumber = messageNumber
        self.accountID = accountID
        self.mailboxPath = mailboxPath
    }

    /// The kinds of Mail-wide mailboxes (`MailboxSelection.scriptKind`).
    static let mailWideKinds = ["inbox", "sent", "drafts", "junk", "trash"]

    /// The path of a message found in a Mail-wide mailbox whose own mailbox
    /// Mail could not name: ["@inbox"], ["@sent"] … The scripts then look for
    /// it in that mailbox of all accounts.
    static func mailWidePath(_ kind: String) -> [String] {
        ["@" + kind]
    }

    /// "inbox" for the path ["@inbox"] (and so on), nil for any other path.
    static func mailWideKind(of path: [String]) -> String? {
        guard path.count == 1, path[0].hasPrefix("@") else { return nil }
        let kind = String(path[0].dropFirst())
        return mailWideKinds.contains(kind) ? kind : nil
    }

    /// Whether only the Mail-wide mailbox the message was found in is known.
    var isInUnnamedMailbox: Bool {
        Self.mailWideKind(of: mailboxPath) != nil
    }
}

/// The id `search_mail` gives the model for a message and `read_mail` and
/// `create_mail_draft` take back: `mail:<number>:<account>:<mailbox path>`
/// with every part percent-encoded and the mailbox names separated by "/",
/// e.g. `mail:4711:0A1B2C3D-…:Archiv/Rechnungen`. ASCII only, so the model can
/// copy it exactly; everything in it is checked before a script sees it.
enum MailID {
    static let prefix = "mail:"
    static let maxLength = 600
    /// Mailbox nesting Orbit accepts in an id.
    static let maxMailboxDepth = 30

    /// Characters that stay as they are; everything else is percent-encoded.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func string(for locator: MailLocator) -> String {
        let path = locator.mailboxPath.map(encoded).joined(separator: "/")
        return "\(prefix)\(locator.messageNumber):\(encoded(locator.accountID)):\(path)"
    }

    /// The locator in an id, or nil when the text is not an id Orbit made.
    static func locator(from text: String) -> MailLocator? {
        guard text.hasPrefix(prefix), text.utf8.count <= maxLength,
              text.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F && $0 != "\"" })
        else { return nil }
        let parts = text.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let digits = parts[0]
        guard (1...15).contains(digits.count), digits.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(digits), number > 0 else { return nil }
        guard let account = decoded(parts[1]) else { return nil }
        var path: [String] = []
        if !parts[2].isEmpty {
            for component in parts[2].split(separator: "/", omittingEmptySubsequences: false) {
                guard let name = decoded(component), !name.isEmpty else { return nil }
                path.append(name)
            }
        }
        guard path.count <= maxMailboxDepth else { return nil }
        return MailLocator(messageNumber: number, accountID: account, mailboxPath: path)
    }

    private static func encoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Percent-decodes `text`; nil for broken escapes or control characters.
    private static func decoded(_ text: Substring) -> String? {
        guard let value = String(text).removingPercentEncoding else { return nil }
        guard !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return nil }
        return value
    }
}

/// The message files in Mail's store, e.g.
/// `~/Library/Mail/V10/<account>/Archiv.mbox/Rechnungen.mbox/<store>/Data/1/2/Messages/4711.emlx`
/// (mailboxes "On My Mac" are under `V10/Mailboxes`; a partly downloaded
/// message is `4711.partial.emlx`). Spotlight returns these paths; the account
/// folder is named after the account's id.
enum MailStorePath {
    /// The folder of the "On My Mac" mailboxes, in place of an account.
    static let localMailboxesFolder = "Mailboxes"

    /// The locator of a message file, or nil when `path` is not a message
    /// file in a Mail store.
    static func locator(forFile path: String) -> MailLocator? {
        let components = path.split(separator: "/").map(String.init)
        guard let file = components.last, let number = messageNumber(fileName: file) else { return nil }
        // The store root is the last "V<digits>" folder followed by an account folder and a mailbox.
        var root: Int?
        for index in components.indices.dropLast(2) where isStoreVersion(components[index])
            && components[index + 2].hasSuffix(".mbox") {
            root = index
        }
        guard let root else { return nil }
        let accountFolder = components[root + 1]
        var mailboxPath: [String] = []
        var index = root + 2
        while index < components.count - 1, components[index].hasSuffix(".mbox") {
            let name = String(components[index].dropLast(".mbox".count))
            guard !name.isEmpty else { return nil }
            mailboxPath.append(name)
            index += 1
        }
        guard !mailboxPath.isEmpty, index < components.count - 1 else { return nil }
        return MailLocator(messageNumber: number,
                           accountID: accountFolder == localMailboxesFolder ? "" : accountFolder,
                           mailboxPath: mailboxPath)
    }

    /// 4711 for "4711.emlx" and "4711.partial.emlx".
    static func messageNumber(fileName: String) -> Int? {
        var stem = Substring(fileName)
        guard stem.hasSuffix(".emlx") else { return nil }
        stem = stem.dropLast(".emlx".count)
        if stem.hasSuffix(".partial") { stem = stem.dropLast(".partial".count) }
        guard (1...15).contains(stem.count), stem.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(stem), number > 0 else { return nil }
        return number
    }

    private static func isStoreVersion(_ component: String) -> Bool {
        component.count >= 2 && component.hasPrefix("V") && component.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }
}
