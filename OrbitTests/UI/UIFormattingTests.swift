import Foundation
import SwiftUI
import Testing
@testable import Orbit

@Suite("Card formatting")
struct CardFormattingTests {
    let germany: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        calendar.locale = Locale(identifier: "de_DE")
        return calendar
    }()
    let german = Locale(identifier: "de_DE")

    private func date(_ text: String) -> Date {
        FlexibleDate.parse(text, timeZone: germany.timeZone)!.date
    }

    /// ICU separates some parts with thin or narrow no-break spaces ("2:00 PM").
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2009}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    // Exact punctuation comes from ICU and differs between macOS versions, so
    // these tests check the chosen branch and the relevant parts.
    @Test func shortDates() {
        let now = date("2026-09-28T16:00")
        let today = CardDateFormatter.string(for: date("2026-09-28T09:05"), now: now, calendar: germany, locale: german)
        #expect(today.contains("9:05"))
        #expect(!today.contains("Sept"))
        #expect(CardDateFormatter.string(for: date("2026-09-27T23:30"), now: now, calendar: germany, locale: german) == "Gestern")
        let thisYear = CardDateFormatter.string(for: date("2026-03-03T10:00"), now: now, calendar: germany, locale: german)
        #expect(thisYear.contains("3.") && thisYear.contains("März") && !thisYear.contains("2026"))
        let lastYear = CardDateFormatter.string(for: date("2025-03-03T10:00"), now: now, calendar: germany, locale: german)
        #expect(lastYear.contains("März") && lastYear.contains("2025"))
    }

    /// German cards: ranges are written out ("14:00 bis 15:30"), no dash.
    @MainActor
    @Test func eventTimes() {
        GermanInterface.run {
            let sameDay = EventTimeFormatter.string(start: date("2026-09-29T14:00"), end: date("2026-09-29T15:30"),
                                                    isAllDay: false, calendar: germany, locale: german)
            #expect(sameDay.hasPrefix("Di"))
            #expect(sameDay.contains("29. Sept."))
            #expect(sameDay.hasSuffix(" · 14:00 bis 15:30"))
            let allDay = EventTimeFormatter.string(start: date("2026-09-29"), end: date("2026-09-30"),
                                                   isAllDay: true, calendar: germany, locale: german)
            #expect(allDay.contains("29. Sept."))
            #expect(allDay.hasSuffix(" · ganztägig"))
            #expect(!allDay.contains("30."))
            let multiDay = Self.plain(EventTimeFormatter.string(start: date("2026-09-29"), end: date("2026-10-02"),
                                                                isAllDay: true, calendar: germany, locale: german))
            #expect(multiDay.contains("29. Sept. bis Do"))
            #expect(multiDay.contains("1. Okt."))
            #expect(multiDay.hasSuffix(" · ganztägig"))
            let overnight = Self.plain(EventTimeFormatter.string(start: date("2026-09-29T22:00"), end: date("2026-09-30T02:00"),
                                                                 isAllDay: false, calendar: germany, locale: german))
            #expect(overnight.contains("29. Sept., 22:00 bis Mi"))
            #expect(overnight.contains("30. Sept., "))
            #expect(overnight.hasSuffix("2:00"))
            let broken = EventTimeFormatter.string(start: date("2026-09-29T10:00"), end: date("2026-09-29T09:00"),
                                                   isAllDay: false, calendar: germany, locale: german)
            #expect(broken.hasSuffix(" · 10:00"), "an event without length shows its start")
            for text in [sameDay, allDay, multiDay, overnight, broken] {
                #expect(!text.contains("\u{2013}") && !text.contains("\u{2014}"), "no dash: \(text)")
            }
        }
    }

    /// Each language's own words and formats (D1): "Yesterday", "Mar 3", a time
    /// range written out ("2:00 PM to 3:30 PM").
    @Test func englishCards() {
        let american = Locale(identifier: "en_US")
        let now = date("2026-09-28T16:00")
        #expect(CardDateFormatter.string(for: date("2026-09-27T23:30"), now: now, calendar: germany, locale: american) == "Yesterday")
        let thisYear = CardDateFormatter.string(for: date("2026-03-03T10:00"), now: now, calendar: germany, locale: american)
        #expect(thisYear.contains("Mar") && thisYear.contains("3") && !thisYear.contains("2026"))
        let sameDay = Self.plain(EventTimeFormatter.string(start: date("2026-09-29T14:00"), end: date("2026-09-29T15:30"),
                                                           isAllDay: false, calendar: germany, locale: american))
        #expect(sameDay.hasPrefix("Tue"))
        #expect(sameDay.contains("Sep 29 · "))
        #expect(sameDay.hasSuffix("2:00 PM to 3:30 PM"))
        let multiDay = Self.plain(EventTimeFormatter.string(start: date("2026-09-29"), end: date("2026-10-02"),
                                                            isAllDay: true, calendar: germany, locale: american))
        #expect(multiDay.hasPrefix("Tue") && multiDay.contains("Sep 29 to ") && multiDay.contains("Oct 1"))
        #expect(multiDay.hasSuffix(" · all day"))
        let overnight = Self.plain(EventTimeFormatter.string(start: date("2026-09-29T22:00"), end: date("2026-09-30T02:00"),
                                                             isAllDay: false, calendar: germany, locale: american))
        #expect(overnight.contains("10:00 PM to ") && overnight.contains("Sep 30") && overnight.hasSuffix("2:00 AM"))
        #expect(MediaDuration.string(seconds: 42, locale: american) == "0:42")
    }

    /// Without a locale, cards format with the interface's (`AppLanguage.locale`):
    /// English in the test process, German dates for German texts even when the
    /// process runs in another language.
    @MainActor
    @Test func cardsDefaultToTheInterfaceLocale() {
        let now = date("2026-09-28T16:00")
        let march = CardDateFormatter.string(for: date("2026-03-03T10:00"), now: now, calendar: germany)
        #expect(march == CardDateFormatter.string(for: date("2026-03-03T10:00"), now: now, calendar: germany,
                                                  locale: AppLanguage.locale))
        #expect(march.contains("Mar"))
        #expect(EventTimeFormatter.string(start: date("2026-10-05"), end: date("2026-10-06"), isAllDay: true,
                                          calendar: germany).hasPrefix("Mon"))
        #expect(PhotoCardFormat.date(date("2026-07-13T18:42"), now: now, calendar: germany).contains("July"))
        let file = FileItem(path: "/x/a.pdf", name: "a.pdf", size: 2_310_000)
        #expect(FileCardFormat.size(of: file) == FileCardFormat.size(of: file, locale: AppLanguage.locale))
        GermanInterface.run {
            #expect(CardDateFormatter.string(for: date("2026-03-03T10:00"), now: now, calendar: germany).contains("März"))
            #expect(EventTimeFormatter.string(start: date("2026-10-05"), end: date("2026-10-06"), isAllDay: true,
                                              calendar: germany).hasPrefix("Mo"))
            #expect(PhotoCardFormat.date(date("2026-07-13T18:42"), now: now, calendar: germany).contains("Juli"))
            #expect(FileCardFormat.size(of: file) == "2,3 MB")
        }
    }

    /// Dates and sizes inside composed texts follow the locale too.
    @Test func composedTextsFollowTheLocale() {
        let resets = date("2026-10-05T18:00")
        let info = RateLimitInfo(status: "rejected", utilization: 1, resetsAt: resets, window: "five_hour", isUsingOverage: false)
        #expect(ProviderUsage.resetText(for: info, locale: german)?.contains("5. Okt. 2026") == true)
        #expect(Self.plain(ProviderUsage.resetDate(resets, locale: Locale(identifier: "en_US"))).contains("Oct 5, 2026"))
        let image = ShortcutOutput.OutputFile(typeIdentifier: "public.png", size: 2_310_000)
        #expect(RunShortcutTool.shownFile(image, locale: german).hasSuffix(", 2,3 MB"))
        #expect(RunShortcutTool.shownFile(image, locale: Locale(identifier: "en_US")).hasSuffix(", 2.3 MB"))
    }

    @Test func paths() {
        #expect(FilePathFormatter.parentFolder(of: "/Users/lisa/Documents/Rechnungen/a.pdf", homeDirectory: "/Users/lisa")
                == "~/Documents/Rechnungen")
        #expect(FilePathFormatter.abbreviate("/Users/lisa", homeDirectory: "/Users/lisa/") == "~")
        #expect(FilePathFormatter.abbreviate("/Users/lisa2/x", homeDirectory: "/Users/lisa") == "/Users/lisa2/x")
        #expect(FilePathFormatter.parentFolder(of: "/Volumes/Daten/x.txt", homeDirectory: "/Users/lisa") == "/Volumes/Daten")
    }

    @Test func durations() {
        #expect(MediaDuration.string(seconds: 42.4) == "0:42")
        #expect(MediaDuration.string(seconds: 725) == "12:05")
        #expect(MediaDuration.string(seconds: 3723) == "1:02:03")
        #expect(MediaDuration.string(seconds: -5) == "0:00")
    }

    @Test func initials() {
        #expect(ContactInitials.initials(for: "Lisa Müller") == "LM")
        #expect(ContactInitials.initials(for: "lisa") == "L")
        #expect(ContactInitials.initials(for: "Anna-Lena Schmidt Weber") == "AL")
        #expect(ContactInitials.initials(for: "  ") == "?")
        #expect(ContactInitials.initials(for: "Émile Zola") == "ÉZ")
    }

    @Test func mailLinks() {
        #expect(MailLink.url(messageID: "<abc.123@mail.example.com>")?.absoluteString == "message://%3Cabc.123@mail.example.com%3E")
        #expect(MailLink.url(messageID: "a+b=c/d@x")?.absoluteString == "message://%3Ca%2Bb%3Dc%2Fd@x%3E")
        #expect(MailLink.url(messageID: "<>") == nil)
        #expect(ContactLinks.mailURL("lisa@example.com")?.absoluteString == "mailto:lisa@example.com")
        #expect(ContactLinks.mailURL("kein Mail") == nil)
        #expect(ContactLinks.mailURL("a@b.c?subject=x") == nil)
    }

    @Test func hexColors() throws {
        let components = try #require(Theme.rgbComponents(fromHex: "#FF8000"))
        #expect(components.red == 1)
        #expect(abs(components.green - 128.0 / 255) < 0.0001)
        #expect(components.blue == 0)
        #expect(Theme.rgbComponents(fromHex: "00ff00") != nil)
        #expect(Theme.rgbComponents(fromHex: "#FFF") == nil)
        #expect(Theme.rgbComponents(fromHex: "#GGGGGG") == nil)
        #expect(Theme.color(hex: nil) == nil)
    }
}

