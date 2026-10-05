import AppKit
import ServiceManagement
import SwiftUI
import Testing
@testable import Orbit

/// Parent of the suites that drive real windows and the app's event handling.
/// `.serialized` applies to all of them: run concurrently, they would steal
/// focus and events from each other.
@Suite(.serialized)
enum UIWindowTests {}

extension UIWindowTests {
    /// Renders the UI offscreen to PNG files for visual review (light and dark),
    /// in German with German sample data (`GermanInterface`, de_DE formats);
    /// `UISnapshotEnglishTests` renders the main views in English.
    ///
    ///     ORBIT_UI_SNAPSHOT_DIR=/tmp/orbit-snapshots Scripts/swiftpm.sh test --filter UISnapshot
    ///
    /// Uses only sample data and an in-memory key store; nothing personal is read.
    @MainActor
    @Suite("UISnapshot", .serialized, .enabled(if: ProcessInfo.processInfo.environment["ORBIT_UI_SNAPSHOT_DIR"] != nil))
    struct UISnapshotTests {
        private var directory: URL {
            URL(fileURLWithPath: ProcessInfo.processInfo.environment["ORBIT_UI_SNAPSHOT_DIR"] ?? NSTemporaryDirectory(), isDirectory: true)
        }

        static let german = Locale(identifier: "de_DE")

        // MARK: Panel

        @Test func panelStates() async throws {
            try await GermanInterface.run(formats: Self.german) {
                for dark in [false, true] {
                    let environment = SnapshotEnvironment.make()
                    try await SnapshotRenderer.renderPanel(environment: environment, dark: dark, name: "panel-compact", in: directory)

                    environment.panelState.attachments = SampleData.attachments
                    try await SnapshotRenderer.renderPanel(environment: environment, dark: dark, name: "panel-chips", in: directory)

                    environment.panelState.attachments = []
                    environment.panelState.inputText = "Telekom Rechnung März"
                    try await SnapshotRenderer.renderPanel(environment: environment, dark: dark, name: "panel-search", in: directory)

                    environment.agentLoop.send("Finde die Telekom-Rechnung aus dem März", attachments: SampleData.attachments)
                    environment.panelState.inputText = ""
                    try await SnapshotRenderer.renderPanel(environment: environment, dark: dark, name: "panel-chat", in: directory)
                }
            }
        }

        /// After a pause the panel opens in search mode; the chat waits under
        /// the empty input ("Continue chat").
        @Test func parkedChatPanel() async throws {
            try await GermanInterface.run(formats: Self.german) {
                for dark in [false, true] {
                    let environment = SnapshotEnvironment.make()
                    environment.agentLoop.send("Finde die Telekom-Rechnung aus dem März")
                    await environment.agentLoop.waitUntilIdle()
                    let hidden = Date()
                    environment.chatParking.now = { hidden }
                    environment.chatParking.panelDidHide()
                    environment.chatParking.now = { hidden.addingTimeInterval(ChatParking.pause) }
                    environment.chatParking.panelWillAppear()
                    #expect(environment.chatParking.isParked)
                    try await SnapshotRenderer.renderPanel(environment: environment, dark: dark, name: "panel-parked-chat", in: directory)
                }
            }
        }

        /// The real instant search in the panel, on fakes: apps, files in a
        /// temporary folder (the fake home) and contacts.
        @Test func instantSearchPanel() async throws {
            try await GermanInterface.run(formats: Self.german) {
                let folder = try TemporaryFolder("snapshot-instant")
                defer { folder.remove() }
                let services = try SampleData.instantSearchServices(in: folder)
                for dark in [false, true] {
                    let environment = SnapshotEnvironment.make(services: services)
                    environment.instantSearch.search("ma")
                    environment.panelState.inputText = "ma"
                    try await SnapshotRenderer.renderPanel(environment: environment, dark: dark, name: "panel-instant-search", in: directory)
                    #expect(environment.instantSearch.groups.map(\.results.count) == [2, 3, 2])
                }
            }
        }

        @Test func searchResults() async throws {
            try await GermanInterface.run(formats: Self.german) {
                for dark in [false, true] {
                    var selection = SearchSelection(resultIDs: SampleData.searchGroups.flatMap(\.results).map(\.id))
                    selection.moveDown()
                    selection.moveDown()
                    let view = SearchView(query: "ma", groups: SampleData.searchGroups, selection: selection,
                                          maxHeight: 600, onAsk: {}, onOpen: { _ in })
                    try await SnapshotRenderer.render(view.frame(width: Theme.panelWidth), dark: dark, panelBackground: true,
                                                name: "search-results", in: directory)
                }
            }
        }

        // MARK: Chat

        @Test func chatConversation() async throws {
            try await GermanInterface.run(formats: Self.german) {
                for dark in [false, true] {
                    try await renderChat(SampleData.conversation, isRunning: true, name: "chat-conversation", dark: dark)
                    try await renderChat(SampleData.cards, isRunning: false, name: "chat-cards", dark: dark)
                    try await renderChat(SampleData.confirmations, isRunning: true, name: "chat-confirmations", dark: dark)
                    try await renderChat(SampleData.reminderDates, isRunning: true, name: "chat-reminder-dates", dark: dark)
                    try await renderChat(SampleData.linkConfirmations, isRunning: true, name: "chat-link-confirmations", dark: dark)
                    try await renderChat(SampleData.markdown, isRunning: false, name: "chat-markdown", dark: dark)
                    try await renderChat(SampleData.failedTurn, isRunning: false, name: "chat-failed", dark: dark)
                }
            }
        }

        // MARK: Mail cards

        /// Mail cards as RootView shows them: rows that open the message, a
        /// draft card with "Show in Mail", and a reply card (Mail's reply
        /// window, text on the clipboard) with "Copy Text" (fakes only;
        /// nothing is opened or copied).
        @Test func mailCards() async throws {
            try await GermanInterface.run(formats: Self.german) {
                let actions = MailCardActions(mail: MailService(runner: MockAppleScriptRunner()), opener: DisabledMessageLinkOpener(),
                                              pasteboard: RecordingPasteboard())
                let draft = MailDraftItem(to: ["Lisa Beispiel <lisa.beispiel@example.com>"], cc: ["max@example.com"],
                                          subject: "Re: Projekt Orbit: nächste Schritte",
                                          body: "Hallo Lisa,\n\nDonnerstag um 14 Uhr passt mir gut.\n\nViele Grüße\nErika",
                                          isOpenInMail: true, draftID: 7)
                let reply = MailDraftItem(to: ["Lisa Beispiel <lisa.beispiel@example.com>"], cc: [],
                                          subject: "Re: Projekt Orbit: nächste Schritte",
                                          body: "Hallo Lisa,\n\nDonnerstag um 14 Uhr passt mir gut.\n\nViele Grüße\nErika",
                                          isOpenInMail: true, draftID: 8, reply: MailReplyInfo(toAll: false, isTextOnClipboard: true))
                guard case .card(let mails) = SampleData.cards[0].kind else {
                    Issue.record("the sample cards start with mails")
                    return
                }
                for dark in [false, true] {
                    let view = VStack(spacing: 10) {
                        ResultCardView(card: mails, id: UUID())
                        ResultCardView(card: .mailDraft(draft), id: UUID())
                        ResultCardView(card: .mailDraft(reply), id: UUID())
                    }
                    .environment(actions)
                    .padding(Theme.contentInset)
                    .frame(width: Theme.panelWidth)
                    try await SnapshotRenderer.render(view, dark: dark, panelBackground: true, name: "mail-cards", in: directory)
                }
            }
        }

