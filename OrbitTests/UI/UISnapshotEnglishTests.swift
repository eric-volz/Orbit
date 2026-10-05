import AppKit
import SwiftUI
import Testing
@testable import Orbit

extension UIWindowTests {
    /// The main snapshots in English (files named `en-…`), next to the German
    /// ones of `UISnapshotTests` (German interface, German sample data):
    ///
    ///     ORBIT_UI_SNAPSHOT_DIR=/tmp/orbit-snapshots Scripts/swiftpm.sh test --filter UISnapshot
    ///
    /// The test process shows the catalog's English keys and `EnglishFormats`
    /// formats with en_US, so any German text in these pictures (other than
    /// the user's own data) bypasses the catalog. The format override affects
    /// the whole process while a test runs: run the snapshots on their own (the
    /// filter above), as all gated suites. Sample data only; nothing personal is read.
    @MainActor
    @Suite("UISnapshotEnglish", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_UI_SNAPSHOT_DIR"] != nil))
    struct UISnapshotEnglishTests {
        private var directory: URL {
            URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORBIT_UI_SNAPSHOT_DIR"] ?? NSTemporaryDirectory(), isDirectory: true)
        }

        static let american = Locale(identifier: "en_US")

        // MARK: Panel

        @Test func panelStates() async throws {
            try await EnglishFormats.run(Self.american) {
                for dark in [false, true] {
                    let environment = SnapshotEnvironment.make()
                    try await SnapshotRenderer.renderPanel(environment: environment, dark: dark, name: "en-panel-compact", in: directory)

                    environment.panelState.attachments = EnglishSampleData.attachments
                    try await SnapshotRenderer.renderPanel(environment: environment, dark: dark, name: "en-panel-chips", in: directory)

                    environment.panelState.attachments = []
                    environment.panelState.inputText = "Telekom invoice March"
                    try await SnapshotRenderer.renderPanel(environment: environment, dark: dark, name: "en-panel-search", in: directory)

                    environment.agentLoop.send("Find the Telekom invoice from March", attachments: EnglishSampleData.attachments)
                    environment.panelState.inputText = ""
                    try await SnapshotRenderer.renderPanel(environment: environment, dark: dark, name: "en-panel-chat", in: directory)
                }
            }
        }

        /// The parked chat ("Continue chat") and instant search with apps,
        /// files and contacts (fakes only).
        @Test func parkedChatAndInstantSearch() async throws {
            try await EnglishFormats.run(Self.american) {
                let folder = try TemporaryFolder("snapshot-instant-en")
                defer { folder.remove() }
                let services = try EnglishSampleData.instantSearchServices(in: folder)
                for dark in [false, true] {
                    let parked = SnapshotEnvironment.make()
                    parked.agentLoop.send("Find the Telekom invoice from March")
                    await parked.agentLoop.waitUntilIdle()
                    let hidden = Date()
                    parked.chatParking.now = { hidden }
                    parked.chatParking.panelDidHide()
                    parked.chatParking.now = { hidden.addingTimeInterval(ChatParking.pause) }
                    parked.chatParking.panelWillAppear()
                    try await SnapshotRenderer.renderPanel(environment: parked, dark: dark, name: "en-panel-parked-chat", in: directory)

                    let environment = SnapshotEnvironment.make(services: services)
                    environment.instantSearch.search("ma")
                    environment.panelState.inputText = "ma"
                    try await SnapshotRenderer.renderPanel(environment: environment, dark: dark, name: "en-panel-instant-search",
                                                           in: directory)
                }
            }
        }

        // MARK: Chat and cards

        @Test func chat() async throws {
            try await EnglishFormats.run(Self.american) {
                for dark in [false, true] {
                    try await renderChat(EnglishSampleData.conversation, isRunning: true, name: "en-chat-conversation", dark: dark)
                    try await renderChat(EnglishSampleData.cards, isRunning: false, name: "en-chat-cards", dark: dark)
                    try await renderChat(EnglishSampleData.confirmations, isRunning: true, name: "en-chat-confirmations", dark: dark)
                    try await renderChat(EnglishSampleData.reminderDates, isRunning: true, name: "en-chat-reminder-dates", dark: dark)
                    try await renderChat(EnglishSampleData.linkConfirmations, isRunning: true, name: "en-chat-link-confirmations",
                                         dark: dark)
                    try await renderChat(EnglishSampleData.failedTurn, isRunning: false, name: "en-chat-failed", dark: dark)
                    try await SnapshotRenderer.render(SnapshotRenderer.noticeSheet(SampleData.errorNotices)
                                                        .environment(\.locale, AppLanguage.locale),
                                                      dark: dark, panelBackground: true, name: "en-chat-error-notices", in: directory)
                }
            }
        }

        @Test func cards() async throws {
            try await EnglishFormats.run(Self.american) {
                let mailActions = MailCardActions(mail: MailService(runner: MockAppleScriptRunner()), opener: DisabledMessageLinkOpener(),
                                                  pasteboard: RecordingPasteboard())
                let calendarActions = CalendarCardActions(opener: RecordingCalendarAppOpener())
                let events = EnglishSampleData.events
                var created = events[1]
                created.wasCreated = true
                var createdReminder = EnglishSampleData.reminders[0]
                createdReminder.wasCreated = true
                for dark in [false, true] {
                    let mails = VStack(spacing: 10) {
                        ResultCardView(card: .mails(EnglishSampleData.mails), id: UUID())
                        ResultCardView(card: .mailDraft(EnglishSampleData.draft(reply: false)), id: UUID())
                        ResultCardView(card: .mailDraft(EnglishSampleData.draft(reply: true)), id: UUID())
                    }
                    .environment(mailActions)
                    try await render(mails, name: "en-mail-cards", dark: dark)

                    let calendar = VStack(spacing: 10) {
                        ResultCardView(card: .events(events), id: UUID())
                        ResultCardView(card: .events([created]), id: UUID())
                        ResultCardView(card: .reminders(EnglishSampleData.reminders), id: UUID())
                        ResultCardView(card: .reminders([createdReminder]), id: UUID())
                    }
                    .environment(calendarActions)
                    try await render(calendar, name: "en-calendar-cards", dark: dark)

                    let files = EnglishSampleData.fileCardItems
                    try await render(FileCardView(id: UUID(), items: files, selection: FileCardSelection(count: files.count, index: 6)),
                                     name: "en-file-card-expanded", dark: dark)
                    #if DEBUG
                    try await render(photoCards(), name: "en-photo-cards", dark: dark)
                    #endif
                }
            }
        }

        #if DEBUG
        /// The invented photo fixtures (drawn thumbnails, never real photos).
        private func photoCards() -> some View {
            var errors: [String] = []
            let data = FakePhotoData(folder: FakePersonalDataTests.fixtures, now: Date(), errors: &errors)
            let items = data.photos.filter { !$0.isHidden }.map { SearchPhotosTool.item($0.asset) }
            let actions = PhotoCardActions(photos: PhotosService(runner: MockAppleScriptRunner()),
                                           opener: RecordingPhotosAppOpener(), thumbnails: FakePhotoThumbnails(data: data))
            return PhotoCardView(id: UUID(), items: items,
                                 selection: FileCardSelection(count: items.count, index: 4,
                                                              collapsedLimit: PhotoGridLayout.collapsedLimit(columns: 7)))
                .environment(actions)
        }
        #endif

        // MARK: Settings and onboarding

        @Test func settings() async throws {
            try await EnglishFormats.run(Self.american) {
                for dark in [false, true] {
                    let environment = SnapshotEnvironment.make()
                    try await SnapshotRenderer.render(SettingsView(environment: environment), dark: dark, panelBackground: false,
                                                      name: "en-settings-window", in: directory)
                    for tab in SettingsTab.allCases {
                        let content = SettingsTabContent(tab: tab, environment: environment).frame(width: 620, height: 440)
                        try await SnapshotRenderer.render(content.environment(\.locale, AppLanguage.locale), dark: dark,
                                                          panelBackground: false, name: "en-settings-\(tab.rawValue)", in: directory)
                    }

                    let access = MockPermissionAccess([.automationMail: .granted, .automationNotes: .denied,
                                                       .contacts: .notDetermined, .calendars: .writeOnly, .reminders: .granted,
                                                       .fullDiskAccess: .unknown])
                    let manager = PermissionManager(access: access, permissions: [.automationMail, .automationNotes, .contacts,
                                                                                  .calendars, .reminders, .fullDiskAccess])
                    await manager.refresh()
                    let permissions = PermissionsSettingsView(manager: manager, mailSearch: MockMailSpotlight(available: false),
                                                              relaunch: {})
                        .frame(width: 620, height: 1_000)
                    try await SnapshotRenderer.render(permissions, dark: dark, panelBackground: false,
                                                      name: "en-settings-permissions-states", in: directory)
                    let tools = ToolsSettingsView(settings: SettingsStore(defaults: AgentTestDefaults()),
                                                  tools: ToolRegistry(tools: AppEnvironment.makeTools(services: .fake())).infos,
                                                  permissionStatuses: manager.statuses)
                        .frame(width: 620, height: 1_400)
                    try await SnapshotRenderer.render(tools, dark: dark, panelBackground: false, name: "en-settings-tools-permissions",
                                                      in: directory)
                    #expect(access.requests.isEmpty && access.openedSettings.isEmpty)

                    let settings = SettingsStore(defaults: AgentTestDefaults())
                    settings.providerKind = .claudeCode
                    let ready = ClaudeCodeStatus(availability: .ready, executablePath: "/Applications/claude", version: "2.1.284",
                                                 subscriptionType: "max", authMethod: "claude.ai")
                    let usage = RateLimitInfo(status: "allowed_warning", utilization: 0.26,
                                              resetsAt: Date().addingTimeInterval(3 * 86_400), window: "seven_day", isUsingOverage: false)
                    let model = ModelSettingsView(settings: settings, secrets: InMemorySecretStore(), validate: { _, _ in },
                                                  claudeCodeAccount: ClaudeCodeAccountModel(loadStatus: { ready }, signIn: {}),
                                                  usage: { usage })
                    try await SnapshotRenderer.render(model.frame(width: 620, height: 520), dark: dark, panelBackground: false,
                                                      name: "en-settings-claude-code-ready", in: directory)
                }
            }
        }

        @Test func onboardingSteps() async throws {
            try await EnglishFormats.run(Self.american) {
                let ready = ClaudeCodeStatus(availability: .ready, executablePath: "/Applications/claude", version: "2.1.284",
                                             subscriptionType: "max", authMethod: "claude.ai")
                let variants: [(name: String, step: OnboardingModel.Step, provider: ProviderKind, mode: OnboardingModel.Mode)] = [
                    ("welcome", .welcome, .claudeCode, .full),
                    ("provider-claude", .provider, .claudeCode, .full),
                    ("provider-api", .provider, .anthropic, .full),
                    ("provider-openai", .provider, .openAICompatible, .full),
                    ("hotkey", .hotkey, .claudeCode, .full),
                    ("mail", .permission(.automationMail), .claudeCode, .full),
                    ("calendars-add-only", .permission(.calendars), .claudeCode, .full),
                    ("done", .done, .claudeCode, .full),
                    ("new-calendars", .permission(.calendars), .claudeCode, .newPermissions([.calendars, .reminders])),
                    ("new-accessibility", .permission(.accessibility), .claudeCode, .newPermissions([.accessibility])),
                ]
                for dark in [false, true] {
                    for variant in variants {
                        let access = MockPermissionAccess([.automationMail: .notDetermined, .calendars: .writeOnly,
                                                           .reminders: .notDetermined, .accessibility: .denied])
                        let manager = PermissionManager(access: access, permissions: [.automationMail, .calendars, .reminders,
                                                                                      .accessibility])
                        await manager.refresh()
                        let settings = SettingsStore(defaults: AgentTestDefaults())
                        settings.providerKind = variant.provider
                        let model = OnboardingModel(settings: settings, permissions: manager, secrets: InMemorySecretStore(),
                                                    validate: { _, _ in },
                                                    claudeCodeAccount: ClaudeCodeAccountModel(loadStatus: { ready }, signIn: {}),
                                                    mode: variant.mode, onFinish: {})
                        model.go(to: variant.step)
                        try await SnapshotRenderer.render(OnboardingView(model: model).environment(\.locale, AppLanguage.locale),
                                                          dark: dark, panelBackground: false, name: "en-onboarding-\(variant.name)",
                                                          in: directory)
                        #expect(access.requests.isEmpty && access.openedSettings.isEmpty)
                    }
                }
            }
        }

        // MARK: Helpers

        private func renderChat(_ items: [ChatItem], isRunning: Bool, name: String, dark: Bool) async throws {
            let view = ChatView(items: items, isRunning: isRunning, conversationID: UUID(), maxHeight: 4_000, actions: ChatActions())
                .frame(width: Theme.panelWidth)
                .environment(\.locale, AppLanguage.locale)
            try await SnapshotRenderer.render(view, dark: dark, panelBackground: true, name: name, in: directory)
        }

        private func render<V: View>(_ view: V, name: String, dark: Bool) async throws {
            let card = view
                .padding(Theme.contentInset)
                .frame(width: Theme.panelWidth)
                .environment(\.locale, AppLanguage.locale)
            try await SnapshotRenderer.render(card, dark: dark, panelBackground: true, name: name, in: directory)
        }
    }
}

// MARK: - English sample data

/// Sample data for the English snapshots. Interface texts in it (tool status
/// lines, notices, card titles and fields) come from the app's own keys, which
/// are English; the user's data is English sample content.
@MainActor
enum EnglishSampleData {
    static var attachments: [ContextAttachment] {
        [
            ContextAttachment(kind: .finderSelection(paths: ["/Users/lisa/Documents/Offer.pdf"]),
                              label: ContextChipLabel.finderSelection(firstPath: "/Users/lisa/Documents/Offer.pdf", total: 1)),
            ContextAttachment(kind: .selectedText(text: "Delivery by Friday", appName: "Mail"),
                              label: ContextChipLabel.selectedText("Delivery by Friday", appName: "Mail")),
        ]
    }