@Suite("Markdown inline and links")
@MainActor
struct MarkdownInlineTests {
    @Test func allowsOnlyWebAndMailLinks() throws {
        #expect(MarkdownLinkPolicy.allows(try #require(URL(string: "https://example.com"))))
        #expect(MarkdownLinkPolicy.allows(try #require(URL(string: "HTTP://example.com"))))
        #expect(MarkdownLinkPolicy.allows(try #require(URL(string: "mailto:a@b.example"))))
        #expect(!MarkdownLinkPolicy.allows(try #require(URL(string: "file:///etc/passwd"))))
        #expect(!MarkdownLinkPolicy.allows(try #require(URL(string: "shortcuts://run-shortcut?name=x"))))
        #expect(!MarkdownLinkPolicy.allows(try #require(URL(string: "x-apple.systempreferences:com.apple.preference.security"))))
        #expect(!MarkdownLinkPolicy.allows(try #require(URL(string: "javascript:alert(1)"))))
        #expect(!MarkdownLinkPolicy.allows(try #require(URL(string: "relative/path"))))
    }

    @Test func parsesEmphasisAndCode() {
        let text = MarkdownInline.attributedString(from: "Ein **fettes** Wort und `code`")
        #expect(String(text.characters) == "Ein fettes Wort und code")
        let bold = text.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(bold.map { String(text[$0.range].characters) } == "fettes")
        let code = text.runs.first { $0.inlinePresentationIntent?.contains(.code) == true }
        #expect(code.map { String(text[$0.range].characters) } == "code")
        #expect(code?.swiftUI.backgroundColor != nil)
    }