        /// A11Y-1: the keyboard on a reply card ("Copy Text" selected) and
        /// on a mail card (the second message selected), in the panel.
        @Test func cardsFromTheKeyboard() async throws {
            try await GermanInterface.run(formats: Self.german) {
                for dark in [false, true] {
                    try await renderCardPanel(keys: [.tab], name: "panel-reply-card-focused", dark: dark)
                    try await renderCardPanel(keys: [.tab, .backTab, .backTab, .down], name: "panel-mail-card-focused", dark: dark)
                }
            }
        }

        private func renderCardPanel(keys: [UIWindowTests.CardKeyboardTests.Key], name: String, dark: Bool) async throws {
            let harness = try await UIWindowTests.CardKeyboardTests.makeHarness()
            defer { harness.panel.orderOut(nil) }
            harness.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for key in keys {
                await UIWindowTests.CardKeyboardTests.press(harness, key)
            }
            harness.panel.setContentSize(CGSize(width: Theme.panelWidth, height: harness.environment.panelState.preferredContentHeight))
            await SnapshotRenderer.settle(0.4)
            let content = try #require(harness.panel.contentView)
            try SnapshotRenderer.write(content, dark: dark, name: name, in: directory)
        }

        // MARK: Calendar cards

        /// Event and reminder cards as RootView shows them: clickable rows, a
        /// declined, a canceled and a recurring event, an event and a reminder
        /// Orbit just created with "Show in Calendar" / "In Erinnerungen
        /// zeigen", and a selected row (fakes only; nothing opens).
        @Test func calendarCards() async throws {
            try await GermanInterface.run(formats: Self.german) {
                let actions = CalendarCardActions(opener: RecordingCalendarAppOpener())
                let events = SampleData.calendarEvents
                var created = events[1]
                created.wasCreated = true
                let reminders = SampleData.calendarReminders
                var createdReminder = reminders[0]
                createdReminder.wasCreated = true
                for dark in [false, true] {
                    let view = VStack(spacing: 10) {
                        ResultCardView(card: .events(events), id: UUID())
                        ResultCardView(card: .events([created]), id: UUID())
                        ResultCardView(card: .reminders(reminders), id: UUID())
                        ResultCardView(card: .reminders([createdReminder]), id: UUID())
                    }
                    .environment(actions)
                    .padding(Theme.contentInset)
                    .frame(width: Theme.panelWidth)
                    try await SnapshotRenderer.render(view, dark: dark, panelBackground: true, name: "calendar-cards", in: directory)
                    try await renderCalendarCardPanel(keys: [.tab, .down], name: "panel-reminder-card-focused", dark: dark)
                    try await renderCalendarCardPanel(keys: [.tab, .backTab, .down, .down], name: "panel-event-card-focused", dark: dark)
                }
            }
        }

        private func renderCalendarCardPanel(keys: [UIWindowTests.CardKeyboardTests.Key], name: String, dark: Bool) async throws {
            let harness = try await UIWindowTests.CalendarCardKeyboardTests.makeHarness()
            defer { harness.panel.orderOut(nil) }
            harness.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for key in keys {
                await UIWindowTests.CalendarCardKeyboardTests.press(harness, key)
            }
            harness.panel.setContentSize(CGSize(width: Theme.panelWidth, height: harness.environment.panelState.preferredContentHeight))
            await SnapshotRenderer.settle(0.4)
            let content = try #require(harness.panel.contentView)
            try SnapshotRenderer.write(content, dark: dark, name: name, in: directory)
        }

        // MARK: Photo cards

        #if DEBUG
        /// Photo cards as RootView shows them: a grid of invented thumbnails
        /// (drawn, never real photos) with favorites, Live Photos, videos, an
        /// iCloud-only photo, screenshots, a panorama and a selected tile; a
        /// card without thumbnails (snapshots of single views); and the keyboard
        /// on a card in the panel (fakes only; nothing opens).
        @Test func photoCards() async throws {
            try await GermanInterface.run(formats: Self.german) {
                var errors: [String] = []
                let data = FakePhotoData(folder: FakePersonalDataTests.fixtures, now: Date(), errors: &errors)
                #expect(errors.isEmpty)
                let items = data.photos.filter { !$0.isHidden }.map { SearchPhotosTool.item($0.asset) }
                let actions = PhotoCardActions(photos: PhotosService(runner: MockAppleScriptRunner()),
                                               opener: RecordingPhotosAppOpener(), thumbnails: FakePhotoThumbnails(data: data))
                for dark in [false, true] {
                    let view = VStack(spacing: 10) {
                        PhotoCardView(id: UUID(), items: items,
                                      selection: FileCardSelection(count: items.count, index: 4,
                                                                   collapsedLimit: PhotoGridLayout.collapsedLimit(columns: 7)))
                            .environment(actions)
                        PhotoCardView(id: UUID(), items: Array(items.prefix(9)))
                    }
                    .padding(Theme.contentInset)
                    .frame(width: Theme.panelWidth)
                    try await SnapshotRenderer.render(view, dark: dark, panelBackground: true, name: "photo-cards", in: directory)
                    try await renderPhotoCardPanel(keys: [.tab, .right], name: "panel-photo-card-focused", dark: dark)
                }
            }
        }

        private func renderPhotoCardPanel(keys: [UIWindowTests.CardKeyboardTests.Key], name: String, dark: Bool) async throws {
            let thumbnails = MockPhotoThumbnails()
            let all = UIWindowTests.PhotoCardKeyboardTests.older + UIWindowTests.PhotoCardKeyboardTests.latest
            for item in all {
                let size = PlaceholderPhoto.size(width: item.pixelWidth, height: item.pixelHeight,
                                                 shorterSide: PhotoGridLayout.thumbnailPixels)
                if let image = PlaceholderPhoto.image(seed: item.id, color: nil, mediaType: item.mediaType, isScreenshot: false,
                                                      width: size.width, height: size.height) {
                    thumbnails.set(.image(image), for: item.id)
                }
            }
            let harness = try await UIWindowTests.PhotoCardKeyboardTests.makeHarness(thumbnails: thumbnails)
            defer { harness.panel.orderOut(nil) }
            harness.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for key in keys {
                await UIWindowTests.PhotoCardKeyboardTests.press(harness, key)
            }
            harness.panel.setContentSize(CGSize(width: Theme.panelWidth, height: harness.environment.panelState.preferredContentHeight))
            await SnapshotRenderer.settle(0.4)
            let content = try #require(harness.panel.contentView)
            try SnapshotRenderer.write(content, dark: dark, name: name, in: directory)
        }
        #endif

        // MARK: File cards

