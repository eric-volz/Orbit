import Foundation
import Testing
@testable import Orbit

/// Orbit's Mail scripts: what they may never do (static checks on top of
/// AppleScriptFilesTests), and their handlers that do not talk to Mail, run
/// for real with osascript in scripts that address no app. `.serialized`: each
/// osascript run loads AppleScriptObjC (about a quarter of a second of CPU), so
/// all at once they would crowd out the timing-sensitive tests of the run.
@Suite("Mail scripts", .serialized)
struct MailScriptTests {
    static func source(_ name: String) throws -> String {
        try AppleScriptFilesTests.source(name)
    }

    /// The script without its comments.
    static func code(_ name: String) throws -> String {
        try source(name).components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("--") }
            .joined(separator: "\n")
    }

    static func matches(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    @Test func noScriptCanSendDeleteMoveOrChangeMail() throws {
        for script in MailService.scripts {
            let source = try Self.source(script.name)
            for word in ["send", "delete", "move", "forward", "redirect", "bounce", "duplicate", "synchronize",
                         "check for new mail", "import", "save", "close", "make new mailbox", "make new rule"] {
                #expect(!Self.matches("\\b\(word)\\b", in: source), "\(script.name) must not use '\(word)'")
            }
            // The command "reply" (only mail-reply answers, see below); the property "reply to"
            // (the address to answer to) is fine.
            if script != MailService.replyScript {
                #expect(!Self.matches(#"\breply\b(?!\s+to\b)"#, in: source), "\(script.name) must not use 'reply'")
            }
            let code = try Self.code(script.name)
            #expect(!Self.matches(#"\bset\s+(read status|flagged status|flag index|junk mail status|deleted status|background color|mailbox|content|subject|sender)\s+of\s+the(Message|Box)\b"#, in: code),
                    "\(script.name) must not change messages")
        }
    }

    /// The one script that answers a message: always in Mail's visible reply
    /// window, which Mail fills in; nothing of the reply is changed.
    @Test func onlyTheReplyScriptAnswersAndOnlyInAVisibleWindow() throws {
        // Text in quotes ("mail-reply expects …") is no command.
        let code = try Self.code("mail-reply").replacingOccurrences(of: #""[^"\n]*""#, with: "\"\"", options: .regularExpression)
        let commands = code.components(separatedBy: "\n")
            .filter { Self.matches(#"\breply\b(?!\s+to\b)"#, in: $0) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(commands == ["set theReply to reply theMessage with opening window and reply to all",
                             "set theReply to reply theMessage with opening window"])
        #expect(!Self.matches(#"\bof\s+theReply\s+to\b"#, in: code), "no property of the reply is set")
        #expect(!Self.matches(#"\btell\s+theReply\b"#, in: code))
        #expect(!Self.matches(#"\b(content|visible|message signature)\b"#, in: code))
        // Only the reply command and reads of what Mail filled in touch the reply.
        let uses = code.components(separatedBy: "\n").filter { $0.contains("theReply") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(uses.allSatisfy { line in
            line.hasPrefix("set theReply to reply theMessage with opening window") || line.hasPrefix("on recipientList(theReply")
                || line.hasPrefix("end recipientList") || line.hasSuffix("of theReply") || line.hasPrefix("set toList to my recipientList(theReply")
                || line.hasPrefix("set ccList to my recipientList(theReply")
        }, "\(uses)")
    }

    @Test func onlyTheDraftScriptMakesSomethingAndItIsAVisibleMessage() throws {
        for script in MailService.scripts where script != MailService.draftScript {
            #expect(!Self.matches(#"\bmake new\b"#, in: try Self.code(script.name)), "\(script.name)")
        }
        let draft = try Self.code("mail-draft")
        #expect(draft.contains("make new outgoing message with properties {subject:theSubject, content:theContent, visible:true}"))
        #expect(draft.contains("make new to recipient at end of to recipients"))
        #expect(draft.contains("make new cc recipient at end of cc recipients"))
        #expect(!Self.matches(#"\bbcc\b"#, in: draft))
    }

    @Test func messagesAreFoundByMailsOwnIDForm() throws {
        let finders = ["mail-read", "mail-summaries", "mail-reply"]
        for name in finders {
            #expect(try Self.code(name).contains("set theMessage to «class mssg» id theNumber of theBox"), "\(name)")
        }
        // Every other raw code would need a reason; there is none.
        for script in MailService.scripts {
            let raw = try Self.code(script.name).components(separatedBy: "«").count - 1
            #expect(raw == (finders.contains(script.name) ? 1 : 0), "\(script.name)")
        }
        // mail-reply and mail-summaries look for the message exactly like mail-read.
        let read = try Self.source("mail-read")
        for other in ["mail-reply", "mail-summaries"] {
            let source = try Self.source(other)
            for handler in ["findMessage", "mailWideKind", "specialMailbox", "mailboxAt", "messageIn", "allMailboxes",
                            "collectMailboxes", "isFatal", "pathText"] {
                #expect(try AppleScriptFilesTests.handlers([handler], from: source) == AppleScriptFilesTests.handlers([handler], from: read),
                        "\(other): \(handler)")
            }
        }
    }

    /// A message whose own mailbox Mail could not name in a search of the inbox
    /// (or sent …) has the path "@inbox": it is looked for in that Mail-wide
    /// mailbox first, then as before.
    @Test func aMessageWithoutItsMailboxIsLookedForInItsMailWideMailbox() async throws {
        let find = try AppleScriptFilesTests.handlers(["findMessage"], from: try Self.source("mail-read"))
        #expect(find.contains("""
                set wideKind to my mailWideKind(boxPath)
                if wideKind is not "" then
                    set theMessage to missing value
                    try
                        set theMessage to my messageIn(my specialMailbox(wideKind), theNumber)
            """.replacingOccurrences(of: "    ", with: "\t")))
        let handlers = try AppleScriptFilesTests.handlers(["mailWideKind"], from: try Self.source("mail-read"))
        let output = try await AppleScriptFilesTests.runHandlers(handlers, body: """
                set kinds to {}
                repeat with probe in {{"@inbox"}, {"@sent"}, {"@drafts"}, {"@junk"}, {"@trash"}, {"@INBOX"}, {"INBOX"}, {"@inbox", "x"}, {}, {"@archive"}}
                    set end of kinds to my mailWideKind(contents of probe)
                end repeat
                set AppleScript's text item delimiters to ","
                return kinds as text
            """)
        #expect(output.components(separatedBy: ",") == ["inbox", "sent", "drafts", "junk", "trash", "", "", "", "", ""])
        for kind in MailLocator.mailWideKinds {
            #expect(MailLocator.mailWideKind(of: MailLocator.mailWidePath(kind)) == kind, "Swift writes what the scripts read")
        }
    }

    // MARK: Handlers

    private struct SearchHandlers: Decodable {
        var single: MailCandidates.Batch
        var wide: MailCandidates.Batch
        var fallback: [Double?]
        var excluded: [Bool]
        var named: [Bool]
        var fatal: [Bool]
        var paths: [String]
        var lines: [String]
    }

    @Test func mailSearchBuildsBatchesAndDecidesOnMailboxes() async throws {
        let names = ["secondsSince1970", "dateFromSeconds", "isFatal", "isExcluded", "isNamed", "pathText", "nonEmptyLines",
                     "shortened", "batchDictionary", "toJSON"]
        let handlers = try AppleScriptFilesTests.handlers(names, from: try Self.source("mail-search"))
        let output = try await AppleScriptFilesTests.runHandlers(handlers, body: """
                set firstDate to my dateFromSeconds(item 1 of argv)
                set secondDate to firstDate + 3600
                set single to my batchDictionary("ACC", {"Archiv", "Rechnungen"}, missing value, missing value, {101, 102}, {firstDate, secondDate}, {item 2 of argv, missing value}, {"Lisa <l@example.com>", "x"})
                set wide to my batchDictionary("", missing value, {"A1", missing value}, {"INBOX", missing value}, {7, 8}, {firstDate, secondDate}, {"a", "b"}, {"c", "d"})
                set fallback to my secondsSince1970({firstDate, missing value})
                set excludedNames to my nonEmptyLines(item 3 of argv)
                set excluded to {my isExcluded({"Archiv"}, excludedNames), my isExcluded({"Archiv", "PAPIERKORB"}, excludedNames), my isExcluded({}, excludedNames), my isExcluded({"Geloscht"}, excludedNames)}
                set nameMatches to {my isNamed({"Archiv", "Rechnungen"}, "rechnungen"), my isNamed({"Archiv", "Rechnungen"}, "ARCHIV/rechnungen"), my isNamed({"Archiv", "Rechnungen"}, "Archiv"), my isNamed({}, "x"), my isNamed({item 4 of argv}, "buro")}
                set fatal to {}
                repeat with errorNumber in {-1743, -1744, -600, -609, -128, -1712, -1728, 1002}
                    set end of fatal to my isFatal(contents of errorNumber)
                end repeat
                set paths to {my pathText({"A", "B", "C"}), my pathText({"Nur"}), my pathText({})}
                set payload to current application's NSDictionary's dictionaryWithObjects:{single, wide, fallback, excluded, nameMatches, fatal, paths, my nonEmptyLines(item 3 of argv)} forKeys:{"single", "wide", "fallback", "excluded", "named", "fatal", "paths", "lines"}
                return my toJSON(payload)
            """, arguments: ["1790856120", "Projekt „Orbit“ 👨‍👩‍👧", "Papierkorb\n\nJunk\r\nGelöscht", "Büro"])
        let result = try JSONDecoder().decode(SearchHandlers.self, from: Data(output.utf8))
        #expect(result.single == MailCandidates.Batch(account: "ACC", mailbox: ["Archiv", "Rechnungen"], ids: [101, 102],
                                                      dates: [1_790_856_120, 1_790_859_720],
                                                      subjects: ["Projekt „Orbit“ 👨‍👩‍👧", nil], senders: ["Lisa <l@example.com>", "x"]))
        #expect(result.wide == MailCandidates.Batch(accounts: ["A1", nil], mailboxNames: ["INBOX", nil], ids: [7, 8],
                                                    dates: [1_790_856_120, 1_790_859_720], subjects: ["a", "b"], senders: ["c", "d"]))
        #expect(result.fallback == [1_790_856_120, nil], "a missing date does not break the batch")
        #expect(result.excluded == [false, true, false, true], "any name of the path; case and accents ignored")
        #expect(result.named == [true, true, false, false, true], "leaf name or path; case and accents ignored")
        #expect(result.fatal == [true, true, true, true, true, false, false, false], "a timeout only ends this mailbox")
        #expect(result.paths == ["A/B/C", "Nur", ""])
        #expect(result.lines == ["Papierkorb", "Junk", "Gelöscht"])
    }

    /// Hostile mail with huge subjects and senders (mail servers accept headers
    /// of 100 KB): mail-search cuts them to 500 characters without a loop per
    /// message, so the answer stays far below the runner's output limit and
    /// every message is still there.
    @Test func mailSearchCutsHugeSubjectsAndSendersAndKeepsEveryMessage() async throws {
        let handlers = try AppleScriptFilesTests.handlers(["secondsSince1970", "shortened", "batchDictionary", "toJSON"],
                                                          from: try Self.source("mail-search"))
        let output = try await AppleScriptFilesTests.runHandlers(handlers, body: """
                set unit to current application's NSString's stringWithString:"Abc/"
                set huge to (unit's stringByPaddingToLength:100000 withString:"Abc/" startingAtIndex:0) as text
                set theIDs to {}
                set theDates to {}
                set theSubjects to {}
                set theSenders to {}
                repeat with i from 1 to 40
                    set end of theIDs to i
                    set end of theDates to (current date)
                    set end of theSubjects to huge
                    set end of theSenders to "Mallory " & huge & " <m@example.com>"
                end repeat
                set end of theIDs to 41
                set end of theDates to (current date)
                set end of theSubjects to missing value
                set end of theSenders to "Lisa Beispiel <lisa@example.com>"
                set end of theIDs to 42
                set end of theDates to (current date)
                set end of theSubjects to item 1 of argv
                set end of theSenders to "x" & (character id 30) & "y" & tab & "z"
                return my toJSON(my batchDictionary("ACC", {"INBOX"}, missing value, missing value, theIDs, theDates, theSubjects, theSenders))
            """, arguments: ["Rechnung 10/2026 „Büro“ 👨‍👩‍👧"])
        #expect(output.utf8.count < 100_000, "40 messages with 200 KB of headers each (10 MB in full)")
        let batch = try JSONDecoder().decode(MailCandidates.Batch.self, from: Data(output.utf8))
        #expect(batch.ids.count == 42)
        #expect(batch.subjects.count == 42)
        #expect(batch.senders.count == 42)
        let cut = String(repeating: "Abc/", count: 125)
        #expect(batch.subjects[0] == cut, "the first 500 characters")
        #expect(batch.senders[0] == "Mallory " + cut.prefix(492))
        #expect(batch.subjects[40] == "", "a missing subject stays empty")
        #expect(batch.senders[40] == "Lisa Beispiel <lisa@example.com>")
        #expect(batch.subjects[41] == "Rechnung 10/2026 „Büro“ 👨‍👩‍👧")
        #expect(batch.senders[41] == "x y z", "control characters of a cut list become spaces")
        #expect(!output.contains("\\/"), "slashes are not escaped")
    }

    private struct ShortenedValues: Decodable {
        var short: [String?]
        var long: [String?]
        var exact: [String?]
    }

    @Test func mailSearchLeavesShortValuesAsTheyAre() async throws {
        let handlers = try AppleScriptFilesTests.handlers(["shortened", "toJSON"], from: try Self.source("mail-search"))
        let output = try await AppleScriptFilesTests.runHandlers(handlers, body: """
                set separator to character id 30
                set fewShort to my shortened({"a/b", missing value, "c" & separator & "d" & tab & "e", ""}, 5)
                set fewLong to my shortened({"abcdefgh", missing value, "<null>", "x" & separator & "yyyyyyyy", "12345", "123456"}, 5)
                set exact to my shortened({item 1 of argv, item 2 of argv}, 5)
                return my toJSON(current application's NSDictionary's dictionaryWithObjects:{fewShort, fewLong, exact} forKeys:{"short", "long", "exact"})
            """, arguments: ["abcd👍", "ab👨‍👩‍👧"])
        let values = try JSONDecoder().decode(ShortenedValues.self, from: Data(output.utf8))
        #expect(values.short == ["a/b", nil, "c\u{1E}d\te", ""], "nothing too long: the values as they were")
        #expect(values.long == ["abcde", "", "", "x yyy", "12345", "12345"], "cut, nothing lost or added")
        #expect(values.exact == ["abcd👍", "ab👨\u{200D}👩"], "counted in code points, never inside one")
    }

    @Test func mailSearchRetriesAMailWideMailboxAndReportsWhatFailed() async throws {
        let handlers = try AppleScriptFilesTests.handlers(["isFatal", "failureKind"], from: try Self.source("mail-search"))
        let output = try await AppleScriptFilesTests.runHandlers(handlers, body: """
                set kinds to {}
                repeat with probe in {{-1743, 1, 2}, {-128, 1, 1}, {-1712, 1, 2}, {-1728, 1, 2}, {-1728, 2, 2}, {-10000, 1, 1}, {-1700, 1, 2}, {1002, 1, 2}, {1002, 1, 1}}
                    set end of kinds to my failureKind(item 1 of probe, item 2 of probe, item 3 of probe)
                end repeat
                set AppleScript's text item delimiters to ","
                return kinds as text
            """)
        #expect(output.split(separator: ",") == ["fatal", "fatal", "stop", "retry", "failed", "failed", "retry", "failed", "failed"],
                "a denied permission ends the search, a timeout stops it, anything else is retried once (Mail-wide) and then reported, never dropped")
    }

    /// The run loop never drops a mailbox silently: every error that does not
    /// end the search puts it into "skipped" (time) or "failed" (with the number).
    @Test func mailSearchNeverLeavesOutAMailboxSilently() throws {
        let code = try Self.code("mail-search")
        #expect(code.contains("(failed's addObject:(current application's NSDictionary's dictionaryWithObjects:{label, errorNumber} forKeys:{\"mailbox\", \"error\"}))"))
        #expect(code.contains("set outcome to my failureKind(errorNumber, attempt, attempts)"))
        #expect(code.contains("if boxPath is missing value then set attempts to 2"))
        #expect(code.contains("forKeys:{\"batches\", \"accounts\", \"complete\", \"skipped\", \"failed\"}"))
    }

    /// mail-search's real run loop (taken from the script as it is) with a
    /// stand-in for containerBatch that fails like Mail can, `failures` times
    /// with `error` and then answers: for each scenario, what the script prints
    /// and how often the mailbox was read. One osascript run; no app is involved.
    static func runSearchLoop(_ scenarios: [(error: Int, failures: Int, mailWide: Bool)]) async throws
        -> [(calls: Int, found: MailCandidates)] {
        let source = try Self.source("mail-search")
        let lines = source.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex(of: "\tset batches to current application's NSMutableArray's array()"))
        let end = try #require(lines[start...].firstIndex(of: "end run"))
        let loop = lines[start..<end].joined(separator: "\n")
            .replacingOccurrences(of: "\treturn my toJSON(", with: "\treturn (gCalls as text) & linefeed & my toJSON(")
        let harness = """
            on containerBatch(theContainer, boxPath, accountID, startDate, endDate, unreadOnly, theDeadline)
                global gError, gFailures, gCalls
                set gCalls to gCalls + 1
                if gFailures > 0 then
                    set gFailures to gFailures - 1
                    error "Mail got an error." number gError
                end if
                return current application's NSDictionary's dictionaryWithObjects:{{7}, {}, {"Projekt"}, {"Lisa"}} forKeys:{"ids", "dates", "subjects", "senders"}
            end containerBatch

            on searchLoop(containers)
                global gError, gFailures, gCalls
                set accountRecords to current application's NSMutableArray's array()
                set startTime to current date
                set budget to 35
                set theDeadline to startTime + budget + 15
                set startDate to startTime - 30 * days
                set endDate to startTime
                set unreadOnly to false
            \(loop)
            end searchLoop
            """
        let handlers = try AppleScriptFilesTests.handlers(["isFatal", "failureKind", "toJSON"], from: source) + "\n\n" + harness
        let output = try await AppleScriptFilesTests.runHandlers(handlers, body: """
                global gError, gFailures, gCalls
                set outputs to {}
                repeat with i from 1 to count of argv by 3
                    set gError to (item i of argv) as integer
                    set gFailures to (item (i + 1) of argv) as integer
                    set gCalls to 0
                    if (item (i + 2) of argv) is "true" then
                        set end of outputs to my searchLoop({{"inbox-ref", missing value, "", {"inbox"}}})
                    else
                        set end of outputs to my searchLoop({{"box-ref", {"Archiv"}, "ACC", {"Archiv"}}})
                    end if
                end repeat
                set AppleScript's text item delimiters to linefeed
                return outputs as text
            """, arguments: scenarios.flatMap { [String($0.error), String($0.failures), $0.mailWide ? "true" : "false"] })
        let printed = output.components(separatedBy: "\n")
        try #require(printed.count == 2 * scenarios.count, "\(output)")
        return try stride(from: 0, to: printed.count, by: 2).map { index in
            (try #require(Int(printed[index])), try JSONDecoder().decode(MailCandidates.self, from: Data(printed[index + 1].utf8)))
        }
    }

    @Test func aMailWideMailboxThatFailsIsReadAgainAndThenReportedNeverDropped() async throws {
        let results = try await Self.runSearchLoop([
            (-1728, 2, true),   // a message vanished while Mail evaluated the request (a rule filed it)
            (-10000, 1, true),  // once is not enough to give up
            (1002, 5, true),    // the mailbox changed: containerBatch already read it twice
            (-1712, 5, true),   // Mail still busy: skipped, as before
        ])
        let (failing, flaky, changed, busy) = (results[0], results[1], results[2], results[3])
        #expect(failing.calls == 2, "read a second time")
        #expect(failing.found.batches.isEmpty)
        #expect(failing.found.failed == [MailCandidates.Failure(mailbox: ["inbox"], error: -1728)])
        #expect(!failing.found.complete)
        #expect(failing.found.searchedNothing)
        #expect(flaky.calls == 2)
        #expect(flaky.found.batches.count == 1)
        #expect(flaky.found.failed.isEmpty)
        #expect(flaky.found.complete)
        #expect(changed.calls == 1)
        #expect(changed.found.failed == [MailCandidates.Failure(mailbox: ["inbox"], error: 1002)])
        #expect(busy.calls == 1)
        #expect(busy.found.skipped == [["inbox"]])
        #expect(busy.found.failed.isEmpty)
        // A denied permission ends the whole search.
        await #expect(throws: AppleScriptError.self) {
            _ = try await Self.runSearchLoop([(-1743, 1, true)])
        }
    }

    @Test func aMailboxOfAllOrANamedOneThatFailsIsReportedWithItsError() async throws {
        let results = try await Self.runSearchLoop([(-10000, 1, false), (0, 0, false)])
        let (failing, fine) = (results[0], results[1])
        #expect(failing.calls == 1, "one of many mailboxes: not read again")
        #expect(failing.found.failed == [MailCandidates.Failure(mailbox: ["Archiv"], error: -10000)])
        #expect(!failing.found.complete)
        #expect(fine.found.batches.count == 1)
        #expect(fine.found.failed.isEmpty)
        #expect(fine.found.complete)
    }

    private struct SummaryHandlers: Decodable {
        struct Line: Decodable {
            var number: Int
            var account: String
            var mailbox: [String]
        }

        var lines: [Line]
        var prefixes: [String]
        var seconds: [Double?]
        var fatal: [Bool]
    }

    @Test func mailSummariesReadItsLines() async throws {
        let names = ["parseLine", "isFatal", "pathText", "prefix", "dateSeconds", "nonEmptyLines", "toJSON"]
        let handlers = try AppleScriptFilesTests.handlers(names, from: try Self.source("mail-summaries"))
        let output = try await AppleScriptFilesTests.runHandlers(handlers, body: """
                set parsed to current application's NSMutableArray's array()
                set requestLines to my nonEmptyLines(item 1 of argv)
                repeat with i from 1 to count of requestLines
                    set {theNumber, accountID, boxPath} to my parseLine(item i of requestLines)
                    (parsed's addObject:(current application's NSDictionary's dictionaryWithObjects:{theNumber, accountID, boxPath} forKeys:{"number", "account", "mailbox"}))
                end repeat
                set someDate to current application's NSDate's dateWithTimeIntervalSince1970:1790856120
                set dateValues to {my dateSeconds(someDate as date), my dateSeconds(missing value), my dateSeconds("2026")}
                set fatal to {my isFatal(-1743), my isFatal(-1712), my isFatal(-1728)}
                set payload to current application's NSDictionary's dictionaryWithObjects:{parsed, {my prefix(item 2 of argv, 3), my prefix("Hallo", 0), my prefix("Hallo", 10)}, dateValues, fatal} forKeys:{"lines", "prefixes", "seconds", "fatal"}
                return my toJSON(payload)
            """, arguments: ["4711\tACC-1\tArchiv\tRechnungen\n7\t\tLokal\n9", "ab👨‍👩‍👧cd"])
        let result = try JSONDecoder().decode(SummaryHandlers.self, from: Data(output.utf8))
        #expect(result.lines.map(\.number) == [4711, 7, 9])
        #expect(result.lines[0].account == "ACC-1")
        #expect(result.lines[0].mailbox == ["Archiv", "Rechnungen"])
        #expect(result.lines[1].account == "")
        #expect(result.lines[1].mailbox == ["Lokal"])
        #expect(result.lines[2].mailbox == [])
        #expect(result.prefixes == ["ab👨‍👩‍👧", "", "Hallo"], "a character is never split")
        #expect(result.seconds == [1_790_856_120, nil, nil])
        #expect(result.fatal == [true, false, false])
    }

    @Test func mailSummariesStopsOnALineThatIsNoMessage() async throws {
        // Orbit never sends one; the script fails instead of guessing.
        let handlers = try AppleScriptFilesTests.handlers(["parseLine"], from: try Self.source("mail-summaries"))
        await #expect(throws: AppleScriptError.self) {
            _ = try await AppleScriptFilesTests.runHandlers(handlers, body: "return item 1 of my parseLine(item 1 of argv)",
                                                            arguments: ["x12\tA"])
        }
    }

    private struct ReadHandlers: Decodable {
        var addresses: [MailMessage.Address]
        var mismatched: [MailMessage.Address]
        var attachments: [MailMessage.Attachment]
        var unsized: [MailMessage.Attachment]
    }

    @Test func mailReadBuildsRecipientsAndAttachments() async throws {
        let names = ["addressDictionaries", "attachmentDictionaries", "toJSON"]
        let handlers = try AppleScriptFilesTests.handlers(names, from: try Self.source("mail-read"))
        let output = try await AppleScriptFilesTests.runHandlers(handlers, body: """
                set addresses to my addressDictionaries({item 1 of argv, missing value}, {"e@example.org", "m@example.com"})
                set mismatched to my addressDictionaries({"a"}, {"a@example.com", "b@example.com"})
                set attachments to my attachmentDictionaries({"Rechnung.pdf", "see.png"}, {2048, missing value})
                set unsized to my attachmentDictionaries({"x.txt"}, {})
                return my toJSON(current application's NSDictionary's dictionaryWithObjects:{addresses, mismatched, attachments, unsized} forKeys:{"addresses", "mismatched", "attachments", "unsized"})
            """, arguments: ["Erika „E.“ Müller"])
        let result = try JSONDecoder().decode(ReadHandlers.self, from: Data(output.utf8))
        #expect(result.addresses == [.init(name: "Erika „E.“ Müller", address: "e@example.org"), .init(name: nil, address: "m@example.com")])
        #expect(result.mismatched.isEmpty)
        #expect(result.attachments == [.init(name: "Rechnung.pdf", size: 2048), .init(name: "see.png", size: nil)])
        #expect(result.unsized == [.init(name: "x.txt", size: nil)])
    }

    @Test(arguments: ["mail-search", "mail-summaries"])
    func requestsGetTheTimeLeftUntilTheDeadline(script: String) async throws {
        let handlers = try AppleScriptFilesTests.handlers(["secondsLeft"], from: try Self.source(script))
        let output = try await AppleScriptFilesTests.runHandlers(handlers, body: """
                set timeLeft to my secondsLeft((current date) + 30)
                try
                    my secondsLeft((current date) - 1)
                    set lateError to 0
                on error number errorNumber
                    set lateError to errorNumber
                end try
                try
                    my secondsLeft(current date)
                    set nowError to 0
                on error number errorNumber
                    set nowError to errorNumber
                end try
                return (timeLeft as text) & "," & lateError & "," & nowError
            """)
        let values = output.split(separator: ",").compactMap { Int($0) }
        #expect(values.count == 3)
        #expect((29...30).contains(values.first ?? 0))
        #expect(values.dropFirst() == [-1712, -1712], "no time left is a timeout")
    }

    private struct ReplyHandlers: Decodable {
        var addresses: [MailMessage.Address]
        var mismatched: [MailMessage.Address]
        var lines: [String]
        var paths: [String]
        var seconds: [Double?]
        var fatal: [Bool]
    }

    @Test func mailReplyHandlersWorkWithoutMail() async throws {
        let names = ["addressDictionaries", "isFatal", "pathText", "dateSeconds", "nonEmptyLines", "toJSON"]
        let handlers = try AppleScriptFilesTests.handlers(names, from: try Self.source("mail-reply"))
        let output = try await AppleScriptFilesTests.runHandlers(handlers, body: """
                set addresses to my addressDictionaries({item 1 of argv, missing value}, {"lisa@example.com", "team@example.com"})
                set mismatched to my addressDictionaries({"a"}, {})
                set someDate to current application's NSDate's dateWithTimeIntervalSince1970:1790856120
                set fatal to {}
                repeat with errorNumber in {-1743, -1744, -600, -609, -128, -1712, -1728}
                    set end of fatal to my isFatal(contents of errorNumber)
                end repeat
                set payload to current application's NSDictionary's dictionaryWithObjects:{addresses, mismatched, my nonEmptyLines(item 2 of argv), {my pathText({"Archiv", "Rechnungen"}), my pathText({})}, {my dateSeconds(someDate as date), my dateSeconds(missing value)}, fatal} forKeys:{"addresses", "mismatched", "lines", "paths", "seconds", "fatal"}
                return my toJSON(payload)
            """, arguments: ["Lisa „L.“ Beispiel", "Archiv\nRechnungen\n"])
        let result = try JSONDecoder().decode(ReplyHandlers.self, from: Data(output.utf8))
        #expect(result.addresses == [.init(name: "Lisa „L.“ Beispiel", address: "lisa@example.com"),
                                     .init(name: nil, address: "team@example.com")])
        #expect(result.mismatched.isEmpty)
        #expect(result.lines == ["Archiv", "Rechnungen"])
        #expect(result.paths == ["Archiv/Rechnungen", ""])
        #expect(result.seconds == [1_790_856_120, nil])
        #expect(result.fatal == [true, true, true, true, true, false, false],
                "once the window is open, a slow or missing answer does not fail the run")
    }

    @Test func mailDraftSplitsRecipientLines() async throws {
        let names = ["recipientParts", "isFatal", "nonEmptyLines", "toJSON"]
        let handlers = try AppleScriptFilesTests.handlers(names, from: try Self.source("mail-draft"))
        let output = try await AppleScriptFilesTests.runHandlers(handlers, body: """
                set found to {}
                set recipientLines to my nonEmptyLines(item 1 of argv)
                repeat with i from 1 to count of recipientLines
                    set end of found to my recipientParts(item i of recipientLines)
                end repeat
                set end of found to {my isFatal(-1712), my isFatal(-1728)}
                return my toJSON(found)
            """, arguments: [MailService.recipientLine(MailRecipient(address: "lisa@example.com", name: "Lisa „L.“ Beispiel"))
                             + "\n" + MailService.recipientLine(MailRecipient(address: "max@example.com"))])
        let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[Any]]
        #expect(result?[0] as? [String] == ["lisa@example.com", "Lisa „L.“ Beispiel"])
        #expect(result?[1] as? [String] == ["max@example.com", ""])
        #expect(result?[2] as? [Bool] == [true, false], "a timeout ends the draft run")
    }
}