    @Test func keepsLineBreaks() {
        #expect(String(MarkdownInline.attributedString(from: "eins\nzwei").characters) == "eins\nzwei")
    }

    @Test func linksBareURLsButNotInsideCode() {
        let text = MarkdownInline.attributedString(from: "Siehe https://example.com/a und `https://example.org`")
        let links = text.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://example.com/a")!])
    }

    @Test func keepsExplicitLinks() {
        let text = MarkdownInline.attributedString(from: "[Doku](https://example.com/doku)")
        #expect(String(text.characters) == "Doku")
        #expect(text.runs.compactMap(\.link) == [URL(string: "https://example.com/doku")!])
    }

    @Test func unbalancedMarkersFallBackToText() {
        #expect(String(MarkdownInline.attributedString(from: "**offen").characters) == "**offen")
        #expect(String(MarkdownInline.attributedString(from: "").characters).isEmpty)
    }
}

@Suite("FlowLayout lines")
struct FlowLayoutTests {
    @Test func wrapsGreedily() {
        let sizes = [CGSize(width: 100, height: 20), CGSize(width: 100, height: 24), CGSize(width: 100, height: 20)]
        let lines = FlowLayout.lines(for: sizes, maxWidth: 220, spacing: 10)
        #expect(lines.map(\.indices) == [[0, 1], [2]])
        #expect(lines[0].width == 210)
        #expect(lines[0].height == 24)
    }