    static func instantSearchServices(in folder: TemporaryFolder) throws -> AppServices {
        let now = Date()
        let files: [(String, Date, Bool)] = [
            ("Documents/Invoices/Reminder March.pdf", now.addingTimeInterval(-2 * 86_400), false),
            ("Desktop/Marketing Plan.pdf", now.addingTimeInterval(-9 * 86_400), false),
            ("Pictures/Mallorca 2026", now.addingTimeInterval(-40 * 86_400), true),
        ]
        var items: [SpotlightItem] = []
        for (path, modified, isFolder) in files {
            let url = isFolder ? try folder.makeFolder(path) : try folder.write(path, "sample")
            items.append(SpotlightItem(path: url.path, contentType: isFolder ? "public.folder" : "com.adobe.pdf",
                                       contentTypeTree: isFolder ? ["public.folder"] : ["com.adobe.pdf", "public.data"],
                                       modified: modified, size: isFolder ? nil : 6))
        }
        let found = items
        let home = folder.path
        return AppServices(
            spotlight: MockSpotlight { _ in SpotlightResults(items: found, totalCount: found.count, isComplete: true) },
            workspace: MockWorkspace(),
            fileScope: FileSearchScope.restricted(to: home, homeDirectory: home),
            fileAccess: FileAccessPolicy(homeDirectory: home, orbitDataDirectory: home + "/Library/Application Support/Orbit",
                                         restriction: home),
            appIndex: FakeAppIndex([
                IndexedApp(path: "/System/Applications/Mail.app", name: "Mail"),
                IndexedApp(path: "/System/Applications/Maps.app", name: "Maps"),
                IndexedApp(path: "/System/Applications/Calendar.app", name: "Calendar"),
            ]),
            contacts: MockContactSearch([
                ContactHit(identifier: "c1", name: "Marie Smith", detail: "marie@example.com"),
                ContactHit(identifier: "c2", name: "Martin Miller", detail: "Orbit Inc."),
            ]),
            searchOpener: MockSearchOpener(), launchCounts: InMemoryLaunchCounts(), quickLookPanel: FakeQuickLookPanel(),
            announcer: RecordingAnnouncer()
        )
    }