        /// A card on its own (its only focusable view has the keyboard: accent
        /// selection), expanded, and in the panel: after Tab and ↓ (accent), and
        /// after Tab back to the input (gray).
        @Test func fileCards() async throws {
            try await GermanInterface.run(formats: Self.german) {
                let items = SampleData.fileCardItems
                for dark in [false, true] {
                    let collapsed = FileCardView(id: UUID(), items: items, selection: FileCardSelection(count: items.count, index: 1))
                        .padding(Theme.contentInset)
                        .frame(width: Theme.panelWidth)
                    try await SnapshotRenderer.render(collapsed, dark: dark, panelBackground: true, name: "file-card-selected", in: directory)
                    let expanded = FileCardView(id: UUID(), items: items, selection: FileCardSelection(count: items.count, index: 6))
                        .padding(Theme.contentInset)
                        .frame(width: Theme.panelWidth)
                    try await SnapshotRenderer.render(expanded, dark: dark, panelBackground: true, name: "file-card-expanded", in: directory)

                    try await renderFileCardPanel(keys: [.tab, .down], name: "panel-file-card-focused", dark: dark)
                    try await renderFileCardPanel(keys: [.tab, .down, .tab], name: "panel-file-card-unfocused", dark: dark)
                }
            }
        }

        private func renderFileCardPanel(keys: [UIWindowTests.FileCardKeyboardTests.Key], name: String, dark: Bool) async throws {
            let harness = try await UIWindowTests.FileCardKeyboardTests.makeHarness()
            defer { harness.panel.orderOut(nil) }
            harness.panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for key in keys {
                await UIWindowTests.FileCardKeyboardTests.press(harness, key)
            }
            harness.panel.setContentSize(CGSize(width: Theme.panelWidth, height: harness.environment.panelState.preferredContentHeight))
            await SnapshotRenderer.settle(0.4)
            let content = try #require(harness.panel.contentView)
            try SnapshotRenderer.write(content, dark: dark, name: name, in: directory)
        }

        /// D2: what a failed request ends with: each notice with the buttons it
        /// offers as the latest one, and "Sign In…" while the sign-in runs.
        @Test func errorNotices() async throws {
            try await GermanInterface.run(formats: Self.german) {
                for dark in [false, true] {
                    try await SnapshotRenderer.render(SnapshotRenderer.noticeSheet(SampleData.errorNotices), dark: dark,
                                                      panelBackground: true, name: "chat-error-notices", in: directory)
                }
            }
        }

        /// D3: Increase Contrast (clear edges around cards, chips, bubbles, notices and the selected
        /// row) and Differentiate Without Color (the keyboard's row outlined, "Overdue" in words,
        /// the current onboarding step wider), set for the views, as macOS would.
        @Test func accessibilityDisplayOptions() async throws {
            try await GermanInterface.run(formats: Self.german) {
                for dark in [false, true] {
                    for (name, items) in [("conversation", SampleData.conversation), ("cards", SampleData.cards)] {
                        let chat = ChatView(items: items, isRunning: false, conversationID: UUID(), maxHeight: 4_000, actions: ChatActions())
                            .frame(width: Theme.panelWidth)
                            .environment(\._colorSchemeContrast, .increased)
                            .environment(\._accessibilityDifferentiateWithoutColor, true)
                        try await SnapshotRenderer.render(chat, dark: dark, panelBackground: true, name: "a11y-contrast-\(name)", in: directory)
                    }
                    var selection = FileCardSelection(count: SampleData.fileCardItems.count)
                    selection.select(1)
                    let extras = VStack(alignment: .leading, spacing: 14) {
                        FileCardView(id: UUID(), items: SampleData.fileCardItems, selection: selection)
                        OnboardingStepIndicator(count: 7, current: 2)
                        ContextChips(attachments: SampleData.attachments, onRemove: { _ in })
                    }
                    .padding(Theme.contentInset)
                    .frame(width: Theme.panelWidth)
                    .environment(\._colorSchemeContrast, .increased)
                    .environment(\._accessibilityDifferentiateWithoutColor, true)
                    try await SnapshotRenderer.render(extras, dark: dark, panelBackground: true, name: "a11y-contrast-extras", in: directory)
                }
            }
        }

        private func renderChat(_ items: [ChatItem], isRunning: Bool, name: String, dark: Bool) async throws {
            let view = ChatView(items: items, isRunning: isRunning, conversationID: UUID(), maxHeight: 4_000, actions: ChatActions())
                .frame(width: Theme.panelWidth)
            try await SnapshotRenderer.render(view, dark: dark, panelBackground: true, name: name, in: directory)
        }

        // MARK: Settings

        @Test func settings() async throws {
            try await GermanInterface.run(formats: Self.german) {
                for dark in [false, true] {
                    let environment = SnapshotEnvironment.make()
                    try await SnapshotRenderer.render(SettingsView(environment: environment), dark: dark, panelBackground: false,
                                                name: "settings-window", in: directory)
                    for tab in SettingsTab.allCases {
                        let content = SettingsTabContent(tab: tab, environment: environment).frame(width: 620, height: 440)
                        try await SnapshotRenderer.render(content, dark: dark, panelBackground: false,
                                                    name: "settings-\(tab.rawValue)", in: directory)
                    }
                    let tools = ToolsSettingsView(settings: environment.settings, tools: SampleData.tools).frame(width: 620, height: 440)
                    try await SnapshotRenderer.render(tools, dark: dark, panelBackground: false, name: "settings-tools-filled", in: directory)
                    // UX-2: "Open Settings" of a permission notice opens Settings on Permissions.
                    let navigation = SettingsNavigation()
                    navigation.tab = .permissions
                    try await SnapshotRenderer.render(SettingsView(environment: environment, navigation: navigation), dark: dark,
                                                      panelBackground: false, name: "settings-window-permissions", in: directory)
                }
            }
        }

        /// D6: "Open at login" while macOS waits for the user's
        /// approval ("Open Login Items…"), and after a failure (a fake
        /// login item: nothing is registered).
        @Test func launchAtLoginStates() async throws {
            try await GermanInterface.run(formats: Self.german) {
                for dark in [false, true] {
                    let approval = LaunchAtLoginModel(service: FakeLoginItem(status: .requiresApproval))
                    await approval.refresh()
                    let failed = LaunchAtLoginModel(service: FakeLoginItem(status: .notRegistered, failure: kSMErrorJobNotFound))
                    await failed.setEnabled(true)
                    for (name, model) in [("approval", approval), ("error", failed)] {
                        let view = GeneralSettingsView(settings: SettingsStore(defaults: AgentTestDefaults()), launchAtLogin: model)
                            .frame(width: 620, height: 700)
                        try await SnapshotRenderer.render(view, dark: dark, panelBackground: false,
                                                          name: "settings-general-login-\(name)", in: directory)
                    }
                }
            }
        }