    @Test func oversizedItemGetsItsOwnLine() {
        let sizes = [CGSize(width: 50, height: 20), CGSize(width: 500, height: 20), CGSize(width: 50, height: 20)]
        let lines = FlowLayout.lines(for: sizes, maxWidth: 200, spacing: 6)
        #expect(lines.map(\.indices) == [[0], [1], [2]])
        #expect(lines[1].width == 200)
    }

    @Test func emptyInput() {
        #expect(FlowLayout.lines(for: [], maxWidth: 100, spacing: 6).isEmpty)
    }
}

@Suite("Settings logic")
struct SettingsLogicTests {
    @Test(arguments: [
        ("", BaseURLCheck.empty),
        ("   ", .empty),
        ("https://api.anthropic.com", .valid),
        ("http://localhost:11434/v1", .valid),
        ("http://127.0.0.1:11434", .valid),
        ("http://192.168.1.20:1234/v1", .valid),
        ("http://172.20.0.5/v1", .valid),
        ("http://mac-mini.local:11434/v1", .valid),
        ("http://[::1]:11434/v1", .valid),
        ("http://gaming-pc:11434/v1", .valid),
        ("http://api.example.com/v1", .cleartextBlocked),
        ("http://gaming-pc.fritz.box:11434/v1", .cleartextBlocked),
        ("https://gaming-pc.fritz.box/v1", .valid),
        ("http://172.40.0.5/v1", .insecure),
        ("http://[2001:db8::1]/v1", .insecure),
        ("localhost:11434", .invalid),
        ("ftp://example.com", .invalid),
        ("https://", .invalid),
        ("kein url", .invalid),
    ])
    func baseURLCheck(text: String, expected: BaseURLCheck) {
        #expect(BaseURLCheck.check(text) == expected)
    }

    @Test func toolSectionsFollowCategoryOrder() {
        let tools = [
            ToolInfo(name: "search_mail", description: "", category: .mail, riskLevel: .read, requiredPermissions: []),
            ToolInfo(name: "search_files", description: "", category: .files, riskLevel: .read, requiredPermissions: []),
            ToolInfo(name: "open_file", description: "", category: .files, riskLevel: .draft, requiredPermissions: []),
        ]
        let sections = ToolSection.sections(for: tools)
        #expect(sections.map(\.category) == [.files, .mail])
        #expect(sections[0].tools.map(\.name) == ["search_files", "open_file"], "in the order they are registered")
        #expect(ToolSection.sections(for: []).isEmpty)
    }