    static var fileCardItems: [FileItem] {
        let now = Date()
        let files: [(String, String?, TimeInterval, Int64?, Bool)] = [
            ("Documents/Invoices/Invoice-Telekom-2026-08.pdf", "com.adobe.pdf", -2 * 3_600, 184_320, false),
            ("Documents/Kitchen Quote.docx", "org.openxmlformats.wordprocessingml.document", -26 * 3_600, 48_900, false),
            ("Desktop/Quarterly Report Q3.key", "com.apple.keynote.key", -9 * 86_400, 12_400_000, false),
            ("Pictures/Screenshots/Screenshot 2026-09-12 at 10.14.png", "public.png", -18 * 86_400, 2_310_000, false),
            ("Documents/Invoices", nil, -40 * 86_400, nil, true),
            ("Documents/Notes/Moving.md", "net.daringfireball.markdown", -95 * 86_400, 3_200, false),
            ("Downloads/Receipts-2025.zip", "public.zip-archive", -400 * 86_400, 58_700_000, false),
        ]
        return files.map { path, type, age, size, isFolder in
            FileItem(path: "/Users/lisa/" + path, name: (path as NSString).lastPathComponent, contentType: type,
                     modified: now.addingTimeInterval(age), size: size, isDirectory: isFolder)
        }
    }

