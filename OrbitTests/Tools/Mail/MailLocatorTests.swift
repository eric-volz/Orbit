import Foundation
import Testing
@testable import Orbit

@Suite("Mail ids and store paths")
struct MailLocatorTests {
    @Test(arguments: [
        MailLocator(messageNumber: 4711, accountID: "0A1B2C3D-0000-4000-8000-0000000000A1", mailboxPath: ["INBOX"]),
        MailLocator(messageNumber: 1, accountID: "", mailboxPath: ["Lokal"]),
        MailLocator(messageNumber: 99, accountID: "x", mailboxPath: ["[Gmail]", "All Mail"]),
        MailLocator(messageNumber: 7, accountID: "a:b", mailboxPath: ["Archiv/2024", "Rechnungen & Belege", "Größe 😀"]),
        MailLocator(messageNumber: 123_456_789_012, accountID: "acc", mailboxPath: []),
    ])
    func idsRoundTrip(locator: MailLocator) throws {
        let id = MailID.string(for: locator)
        #expect(id.hasPrefix("mail:"))
        #expect(id.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 0x20 }, "ASCII without spaces: \(id)")
        #expect(MailID.locator(from: id) == locator)
    }

    @Test func idsLookLikeThis() {
        #expect(MailID.string(for: MailLocator(messageNumber: 4711, accountID: "0A1B", mailboxPath: ["Archiv", "Rechnungen"]))
            == "mail:4711:0A1B:Archiv/Rechnungen")
        #expect(MailID.string(for: MailLocator(messageNumber: 5, accountID: "", mailboxPath: ["Sent Messages"]))
            == "mail:5::Sent%20Messages")
    }

    @Test(arguments: [
        "", "mail:", "4711:a:INBOX", "mail:0:a:INBOX", "mail:-1:a:INBOX", "mail:12a:a:INBOX", "mail:1:a",
        "mail:1:a:b:c", "mail:1:a:INBOX//x", "mail:1:a:%ZZ", "mail:1:a:%00", "mail:1:a:IN BOX", "mail:1:a:\"x\"",
        "mail:1:a:INBOX\n", "mail:1234567890123456:a:INBOX", "x-coredata://abc", "mail:1:a:Ä",
    ])
    func malformedIDsAreRefused(text: String) {
        #expect(MailID.locator(from: text) == nil)
    }

    @Test func overlongIDsAreRefused() {
        let deep = MailLocator(messageNumber: 1, accountID: "a", mailboxPath: Array(repeating: "x", count: 31))
        #expect(MailID.locator(from: MailID.string(for: deep)) == nil, "at most 30 levels")
        let long = "mail:1:a:" + String(repeating: "x", count: 600)
        #expect(MailID.locator(from: long) == nil)
    }

    @Test func storePathsGiveTheLocator() {
        let home = "/Users/someone/Library/Mail/V10"
        #expect(MailStorePath.locator(forFile: "\(home)/ACC-1/INBOX.mbox/STORE/Data/1/2/Messages/4711.emlx")
            == MailLocator(messageNumber: 4711, accountID: "ACC-1", mailboxPath: ["INBOX"]))
        #expect(MailStorePath.locator(forFile: "\(home)/ACC-1/Archiv.mbox/Rechnungen.mbox/STORE/Data/Messages/12.partial.emlx")
            == MailLocator(messageNumber: 12, accountID: "ACC-1", mailboxPath: ["Archiv", "Rechnungen"]))
        #expect(MailStorePath.locator(forFile: "\(home)/Mailboxes/Lokal.mbox/STORE/Data/Messages/3.emlx")
            == MailLocator(messageNumber: 3, accountID: "", mailboxPath: ["Lokal"]))
        #expect(MailStorePath.locator(forFile: "\(home)/ACC/[Gmail].mbox/All Mail.mbox/S/Data/Messages/8.emlx")
            == MailLocator(messageNumber: 8, accountID: "ACC", mailboxPath: ["[Gmail]", "All Mail"]))
    }

    @Test(arguments: [
        "/Users/someone/Documents/4711.emlx",
        "/Users/someone/Library/Mail/V10/ACC/INBOX.mbox/STORE/Data/Messages/notes.txt",
        "/Users/someone/Library/Mail/V10/ACC/INBOX.mbox/STORE/Data/Messages/abc.emlx",
        "/Users/someone/Library/Mail/V10/ACC/INBOX.mbox/4711.emlx",
        "/Users/someone/Library/Mail/V10/ACC/STORE/Data/Messages/4711.emlx",
        "/Users/someone/Library/Mail/V10/ACC/.mbox/STORE/Data/Messages/4711.emlx",
        "/Users/someone/Library/Mail/V10/ACC/INBOX.mbox/STORE/Data/Messages/0.emlx",
    ])
    func otherPathsAreNoMessages(path: String) {
        #expect(MailStorePath.locator(forFile: path) == nil)
    }

    @Test func theFixturesAreLaidOutLikeMailsStore() throws {
        let files = try FileManager.default.subpathsOfDirectory(atPath: MailFixtures.root + "/V10")
            .filter { $0.hasSuffix(".emlx") }
        #expect(files.count == 18)
        for file in files {
            #expect(MailStorePath.locator(forFile: MailFixtures.root + "/V10/" + file) != nil, "\(file)")
        }
        #expect(MailStorePath.locator(forFile: MailFixtures.inbox("104.partial.emlx"))
            == MailLocator(messageNumber: 104, accountID: MailFixtures.privateAccount, mailboxPath: ["INBOX"]))
    }
}