    /// Settings lists the file tools in their registration order, not sorted by
    /// the English names (which reads at random in German).
    @Test func fileToolsAreListedInTheirRegistrationOrder() {
        let infos = ToolRegistry(tools: AppEnvironment.makeTools(services: .fake())).infos
        let files = ToolSection.sections(for: infos).first { $0.category == .files }
        #expect(files?.tools.map(\.name) == ["search_files", "read_file", "open_file", "reveal_in_finder", "recent_files"])
    }

    @Test func launchAtLoginStates() {
        #expect(LaunchAtLoginModel.state(for: .enabled) == .enabled)
        #expect(LaunchAtLoginModel.state(for: .notRegistered) == .disabled)
        #expect(LaunchAtLoginModel.state(for: .requiresApproval) == .requiresApproval)
        #expect(LaunchAtLoginModel.state(for: .notFound) == .disabled)
    }

    @Test func settingsTabsKeepTheirOrder() {
        #expect(SettingsTab.allCases == [.general, .model, .tools, .permissions, .privacy])
    }
}

@Suite("APIKeyEditor")
@MainActor
struct APIKeyEditorTests {
    struct BrokenStore: SecretStoring {
        func secret(for account: String) throws -> String? { throw KeychainError.unexpectedStatus(-25293) }
        func setSecret(_ secret: String?, for account: String) throws { throw KeychainError.unexpectedStatus(-25293) }
    }

    @Test func savesAndRemovesKeyPerProvider() async throws {
        let store = InMemorySecretStore()
        let editor = APIKeyEditor(secrets: store)
        await editor.load(kind: .anthropic)
        #expect(editor.status == .notSaved)

        editor.draft = "  sk-ant-test  "
        #expect(editor.hasDraft)
        await editor.save()
        #expect(editor.status == .saved)
        #expect(editor.draft.isEmpty)
        #expect(try store.secret(for: SecretAccount.anthropicAPIKey) == "sk-ant-test")
        #expect(try store.secret(for: SecretAccount.openAICompatibleAPIKey) == nil)

        await editor.load(kind: .openAICompatible)
        #expect(editor.status == .notSaved)
        await editor.load(kind: .anthropic)
        #expect(editor.status == .saved)

        await editor.remove()
        #expect(editor.status == .notSaved)
        #expect(try store.secret(for: SecretAccount.anthropicAPIKey) == nil)
    }

    @Test func connectionTestPrefersTypedKey() async throws {
        let store = InMemorySecretStore([SecretAccount.anthropicAPIKey: "stored"])
        let editor = APIKeyEditor(secrets: store)
        await editor.load(kind: .anthropic)
        #expect(try await editor.keyForConnectionTest() == "stored")
        editor.draft = "typed"
        #expect(try await editor.keyForConnectionTest() == "typed")
        await editor.load(kind: .openAICompatible)
        #expect(try await editor.keyForConnectionTest() == "")
    }

    @Test func emptyDraftIsNotSaved() async {
        let store = InMemorySecretStore([SecretAccount.anthropicAPIKey: "stored"])
        let editor = APIKeyEditor(secrets: store)
        await editor.load(kind: .anthropic)
        editor.draft = "   "
        await editor.save()
        #expect(editor.status == .saved)
    }

    @Test func reportsKeychainFailures() async {
        let editor = APIKeyEditor(secrets: BrokenStore())
        await editor.load(kind: .anthropic)
        guard case .failed = editor.status else {
            Issue.record("expected a failure, got \(editor.status)")
            return
        }
        editor.draft = "x"
        await editor.save()
        guard case .failed = editor.status else {
            Issue.record("expected a failure, got \(editor.status)")
            return
        }
    }
}