    static var mails: [MailItem] {
        [
            MailItem(id: "1", messageID: "abc@example.com", sender: "Lisa Miller", subject: "Project Orbit: next steps",
                     date: date("2026-09-27T16:40"), preview: "Hi! Here are the notes from the meeting. Can we talk on Thursday at 2 pm?",
                     isRead: false),
            MailItem(id: "2", messageID: nil, sender: "Telekom", subject: "Your invoice for March 2026", date: date("2026-03-12T07:00"),
                     preview: "Hello, your current invoice is ready.", isRead: true),
        ]
    }

    static func draft(reply: Bool) -> MailDraftItem {
        MailDraftItem(to: ["Lisa Miller <lisa.miller@example.com>"], cc: reply ? [] : ["max@example.com"],
                      subject: "Re: Project Orbit: next steps",
                      body: "Hi Lisa,\n\nThursday at 2 pm works for me.\n\nBest,\nErika",
                      isOpenInMail: true, draftID: reply ? 8 : 7,
                      reply: reply ? MailReplyInfo(toAll: false, isTextOnClipboard: true) : nil)
    }

    static var events: [EventItem] {
        [
            EventItem(id: "e1|1", title: "Lisa’s birthday", start: date("2026-10-05"), end: date("2026-10-06"), isAllDay: true,
                      calendarName: "Family", calendarColor: "#34C759", eventIdentifier: "e1"),
            EventItem(id: "e2|1", title: "Dentist", start: date("2026-10-05T08:30"), end: date("2026-10-05T09:15"), isAllDay: false,
                      location: "Dr. Example’s practice, 1 Sample Street", calendarName: "Home", calendarColor: "#1BADF8",
                      eventIdentifier: "e2"),
            EventItem(id: "e3|1", title: "Team meeting", start: date("2026-10-05T10:00"), end: date("2026-10-05T10:45"),
                      isAllDay: false, location: "Room 3.14", calendarName: "Work", calendarColor: "#FF9500", eventIdentifier: "e3",
                      isRecurring: true),
            EventItem(id: "e4|1", title: "Lunch with Max", start: date("2026-10-05T12:30"), end: date("2026-10-05T13:30"),
                      isAllDay: false, calendarName: "Work", calendarColor: "#FF9500", eventIdentifier: "e4", isDeclined: true),
            EventItem(id: "e5|1", title: "Client meeting", start: date("2026-10-05T15:00"), end: date("2026-10-05T16:00"),
                      isAllDay: false, calendarName: "Work", calendarColor: "#FF9500", eventIdentifier: "e5", isCanceled: true),
            EventItem(id: "e6|1", title: "Autumn holidays", start: date("2026-10-04"), end: date("2026-10-09"), isAllDay: true,
                      calendarName: "Family", calendarColor: "#34C759", eventIdentifier: "e6"),
        ]
    }