        @Test func claudeCodeSettings() async throws {
            try await GermanInterface.run(formats: Self.german) {
                let home = NSHomeDirectory()
                let appCopy = "\(home)/Library/Application Support/Claude/claude-code/2.1.284/claude.app/Contents/MacOS/claude"
                let states: [(String, ClaudeCodeStatus, RateLimitInfo?)] = [
                    ("ready", ClaudeCodeStatus(availability: .ready, executablePath: appCopy, version: "2.1.284",
                                               subscriptionType: "max", authMethod: "claude.ai"),
                     RateLimitInfo(status: "allowed_warning", utilization: 0.26, resetsAt: Date().addingTimeInterval(3 * 86_400),
                                   window: "seven_day", isUsingOverage: false)),
                    ("not-logged-in", ClaudeCodeStatus(availability: .notLoggedIn, executablePath: "\(home)/.local/bin/claude",
                                                       version: "2.1.251"), nil),
                    ("not-installed", ClaudeCodeStatus(availability: .notInstalled), nil),
                ]
                for dark in [false, true] {
                    for (name, status, usage) in states {
                        let settings = SettingsStore(defaults: AgentTestDefaults())
                        settings.providerKind = .claudeCode
                        let account = ClaudeCodeAccountModel(loadStatus: { status }, signIn: {})
                        let view = ModelSettingsView(settings: settings, secrets: InMemorySecretStore(),
                                                     validate: { _, _ in }, claudeCodeAccount: account, usage: { usage })
                        try await SnapshotRenderer.render(view.frame(width: 620, height: 520), dark: dark, panelBackground: false,
                                                          name: "settings-claude-code-\(name)", in: directory)
                    }
                }
            }
        }

        // MARK: Permissions and onboarding

        /// Settings → Permissions with every status (fakes only; nothing is read or asked).
        @Test func permissionsSettings() async throws {
            try await GermanInterface.run(formats: Self.german) {
                for dark in [false, true] {
                    let access = MockPermissionAccess([.automationMail: .granted, .automationNotes: .denied,
                                                       .contacts: .notDetermined, .calendars: .writeOnly, .reminders: .granted,
                                                       .fullDiskAccess: .unknown])
                    let manager = PermissionManager(access: access, permissions: [.automationMail, .automationNotes, .contacts,
                                                                                  .calendars, .reminders, .fullDiskAccess])
                    await manager.refresh()
                    let view = PermissionsSettingsView(manager: manager, mailSearch: MockMailSpotlight(available: false),
                                                       relaunch: {})
                        .frame(width: 620, height: 1_000)
                    try await SnapshotRenderer.render(view, dark: dark, panelBackground: false, name: "settings-permissions-states",
                                                      in: directory)
                    #expect(access.requests.isEmpty && access.openedSettings.isEmpty)

                    // Settings → Tools marks the tools whose permission is missing.
                    let settings = SettingsStore(defaults: AgentTestDefaults())
                    let tools = ToolsSettingsView(settings: settings, tools: ToolRegistry(tools: AppEnvironment.makeTools(services: .fake())).infos,
                                                  permissionStatuses: manager.statuses)
                        .frame(width: 620, height: 1_400)
                    try await SnapshotRenderer.render(tools, dark: dark, panelBackground: false, name: "settings-tools-permissions",
                                                      in: directory)
                }
            }
        }

        /// Every onboarding step, as the window shows it (fakes only).
        @Test func onboardingSteps() async throws {
            try await GermanInterface.run(formats: Self.german) {
                let home = NSHomeDirectory()
                let ready = ClaudeCodeStatus(availability: .ready,
                                             executablePath: "\(home)/Library/Application Support/Claude/claude-code/2.1.284/claude.app/Contents/MacOS/claude",
                                             version: "2.1.284", subscriptionType: "max", authMethod: "claude.ai")
                let newSteps = OnboardingModel.Mode.newPermissions([.calendars, .reminders])
                let variants: [(name: String, step: OnboardingModel.Step, provider: ProviderKind, mode: OnboardingModel.Mode)] = [
                    ("welcome", .welcome, .claudeCode, .full),
                    ("provider-claude", .provider, .claudeCode, .full),
                    ("provider-api", .provider, .anthropic, .full),
                    ("provider-openai", .provider, .openAICompatible, .full),
                    ("hotkey", .hotkey, .claudeCode, .full),
                    ("mail", .permission(.automationMail), .claudeCode, .full),
                    ("notes", .permission(.automationNotes), .claudeCode, .full),
                    ("contacts", .permission(.contacts), .claudeCode, .full),
                    ("calendars-add-only", .permission(.calendars), .claudeCode, .full),
                    ("reminders", .permission(.reminders), .claudeCode, .full),
                    ("done", .done, .claudeCode, .full),
                    // What an existing user sees once after the update: only the new steps.
                    ("new-calendars", .permission(.calendars), .claudeCode, newSteps),
                    ("new-done", .done, .claudeCode, newSteps),
                ]
                for dark in [false, true] {
                    for variant in variants {
                        let access = MockPermissionAccess([.automationMail: .notDetermined, .automationNotes: .denied,
                                                           .contacts: .granted, .calendars: .writeOnly, .reminders: .notDetermined,
                                                           .fullDiskAccess: .unknown])
                        let manager = PermissionManager(access: access, permissions: [.automationMail, .automationNotes, .contacts,
                                                                                      .calendars, .reminders, .fullDiskAccess])
                        await manager.refresh()
                        let settings = SettingsStore(defaults: AgentTestDefaults())
                        settings.providerKind = variant.provider
                        let model = OnboardingModel(settings: settings, permissions: manager, secrets: InMemorySecretStore(),
                                                    validate: { _, _ in },
                                                    claudeCodeAccount: ClaudeCodeAccountModel(loadStatus: { ready }, signIn: {}),
                                                    mode: variant.mode, onFinish: {})
                        model.go(to: variant.step)
                        if variant.provider == .anthropic {
                            await model.keyEditor.load(kind: .anthropic)
                            model.keyEditor.draft = "sk-ant-snapshot"
                        }
                        try await SnapshotRenderer.render(OnboardingView(model: model), dark: dark, panelBackground: false,
                                                          name: "onboarding-\(variant.name)", in: directory)
                        #expect(access.requests.isEmpty && access.openedSettings.isEmpty)
                    }
                }
                // The context steps after the update (UX-2, UX-6): their own note and skip help; Accessibility, never
                // asked for, looks "not asked yet" rather than refused.
                let contextSteps: [(name: String, step: OnboardingModel.Step)] = [
                    ("new-finder", .permission(.automationFinder)), ("new-accessibility", .permission(.accessibility)),
                    ("new-context-done", .done),
                ]
                for dark in [false, true] {
                    for variant in contextSteps {
                        let access = MockPermissionAccess([.automationFinder: .notDetermined, .accessibility: .denied])
                        let manager = PermissionManager(access: access, permissions: [.automationFinder, .accessibility])
                        await manager.refresh()
                        let model = OnboardingModel(settings: SettingsStore(defaults: AgentTestDefaults()), permissions: manager,
                                                    secrets: InMemorySecretStore(), validate: { _, _ in },
                                                    claudeCodeAccount: ClaudeCodeAccountModel(loadStatus: { nil }, signIn: {}),
                                                    mode: .newPermissions([.automationFinder, .accessibility]), onFinish: {})
                        model.go(to: variant.step)
                        try await SnapshotRenderer.render(OnboardingView(model: model), dark: dark, panelBackground: false,
                                                          name: "onboarding-\(variant.name)", in: directory)
                        #expect(access.requests.isEmpty && access.openedSettings.isEmpty)
                    }
                }
            }
        }