    static var reminders: [ReminderItem] {
        [
            ReminderItem(id: "r1", title: "Call Lisa", due: date("2026-10-05T09:00"), dueHasTime: true, isCompleted: false,
                         listName: "Reminders", listColor: "#1BADF8", notes: nil),
            ReminderItem(id: "r2", title: "Pay the Telekom invoice", due: date("2026-03-26"), dueHasTime: false, isCompleted: false,
                         listName: "Reminders", listColor: "#1BADF8", notes: nil),
            ReminderItem(id: "r3", title: "Bread", due: nil, dueHasTime: false, isCompleted: false, listName: "Groceries",
                         listColor: "#FF9500", notes: nil),
            ReminderItem(id: "r4", title: "Pick up the parcel", due: date("2026-10-03"), dueHasTime: false, isCompleted: true,
                         listName: "Reminders", listColor: "#1BADF8", notes: nil, completionDate: date("2026-10-03T17:30")),
        ]
    }

    static var conversation: [ChatItem] {
        [
            ChatItem(kind: .user(text: "Find the Telekom invoice from March", attachments: [attachments[0]])),
            ChatItem(kind: .toolStatus(ToolStatus(toolCallID: "1", toolName: "search_files", category: .files,
                                                  text: String(format: String(localized: "Found %lld files"), 3), state: .succeeded))),
            ChatItem(kind: .progress(text: "Let me check whether there is an email about it.")),
            ChatItem(kind: .toolStatus(ToolStatus(toolCallID: "2", toolName: "search_mail", category: .mail,
                                                  text: String(localized: "No emails found"), state: .failed))),
            ChatItem(kind: .toolStatus(ToolStatus(toolCallID: "3", toolName: "read_file", category: .files,
                                                  text: String(format: String(localized: "Reading “%@”…"), "Telekom_2026-03.pdf"),
                                                  state: .cancelled))),
            ChatItem(kind: .card(.files([
                FileItem(path: "/Users/lisa/Documents/Invoices/Telekom_2026-03.pdf", name: "Telekom_2026-03.pdf",
                         contentType: "com.adobe.pdf", modified: date("2026-03-12T09:14")),
                FileItem(path: "/Users/lisa/Downloads/Telekom invoice March.pdf", name: "Telekom invoice March.pdf",
                         contentType: "com.adobe.pdf", modified: date("2026-03-11T18:02")),
                FileItem(path: "/Users/lisa/Documents/Invoices", name: "Invoices", modified: date("2025-11-02T10:00"), isDirectory: true),
            ]))),
            ChatItem(kind: .assistant(text: """
                I found **3 invoices** from Telekom for March. The latest is `Telekom_2026-03.pdf` from March 12.

                - Amount: **€39.95**
                - Due on March 26
                """, isStreaming: false)),
            ChatItem(kind: .disclosure(items: [ContentDisclosure(kind: .fileNames, count: 3), ContentDisclosure(kind: .fileContents, count: 1),
                                               ContentDisclosure(kind: .photos, count: 2)],
                                       providerName: "Claude")),
            ChatItem(kind: .user(text: "And when was the February one due?", attachments: [])),
            ChatItem(kind: .assistant(text: "The February invoice was due on", isStreaming: true)),
        ]
    }

    static var cards: [ChatItem] {
        [
            ChatItem(kind: .card(.mails(mails))),
            ChatItem(kind: .card(.events(Array(events.prefix(2))))),
            ChatItem(kind: .card(.reminders(Array(reminders.prefix(2))))),
            ChatItem(kind: .card(.contacts([
                ContactItem(id: "p1", name: "Lisa Miller", organization: "Orbit Inc.", emails: ["lisa@example.com"],
                            phones: ["+1 555 0100"]),
            ]))),
            ChatItem(kind: .card(.notes([
                NoteItem(id: "n1", title: "Moving", excerpt: "Order boxes, register the move, forward the mail …", folder: "Personal",
                         modified: date("2026-09-20T11:00")),
            ]))),
            ChatItem(kind: .card(.photos((0..<9).map { index in
                PhotoItem(id: "ph\(index)", creationDate: date("2025-07-1\(index % 9)T12:00"),
                          mediaType: index == 2 ? .video : (index == 5 ? .livePhoto : .image), isFavorite: index == 1,
                          duration: index == 2 ? 42 : nil)
            }))),
            ChatItem(kind: .card(.mailDraft(draft(reply: false)))),
            ChatItem(kind: .card(.info(InfoItem(title: String(localized: "Dark appearance"),
                                                detail: String(localized: "Turned on for all apps."), systemImage: "moon.fill")))),
        ]
    }