        /// The app's environment reads permissions through the manager (on fakes),
        /// and closing the onboarding counts as seen.
        @Test func environmentWiring() async {
            let environment = SnapshotEnvironment.make()
            // Every tool's permission (System Events for set_appearance), and Finder and Accessibility while the
            // context features are on (as by default).
            #expect(environment.permissions.permissions == [.automationMail, .automationNotes, .contacts, .calendars, .reminders,
                                                            .photos, .automationPhotos, .automationFinder,
                                                            .automationSystemEvents, .accessibility, .fullDiskAccess])
            #expect(environment.agentLoop.dependencies.permissions as? PermissionManager === environment.permissions)
            // D2: VoiceOver hears the chat's notices through the app's announcer.
            #expect(environment.agentLoop.dependencies.announcer as? RecordingAnnouncer === environment.services.announcer as? RecordingAnnouncer)
            #expect(environment.agentLoop.dependencies.announcer != nil)
            // The sign-in that quitting ends (applicationWillTerminate) is the one the chat's notice, Settings and
            // the onboarding start.
            #expect(environment.agentLoop.dependencies.claudeCodeAccount as? ClaudeCodeAccountService === environment.claudeCodeAccount)
            // A11Y-1, FC5-4: a waiting card's announcement names ⌘↩ and ⌘. only while the panel is shown with the
            // keyboard (more in AppEnvironmentTests).
            environment.panelState.isVisible = false
            #expect(!environment.agentLoop.dependencies.panelHasKeyboard())
            environment.panelState.isVisible = true
            #expect(environment.agentLoop.dependencies.panelHasKeyboard())
            environment.panelState.keyboardHandoff.begin(to: "com.apple.mail", now: Date())
            #expect(!environment.agentLoop.dependencies.panelHasKeyboard(), "Mail's reply window takes the keyboard")
            environment.panelState.keyboardHandoff.reset()
            environment.panelState.isVisible = false
            // ⌘N in a chat without a request to keep starts an empty chat.
            environment.panelState.inputText = "Entwurf"
            environment.startNewChat()
            #expect(environment.panelState.inputText.isEmpty)
            let controller = OnboardingWindowController(environment: environment, hidePanel: {})
            #expect(!controller.isVisible)
            environment.settings.hasCompletedOnboarding = false
            controller.didClose()
            #expect(environment.settings.hasCompletedOnboarding)
            #expect(controller.window == nil && controller.model == nil)

            // Closing an onboarding counts its permission steps as seen, only those.
            environment.settings.presentedOnboardingPermissions = [.automationMail, .automationNotes, .contacts]
            _ = controller.prepareWindow(mode: .newPermissions([.calendars, .reminders]))
            #expect(controller.model?.steps == [.permission(.calendars), .permission(.reminders), .done])
            controller.didClose()
            #expect(environment.settings.presentedOnboardingPermissions
                == [.automationMail, .automationNotes, .contacts, .calendars, .reminders])
        }
    }
}

// MARK: - Rendering

@MainActor
enum SnapshotRenderer {
    /// Hosts RootView like the panel controller does: width 720, height from
    /// `preferredContentHeight`.
    static func renderPanel(environment: AppEnvironment, dark: Bool, name: String, in directory: URL) async throws {
        let hosting = NSHostingView(rootView: RootView(environment: environment).background(panelBackground))
        let window = makeWindow(size: CGSize(width: Theme.panelWidth, height: 900), dark: dark, content: hosting)
        await settle(0.6)
        let height = environment.panelState.preferredContentHeight
        window.setContentSize(CGSize(width: Theme.panelWidth, height: height))
        await settle(0.2)
        try write(hosting, dark: dark, name: name, in: directory)
        window.orderOut(nil)
    }