    static var confirmations: [ChatItem] {
        [
            ChatItem(kind: .confirmation(ConfirmationState(request: ConfirmationRequest(
                toolName: "create_event", riskLevel: .write, title: String(localized: "Create event"),
                message: String(localized: "Orbit creates this event in your calendar."),
                fields: [
                    ConfirmationField(id: "title", label: String(localized: "Titel"), value: "Dentist", kind: .text),
                    ConfirmationField(id: "start", label: String(localized: "Start"), value: "2026-09-29T14:00", kind: .dateTime),
                    ConfirmationField(id: "notes", label: String(localized: "Notizen"), value: "Bring the insurance card",
                                      kind: .multilineText),
                    ConfirmationField(id: "calendar", label: String(localized: "Kalender"), value: "Home", kind: .readOnly),
                ], confirmLabel: String(localized: "Create")), status: .pending))),
            ChatItem(kind: .confirmation(ConfirmationState(request: ConfirmationRequest(
                toolName: "set_volume", riskLevel: .write, title: String(localized: "Change volume"),
                message: String(localized: "Orbit sets the volume of your output device."),
                fields: [
                    ConfirmationField(id: "level", label: String(localized: "Volume (0 to 100)"), value: "30", kind: .text),
                    ConfirmationField(id: "current", label: String(localized: "Current"),
                                      value: String(format: String(localized: "%lld%% (muted)"), 50), kind: .readOnly),
                ], confirmLabel: String(localized: "Set")), status: .approved))),
            ChatItem(kind: .confirmation(ConfirmationState(request: ConfirmationRequest(
                toolName: "set_appearance", riskLevel: .write, title: String(localized: "Change appearance"), message: ""),
                status: .expired))),
            ChatItem(kind: .notice(Notice(style: .error, message: LLMError.overloaded.userMessage, action: .retry))),
            ChatItem(kind: .notice(Notice(style: .warning, message: LLMError.missingAPIKey.userMessage, action: .openSettings))),
            ChatItem(kind: .notice(Notice(style: .info, message: AgentLoop.permissionNotice(for: .automationMail),
                                          action: .openPermissionSettings))),
            ChatItem(kind: .notice(Notice(style: .warning, message: String(format: String(localized: "Orbit stopped running tools after %lld tool calls. Make your request more specific if the answer is incomplete."), 15)))),
        ]
    }

    static var reminderDates: [ChatItem] {
        let title = String(localized: "Create reminder")
        return [
            ChatItem(kind: .confirmation(ConfirmationState(request: ConfirmationRequest(
                toolName: "create_reminder", riskLevel: .write, title: title,
                message: String(localized: "Orbit creates this reminder in Reminders. A date without a time covers the whole day."),
                fields: [
                    ConfirmationField(id: "title", label: String(localized: "Titel"), value: "Take out the trash", kind: .text),
                    ConfirmationField(id: "due", label: String(localized: "Due"), value: "2026-10-05", kind: .dateTime,
                                      isOptionalDate: true),
                    ConfirmationField(id: "list", label: String(localized: "Liste"), value: "Reminders", kind: .readOnly),
                ], confirmLabel: String(localized: "Create")), status: .pending))),
            ChatItem(kind: .confirmation(ConfirmationState(request: ConfirmationRequest(
                toolName: "create_reminder", riskLevel: .write, title: title, message: "",
                fields: [
                    ConfirmationField(id: "title", label: String(localized: "Titel"), value: "Milk", kind: .text),
                    ConfirmationField(id: "due", label: String(localized: "Due"), value: "", kind: .dateTime, isOptionalDate: true),
                ], confirmLabel: String(localized: "Create")), status: .pending))),
            ChatItem(kind: .confirmation(ConfirmationState(request: ConfirmationRequest(
                toolName: "create_reminder", riskLevel: .write, title: title, message: "",
                fields: [ConfirmationField(id: "due", label: String(localized: "Due"), value: "2026-09-30T10:00", kind: .dateTime)]),
                status: .approved))),
        ]
    }

    /// Built by `open_url` itself, like the German ones.
    static var linkConfirmations: [ChatItem] {
        let tool = OpenURLTool(context: OpenAppToolTests.context())
        let links = [
            "https://xn--80ak6aa92e.com/login?d=" + String(repeating: "Dentist%20Dr.%20Example%2008:30%20", count: 6),
            "mailto:lisa@example.com?cc=max@example.com&subject=Appointments&body=Dentist",
        ]
        let refusal = Result { try LinkPolicy.checkNotTyped(try LinkPolicy.check("http://192.168.178.1/")) }
        let status: String = if case .failure(let error as ToolError) = refusal { AgentLoop.statusText(for: error) } else { "" }
        return links.map { link in
            ChatItem(kind: .confirmation(ConfirmationState(
                request: tool.confirmationRequest(for: ToolArguments(["url": .string(link)])), status: .pending)))
        } + [ChatItem(kind: .toolStatus(ToolStatus(toolCallID: "local", toolName: tool.name, category: tool.category, text: status,
                                                   state: .failed)))]
    }

    static var failedTurn: [ChatItem] {
        [
            ChatItem(kind: .user(text: "What’s on my calendar tomorrow?", attachments: [])),
            ChatItem(kind: .assistant(text: "Let me check", isStreaming: false)),
            SampleData.errorNotice(.network(.cannotConnect), .thisMac(address: "localhost:11434")),
        ]
    }

    private static func date(_ text: String) -> Date {
        FlexibleDate.parse(text)?.date ?? Date()
    }
}