    /// Notices as the chat shows the latest one (its buttons offered), and
    /// the first one again while its sign-in runs.
    static func noticeSheet(_ items: [ChatItem]) -> some View {
        let notices = items.compactMap { item -> Notice? in
            if case .notice(let notice) = item.kind { return notice }
            return nil
        }
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(notices.enumerated()), id: \.offset) { _, notice in
                NoticeRow(notice: notice, isActionAvailable: true, onAction: { _ in })
            }
            if let first = notices.first {
                NoticeRow(notice: first, isActionAvailable: true, isSigningIn: true, onAction: { _ in })
            }
        }
        .padding(Theme.contentInset)
        .frame(width: Theme.panelWidth)
    }

    static func render<V: View>(_ view: V, dark: Bool, panelBackground: Bool, name: String, in directory: URL) async throws {
        let root = view.background(panelBackground ? AnyView(Self.panelBackground) : AnyView(Color(nsColor: .windowBackgroundColor)))
        let hosting = NSHostingView(rootView: root)
        let window = makeWindow(size: CGSize(width: 800, height: 800), dark: dark, content: hosting)
        await settle(0.6)
        window.setContentSize(hosting.fittingSize)
        await settle(0.3)
        window.setContentSize(hosting.fittingSize)
        await settle(0.1)
        try write(hosting, dark: dark, name: name, in: directory)
        window.orderOut(nil)
    }

    private static var panelBackground: some View {
        Color(nsColor: .windowBackgroundColor)
    }

    private static func makeWindow(size: CGSize, dark: Bool, content: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = content
        window.orderFront(nil)
        return window
    }

    /// Lets SwiftUI and main-actor tasks (`.task`, icon loading) run: the
    /// test job suspends so the main actor is free, and the run loop turns.
    static func settle(_ seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(15))
            turnRunLoop()
        }
    }

    /// Synchronous on purpose: run loop APIs are unavailable in async functions.
    private static func turnRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }

    static func write(_ view: NSView, dark: Bool, name: String, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Issue.record("no bitmap for \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}

@MainActor
enum SnapshotEnvironment {
    /// An environment that never touches the user's keychain, settings, files
    /// or the network: requests go to a closed local port and fail immediately,
    /// and Spotlight, the app index, contacts, opening and Quick Look are fakes
    /// (`AppServices.fake()` unless the test passes other fakes).
    static func make(services: AppServices = .fake()) -> AppEnvironment {
        setenv("ORBIT_DEBUG_API_KEY", "sk-snapshot", 1)
        setenv("ORBIT_DEBUG_PROVIDER", "anthropic", 1)
        setenv("ORBIT_DEBUG_BASE_URL", "http://127.0.0.1:9", 1)
        setenv("ORBIT_DATA_DIR", NSTemporaryDirectory() + "orbit-snapshots-data", 1)
        return AppEnvironment(services: services)
    }
}

// MARK: - Sample data

enum SampleData {
    static let attachments = [
        ContextAttachment(kind: .finderSelection(paths: ["/Users/lisa/Documents/Angebot.pdf"]), label: "Mit Auswahl: Angebot.pdf"),
        ContextAttachment(kind: .selectedText(text: "Lieferung bis Freitag", appName: "Mail"), label: "Markierter Text aus Mail"),
    ]

    static let searchGroups = [
        SearchResultGroup(category: .apps, results: [
            SearchResult(id: "mail", kind: .app(url: URL(fileURLWithPath: "/System/Applications/Mail.app")), title: "Mail", subtitle: "Programm"),
            SearchResult(id: "maps", kind: .app(url: URL(fileURLWithPath: "/System/Applications/Maps.app")), title: "Karten", subtitle: "Programm"),
        ]),
        SearchResultGroup(category: .files, results: [
            SearchResult(id: "f1", kind: .file(url: URL(fileURLWithPath: "/Users/lisa/Documents/Mahnung.pdf")), title: "Mahnung.pdf", subtitle: "~/Documents"),
            SearchResult(id: "f2", kind: .file(url: URL(fileURLWithPath: "/Users/lisa/Desktop/Marketing Plan.key")), title: "Marketing Plan.key", subtitle: "~/Desktop"),
        ]),
        SearchResultGroup(category: .contacts, results: [
            SearchResult(id: "c1", kind: .contact(identifier: "1"), title: "Marie Schneider", subtitle: "marie@example.com"),
        ]),
    ]

    /// Fakes for the instant-search snapshot: two system apps (for their
    /// icons), three sample files created in `folder` and two contacts.
    static func instantSearchServices(in folder: TemporaryFolder, opener: MockSearchOpener = MockSearchOpener(),
                                      workspace: MockWorkspace = MockWorkspace(),
                                      announcer: RecordingAnnouncer = RecordingAnnouncer()) throws -> AppServices {
        let now = Date()
        let files: [(String, Date, Bool)] = [
            ("Documents/Rechnungen/Mahnung März.pdf", now.addingTimeInterval(-2 * 86_400), false),
            ("Desktop/Marketing-Plan.pdf", now.addingTimeInterval(-9 * 86_400), false),
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
        let spotlight = MockSpotlight { _ in SpotlightResults(items: found, totalCount: found.count, isComplete: true) }
        let home = folder.path
        return AppServices(
            spotlight: spotlight, workspace: workspace,
            fileScope: FileSearchScope.restricted(to: home, homeDirectory: home),
            fileAccess: FileAccessPolicy(homeDirectory: home, orbitDataDirectory: home + "/Library/Application Support/Orbit",
                                         restriction: home),
            appIndex: FakeAppIndex([
                IndexedApp(path: "/System/Applications/Mail.app", name: "Mail"),
                IndexedApp(path: "/System/Applications/Maps.app", name: "Karten", aliases: ["Maps"]),
                IndexedApp(path: "/System/Applications/Calendar.app", name: "Kalender", aliases: ["Calendar"]),
            ]),
            contacts: MockContactSearch([
                ContactHit(identifier: "c1", name: "Marie Schneider", detail: "marie@example.com"),
                ContactHit(identifier: "c2", name: "Martin Maier", detail: "Orbit GmbH"),
            ]),
            searchOpener: opener, launchCounts: InMemoryLaunchCounts(), quickLookPanel: FakeQuickLookPanel(),
            announcer: announcer
        )
    }

    /// Seven files of different kinds (they do not exist: icons come from their types).
    static let fileCardItems: [FileItem] = {
        let now = Date()
        let files: [(String, String?, TimeInterval, Int64?, Bool)] = [
            ("Documents/Rechnungen/Rechnung-Telekom-2026-08.pdf", "com.adobe.pdf", -2 * 3_600, 184_320, false),
            ("Documents/Angebot Küche.docx", "org.openxmlformats.wordprocessingml.document", -26 * 3_600, 48_900, false),
            ("Desktop/Quartalsbericht Q3.key", "com.apple.keynote.key", -9 * 86_400, 12_400_000, false),
            ("Pictures/Screenshots/Bildschirmfoto 2026-09-12 um 10.14.png", "public.png", -18 * 86_400, 2_310_000, false),
            ("Documents/Rechnungen", nil, -40 * 86_400, nil, true),
            ("Documents/Notizen/Umzug.md", "net.daringfireball.markdown", -95 * 86_400, 3_200, false),
            ("Downloads/Belege-2025.zip", "public.zip-archive", -400 * 86_400, 58_700_000, false),
        ]
        return files.map { path, type, age, size, isFolder in
            FileItem(path: "/Users/lisa/" + path, name: (path as NSString).lastPathComponent, contentType: type,
                     modified: now.addingTimeInterval(age), size: size, isDirectory: isFolder)
        }
    }()

    /// Events of a Monday: a recurring meeting, a declined lunch, a canceled
    /// appointment, an all-day birthday and a trip over several days.
    static let calendarEvents: [EventItem] = [
        EventItem(id: "e1|1", title: "Geburtstag Lisa", start: date("2026-10-05"), end: date("2026-10-06"), isAllDay: true,
                  calendarName: "Familie", calendarColor: "#34C759", eventIdentifier: "e1"),
        EventItem(id: "e2|1", title: "Zahnarzt", start: date("2026-10-05T08:30"), end: date("2026-10-05T09:15"), isAllDay: false,
                  location: "Praxis Dr. Beispiel, Musterstraße 1", calendarName: "Privat", calendarColor: "#1BADF8",
                  eventIdentifier: "e2"),
        EventItem(id: "e3|1", title: "Team-Meeting", start: date("2026-10-05T10:00"), end: date("2026-10-05T10:45"), isAllDay: false,
                  location: "Raum 3.14", calendarName: "Arbeit", calendarColor: "#FF9500", eventIdentifier: "e3", isRecurring: true),
        EventItem(id: "e4|1", title: "Mittagessen mit Max", start: date("2026-10-05T12:30"), end: date("2026-10-05T13:30"),
                  isAllDay: false, calendarName: "Arbeit", calendarColor: "#FF9500", eventIdentifier: "e4", isDeclined: true),
        EventItem(id: "e5|1", title: "Kundentermin", start: date("2026-10-05T15:00"), end: date("2026-10-05T16:00"), isAllDay: false,
                  calendarName: "Arbeit", calendarColor: "#FF9500", eventIdentifier: "e5", isCanceled: true),
        EventItem(id: "e6|1", title: "Herbstferien", start: date("2026-10-04"), end: date("2026-10-09"), isAllDay: true,
                  calendarName: "Familie", calendarColor: "#34C759", eventIdentifier: "e6"),
    ]

    static let calendarReminders: [ReminderItem] = [
        ReminderItem(id: "r1", title: "Lisa anrufen", due: date("2026-10-05T09:00"), dueHasTime: true, isCompleted: false,
                     listName: "Erinnerungen", listColor: "#1BADF8", notes: nil),
        ReminderItem(id: "r2", title: "Rechnung Telekom bezahlen", due: date("2026-03-26"), dueHasTime: false, isCompleted: false,
                     listName: "Erinnerungen", listColor: "#1BADF8", notes: nil),
        ReminderItem(id: "r3", title: "Brot", due: nil, dueHasTime: false, isCompleted: false, listName: "Einkauf",
                     listColor: "#FF9500", notes: nil),
        ReminderItem(id: "r4", title: "Paket abholen", due: date("2026-10-03"), dueHasTime: false, isCompleted: true,
                     listName: "Erinnerungen", listColor: "#1BADF8", notes: nil, completionDate: date("2026-10-03T17:30")),
    ]

    static let tools = [
        ToolInfo(name: "search_files", description: "", category: .files, riskLevel: .read, requiredPermissions: []),
        ToolInfo(name: "open_file", description: "", category: .files, riskLevel: .draft, requiredPermissions: []),
        ToolInfo(name: "search_mail", description: "", category: .mail, riskLevel: .read, requiredPermissions: []),
        ToolInfo(name: "create_event", description: "", category: .calendar, riskLevel: .write, requiredPermissions: []),
        ToolInfo(name: "move_to_trash", description: "", category: .files, riskLevel: .destructive, requiredPermissions: []),
    ]

    private static func date(_ text: String) -> Date {
        FlexibleDate.parse(text)?.date ?? Date()
    }

    static let answer = """
    Ich habe **3 Rechnungen** von der Telekom aus dem März gefunden. Die aktuellste ist `Telekom_2026-03.pdf` vom 12. März.

    - Rechnungsbetrag: **39,95 €**
    - Fällig am 26. März
      - per Lastschrift
    - Kundennummer siehe [Kundencenter](https://www.telekom.de)
    """

    static let conversation: [ChatItem] = [
        ChatItem(kind: .user(text: "Finde die Telekom-Rechnung aus dem März", attachments: [attachments[0]])),
        ChatItem(kind: .toolStatus(ToolStatus(toolCallID: "1", toolName: "search_files", category: .files, text: "3 Dateien gefunden", state: .succeeded))),
        ChatItem(kind: .progress(text: "Ich prüfe noch, ob es dazu eine Mail gibt.")),
        ChatItem(kind: .toolStatus(ToolStatus(toolCallID: "2", toolName: "search_mail", category: .mail, text: "Keine Nachrichten gefunden", state: .failed))),
        ChatItem(kind: .toolStatus(ToolStatus(toolCallID: "3", toolName: "read_file", category: .files, text: "Lese Telekom_2026-03.pdf …", state: .cancelled))),
        ChatItem(kind: .card(.files([
            FileItem(path: "/Users/lisa/Documents/Rechnungen/Telekom_2026-03.pdf", name: "Telekom_2026-03.pdf", contentType: "com.adobe.pdf", modified: date("2026-03-12T09:14")),
            FileItem(path: "/Users/lisa/Downloads/Telekom Rechnung März.pdf", name: "Telekom Rechnung März.pdf", contentType: "com.adobe.pdf", modified: date("2026-03-11T18:02")),
            FileItem(path: "/Users/lisa/Documents/Rechnungen", name: "Rechnungen", modified: date("2025-11-02T10:00"), isDirectory: true),
        ]))),
        ChatItem(kind: .assistant(text: answer, isStreaming: false)),
        ChatItem(kind: .disclosure(items: [ContentDisclosure(kind: .fileNames, count: 3), ContentDisclosure(kind: .fileContents, count: 1)], providerName: "Claude")),
        ChatItem(kind: .user(text: "Und wann war die im Februar fällig?", attachments: [])),
        ChatItem(kind: .assistant(text: "Die Februar-Rechnung war am", isStreaming: true)),
    ]

    static let cards: [ChatItem] = [
        ChatItem(kind: .card(.mails([
            MailItem(id: "1", messageID: "abc@example.com", sender: "Lisa Müller", subject: "Projekt Orbit: nächste Schritte",
                     date: date("2026-09-27T16:40"), preview: "Hi! Anbei die Notizen vom Termin. Können wir Donnerstag um 14 Uhr sprechen?", isRead: false),
            MailItem(id: "2", messageID: nil, sender: "Telekom", subject: "Ihre Rechnung für März 2026", date: date("2026-03-12T07:00"),
                     preview: "Guten Tag, Ihre aktuelle Rechnung steht bereit.", isRead: true),
        ]))),
        ChatItem(kind: .card(.events([
            EventItem(id: "e1", title: "Zahnarzt", start: date("2026-09-29T14:00"), end: date("2026-09-29T15:00"), isAllDay: false,
                      location: "Praxis Dr. Weber, Hauptstraße 5", calendarName: "Privat", calendarColor: "#FF3B30"),
            EventItem(id: "e2", title: "Urlaub", start: date("2026-10-05"), end: date("2026-10-10"), isAllDay: true,
                      calendarName: "Familie", calendarColor: "#34C759"),
        ]))),
        ChatItem(kind: .card(.reminders([
            ReminderItem(id: "r1", title: "Rechnung bezahlen", due: date("2026-03-26"), dueHasTime: false, isCompleted: false, listName: "Erledigungen", listColor: "#FF9500"),
            ReminderItem(id: "r2", title: "Angebot schicken", due: date("2026-09-30T10:00"), dueHasTime: true, isCompleted: true, listName: "Arbeit", listColor: "#007AFF"),
        ]))),
        ChatItem(kind: .card(.contacts([
            ContactItem(id: "p1", name: "Lisa Müller", organization: "Orbit GmbH", emails: ["lisa@example.com"], phones: ["+49 30 1234567"]),
        ]))),
        ChatItem(kind: .card(.notes([
            NoteItem(id: "n1", title: "Umzug", excerpt: "Kartons bestellen, Strom ummelden, Nachsendeauftrag stellen …", folder: "Privat", modified: date("2026-09-20T11:00")),
        ]))),
        ChatItem(kind: .card(.photos((0..<9).map { index in
            PhotoItem(id: "ph\(index)", creationDate: date("2025-07-1\(index % 9)T12:00"), mediaType: index == 2 ? .video : (index == 5 ? .livePhoto : .image),
                      isFavorite: index == 1, duration: index == 2 ? 42 : nil)
        }))),
        ChatItem(kind: .card(.mailDraft(MailDraftItem(to: ["lisa@example.com"], cc: [], subject: "Re: Projekt Orbit",
                                                      body: "Hallo Lisa,\n\nDonnerstag um 14 Uhr passt mir gut.\n\nViele Grüße", isOpenInMail: true)))),
        ChatItem(kind: .card(.info(InfoItem(title: "Dunkelmodus aktiviert", detail: "Das Erscheinungsbild ist jetzt dunkel.", systemImage: "moon.fill")))),
    ]

    static let confirmations: [ChatItem] = [
        ChatItem(kind: .confirmation(ConfirmationState(request: ConfirmationRequest(
            toolName: "create_event", riskLevel: .write, title: "Create event",
            message: "Orbit legt diesen Termin in deinem Kalender „Privat“ an.",
            fields: [
                ConfirmationField(id: "title", label: "Titel", value: "Zahnarzt", kind: .text),
                ConfirmationField(id: "start", label: "Start", value: "2026-09-29T14:00", kind: .dateTime),
                ConfirmationField(id: "notes", label: "Notizen", value: "Versichertenkarte mitnehmen", kind: .multilineText),
                ConfirmationField(id: "calendar", label: "Kalender", value: "Privat", kind: .readOnly),
            ], confirmLabel: "Create event"), status: .pending))),
        ChatItem(kind: .confirmation(ConfirmationState(request: ConfirmationRequest(
            toolName: "move_to_trash", riskLevel: .destructive, title: "In den Papierkorb legen",
            message: "2 Dateien werden in den Papierkorb gelegt.",
            fields: [ConfirmationField(id: "paths", label: "Dateien", value: "Entwurf alt.pages, Kopie von Angebot.pdf", kind: .readOnly)],
            warning: nil), status: .pending))),
        ChatItem(kind: .confirmation(ConfirmationState(request: ConfirmationRequest(
            toolName: "create_reminder", riskLevel: .write, title: "Create reminder", message: "",
            fields: [ConfirmationField(id: "due", label: "Due", value: "2026-09-30", kind: .dateTime)]), status: .approved))),
        ChatItem(kind: .confirmation(ConfirmationState(request: ConfirmationRequest(
            toolName: "set_appearance", riskLevel: .write, title: "Dunkelmodus einschalten", message: ""), status: .expired))),
        ChatItem(kind: .notice(Notice(style: .error, message: "The service is overloaded right now. Please try again in a moment.", action: .retry))),
        ChatItem(kind: .notice(Notice(style: .warning, message: "No API key is set. Enter it in Settings.", action: .openSettings))),
        ChatItem(kind: .notice(Notice(style: .info, message: "Orbit is not allowed to control Mail.", action: .openPermissionSettings))),
        ChatItem(kind: .notice(Notice(style: .info, message: "Nach 15 Werkzeugaufrufen hat Orbit angehalten."))),
    ]

    /// UX-4: a reminder's due date on its card: a day ("With time", "No Date"), none yet ("Add
    /// Date"), and a decided card without one ("No Date").
    static let reminderDates: [ChatItem] = [
        ChatItem(kind: .confirmation(ConfirmationState(request: ConfirmationRequest(
            toolName: "create_reminder", riskLevel: .write, title: "Create reminder",
            message: "Orbit creates this reminder in Reminders. A date without a time covers the whole day.",
            fields: [
                ConfirmationField(id: "title", label: "Titel", value: "Müll rausbringen", kind: .text),
                ConfirmationField(id: "due", label: "Due", value: "2026-10-05", kind: .dateTime, isOptionalDate: true),
                ConfirmationField(id: "list", label: "Liste", value: "Erinnerungen", kind: .readOnly),
            ], confirmLabel: "Create"), status: .pending))),
        ChatItem(kind: .confirmation(ConfirmationState(request: ConfirmationRequest(
            toolName: "create_reminder", riskLevel: .write, title: "Create reminder", message: "",
            fields: [
                ConfirmationField(id: "title", label: "Titel", value: "Milch", kind: .text),
                ConfirmationField(id: "due", label: "Due", value: "", kind: .dateTime, isOptionalDate: true),
                ConfirmationField(id: "list", label: "Liste", value: "Einkauf", kind: .readOnly),
            ], confirmLabel: "Create"), status: .pending))),
        ChatItem(kind: .confirmation(ConfirmationState(request: ConfirmationRequest(
            toolName: "create_reminder", riskLevel: .write, title: "Create reminder", message: "",
            fields: [
                ConfirmationField(id: "title", label: "Titel", value: "Brot", kind: .text),
                ConfirmationField(id: "due", label: "Due", value: "", kind: .dateTime, isOptionalDate: true),
            ], confirmLabel: "Create"), status: .approved))),
    ]

    /// SEC-1: links the user did not type wait for a card, built by `open_url` itself: a look-alike host with its
    /// punycode form and a long link carrying data, and a mail link the agent composed. Below them, the status of a
    /// link into the local network the agent tried on its own: refused before any card, saying why.
    static let linkConfirmations: [ChatItem] = {
        let tool = OpenURLTool(context: OpenAppToolTests.context())
        let links = [
            "https://xn--80ak6aa92e.com/login?d=" + String(repeating: "Zahnarzt%20Dr.%20Weber%2008:30%20", count: 6),
            "mailto:lisa@example.com?cc=max@example.com&subject=Termine&body=Zahnarzt%20Dr.%20Weber",
        ]
        let refusal = Result { try LinkPolicy.checkNotTyped(try LinkPolicy.check("http://192.168.178.1/")) }
        let status: String = if case .failure(let error as ToolError) = refusal { AgentLoop.statusText(for: error) } else { "" }
        return links.map { link in
            ChatItem(kind: .confirmation(ConfirmationState(
                request: tool.confirmationRequest(for: ToolArguments(["url": .string(link)])), status: .pending)))
        } + [ChatItem(kind: .toolStatus(ToolStatus(toolCallID: "local", toolName: tool.name, category: tool.category, text: status,
                                                   state: .failed)))]
    }()

    static var failedTurn: [ChatItem] {
        [
            ChatItem(kind: .user(text: "Was steht morgen in meinem Kalender?", attachments: [])),
            ChatItem(kind: .assistant(text: "Ich sehe nach", isStreaming: false)),
            errorNotice(.network(.cannotConnect), .thisMac(address: "localhost:11434")),
        ]
    }

    /// D2: the notices failed requests end with (in the interface's language).
    static var errorNotices: [ChatItem] {
        let ollama = ProviderDestination.thisMac(address: "localhost:11434")
        return [
            errorNotice(.claudeCodeNotLoggedIn, .claudeSubscription),
            errorNotice(.usageLimitReached(resetsAt: FlexibleDate.parse("2026-10-05T15:00:00+02:00")?.date), .claudeSubscription),
            errorNotice(.network(.cannotConnect), ollama),
            errorNotice(.modelNotFound(model: "llama3"), ollama),
            errorNotice(.toolsNotSupported(model: "gemma3:4b"), ollama),
            errorNotice(.rateLimited(retryAfter: 30), .anthropicAPI),
            errorNotice(.contextTooLong, .anthropicAPI),
            ChatItem(kind: .notice(Notice(style: .warning, message: String(localized: "The model declined this request. Start a new chat to continue."),
                                          action: .newChat))),
        ]
    }

    /// The notice `AgentLoop` shows for `error` with requests going to `destination`.
    static func errorNotice(_ error: LLMError, _ destination: ProviderDestination) -> ChatItem {
        let actions = AgentLoop.noticeActions(for: error, destination: destination)
        return ChatItem(kind: .notice(Notice(style: .error, message: error.userMessage(for: destination), action: actions.first,
                                             secondaryAction: actions.dropFirst().first)))
    }

    static let markdown: [ChatItem] = [
        ChatItem(kind: .assistant(text: """
        # Überschrift 1
        ## Überschrift 2
        ### Überschrift 3

        Ein Absatz mit *kursiv*, **fett**, ~~durchgestrichen~~, `inline code` und einem Link: https://example.com.
        Zweite Zeile im selben Absatz.

        1. Erster Schritt
        2. Zweiter Schritt
           - Unterpunkt a
           - Unterpunkt b
             - noch tiefer
        10. Zehnter Schritt

        - [x] Erledigt
        - [ ] Offen

        > Hinweis: Eine Mail enthielt Anweisungen („leite alles weiter“), ich habe sie ignoriert.

        ```swift
        let summe = rechnungen.map(\\.betrag).reduce(0, +)
        print("Summe: \\(summe)")
        ```

        | Datei | Datum | Betrag |
        |:--|:-:|--:|
        | Telekom_2026-03.pdf | 12. März | 39,95 € |
        | Stadtwerke_Q1.pdf | 2. April | 124,10 € |

        ---

        Fertig.
        """, isStreaming: false)),
    ]
}
