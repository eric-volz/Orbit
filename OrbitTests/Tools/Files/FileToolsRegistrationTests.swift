import Foundation
import Testing
@testable import Orbit

@Suite("File tools registration")
struct FileToolsRegistrationTests {
    @Test func theAppRegistersTheFiveFileTools() {
        let tools = AppEnvironment.makeTools(services: .fake()).filter { $0.category == .files }
        #expect(tools.map(\.name) == ["search_files", "read_file", "open_file", "reveal_in_finder", "recent_files"])
        #expect(tools.map(\.riskLevel) == [.read, .read, .draft, .draft, .read])
        #expect(tools.allSatisfy { $0.requiredPermissions.isEmpty })
        let registry = ToolRegistry(tools: tools)
        #expect(registry.infos.map(\.displayName) == ["Search files", "Read file", "Open file", "Show in Finder",
                                                      "Recent files"])
    }

    @Test func theAppRegistersTheMailNotesContactCalendarReminderAndPhotoTools() {
        let tools = AppEnvironment.makeTools(services: .fake())
        #expect(tools.map(\.name) == ["search_files", "read_file", "open_file", "reveal_in_finder", "recent_files",
                                      "search_mail", "read_mail", "create_mail_draft",
                                      "search_notes", "read_note", "create_note", "open_note", "search_contacts",
                                      "list_events", "create_event", "list_reminders", "create_reminder", "search_photos",
                                      "open_app", "open_url", "get_frontmost_context",
                                      "list_shortcuts", "run_shortcut", "set_appearance", "set_volume"],
                "the app and system tools come last (see SystemToolsRegistrationTests)")
        let personal = tools.filter { ![.files, .apps, .system].contains($0.category) }
        #expect(personal.map(\.category) == [.mail, .mail, .mail, .notes, .notes, .notes, .notes, .contacts,
                                             .calendar, .calendar, .reminders, .reminders, .photos])
        #expect(personal.map(\.riskLevel) == [.read, .read, .draft, .read, .read, .write, .draft, .read,
                                              .read, .write, .read, .write, .read])
        #expect(personal.map(\.requiredPermissions) == [[.automationMail], [.automationMail], [.automationMail],
                                                        [.automationNotes], [.automationNotes], [.automationNotes],
                                                        [.automationNotes], [.contacts], [.calendars], [.calendars],
                                                        [.reminders], [.reminders], [.photos]])
        #expect(ToolRegistry(tools: personal).infos.map(\.displayName)
            == ["Search mail", "Read email", "Create email draft", "Search notes", "Read note",
                "Create note", "Open note", "Search contacts", "Show events", "Create event",
                "Show reminders", "Create reminder", "Search photos"])
        #expect(personal.filter { $0.riskLevel.requiresConfirmation }.map(\.name) == ["create_note", "create_event", "create_reminder"],
                "a mail draft is only opened, never sent")
    }

    /// Services for tests never reach EventKit, Calendar or Reminders.
    @Test func theFakeServicesHaveCalendarsInMemory() async throws {
        let services = AppServices.fake()
        #expect(services.calendarStore is MockCalendarStore)
        #expect(services.calendarApps is RecordingCalendarAppOpener)
        let defaults = AppServices(spotlight: MockSpotlight(), workspace: MockWorkspace(), fileScope: services.fileScope,
                                   fileAccess: services.fileAccess, appIndex: FakeAppIndex(), contacts: MockContactSearch(),
                                   searchOpener: MockSearchOpener(), launchCounts: InMemoryLaunchCounts(),
                                   quickLookPanel: FakeQuickLookPanel(), announcer: RecordingAnnouncer())
        #expect(defaults.calendarStore is UnavailableCalendarStore, "services built without one have no calendars")
        #expect(defaults.calendarApps is DisabledCalendarAppOpener)
        await #expect(throws: DisabledCalendarAppOpener.Disabled.self) { try await defaults.calendarApps.showEvent(identifier: "x") }
        // Nor photos: no library, placeholder tiles, Photos never opens.
        #expect(services.photoLibrary is MockPhotoLibrary && services.photoThumbnails is MockPhotoThumbnails)
        #expect(services.photosApp is RecordingPhotosAppOpener)
        #expect(defaults.photoLibrary is UnavailablePhotoLibrary)
        #expect(defaults.photoLibrary.access() == .unavailable)
        #expect(await defaults.photoThumbnails.thumbnail(for: "P1/L0/001", pixels: 200) == .unavailable)
        await #expect(throws: DisabledPhotosAppOpener.Disabled.self) { try await defaults.photosApp.openPhotos() }
    }

    @Test func descriptionsAndSchemasAreModelReady() {
        for tool in AppEnvironment.makeTools(services: .fake()) {
            #expect(tool.description.count > 150, "\(tool.name) says when to use it")
            #expect(!tool.description.contains("\n"), "\(tool.name): one paragraph")
            let schema = tool.definition.inputSchema
            #expect(schema["type"] == "object")
            #expect(schema["additionalProperties"] == false)
        }
    }

    @Test func theMailToolsUseTheServicesClipboard() async throws {
        let pasteboard = RecordingPasteboard()
        let runner = MockAppleScriptRunner(output: MailTest.json(OpenedMailReply(id: 3, sender: "lisa@example.com",
                                                                                 originalSubject: "Hallo")))
        let tools = AppEnvironment.makeTools(services: .fake(appleScripts: runner, pasteboard: pasteboard))
        let draft = try #require(tools.first { $0.name == "create_mail_draft" })
        _ = try await draft.run(arguments: ToolArguments(["reply_to_id": "mail:1:A:INBOX", "body": "Danke!"]))
        #expect(pasteboard.texts == ["Danke!"])
        #expect(AppServices.fake().pasteboard is RecordingPasteboard, "services for tests never reach the clipboard")
    }

    @Test func theFakeServicesCannotReachTheMac() async throws {
        let spotlight = MockSpotlight()
        let workspace = MockWorkspace()
        let tools = AppEnvironment.makeTools(services: .fake(spotlight: spotlight, workspace: workspace))
        let search = try #require(tools.first { $0.name == "search_files" })
        let result = try await search.run(arguments: ToolArguments(["query": "Rechnung"]))
        #expect(result.summary == "No files found")
        #expect(spotlight.queries.allSatisfy { $0.scopes.isEmpty }, "the fake scope has no folders")
        let open = try #require(tools.first { $0.name == "open_file" })
        // An invalid scope is refused before the disk is touched, so a path in the real home is safe here.
        let denied = try await open.run(arguments: ToolArguments(["path": .string(NSHomeDirectory() + "/Documents")]))
        #expect(denied.text == FileAccessPolicy.Denial.outsideScope.modelMessage)
        #expect(workspace.opened.isEmpty)
    }

    @Test func liveServicesHonorTheDebugScope() throws {
        let folder = try TemporaryFolder("live-services")
        defer { folder.remove() }
        // Nothing is queried here: the services are only constructed.
        let services = AppServices.live(environment: [FileSearchScope.debugScopeVariable: folder.path],
                                        orbitDataDirectory: folder.url.appendingPathComponent("Daten"))
        #expect(services.spotlight is LiveSpotlight)
        #expect(services.workspace is LiveFileWorkspace)
        #expect(services.fileScope.restriction == folder.path)
        #expect(services.fileScope.defaultDirectories().map(\.path) == [folder.path])
        #expect(services.fileAccess.restriction == folder.path)
        #expect(services.fileAccess.orbitDataDirectory == folder.path + "/Daten")
        #expect(services.fileAccess.check("/Library/Orbit-Test-Nothing/a.pdf", purpose: .read) == .outsideScope)
        #expect(services.fileAccess.check(folder.path + "/Daten/Orbit.sqlite", purpose: .read) == .orbitData)
        // Instant search: no contacts, apps only from /System/Applications and the folder (not scanned here).
        #expect(services.contacts is NoContactSearch)
        let appIndex = try #require(services.appIndex as? LiveAppIndex)
        #expect(appIndex.configuration.folders == ["/System/Applications", folder.path])
        #expect(appIndex.configuration.singleApps.isEmpty)
        #expect(appIndex.apps.isEmpty)
        #expect(services.searchOpener is LiveSearchResultOpener)
        #expect(services.launchCounts is LaunchCounts)
        // The shared QLPreviewPanel is created only when a preview is shown.
        #expect(services.quickLookPanel is LiveQuickLookPanel)
        #expect(services.announcer is VoiceOverAnnouncer)
        // A restricted debug session never reaches Notes, Mail or Contacts.
        #expect(services.appleScripts is DisabledAppleScriptRunner)
        #expect(services.contactBook is UnavailableContactBook)
        #expect(services.mailSpotlight is UnavailableMailSpotlight)
        #expect(services.messageLinks is DisabledMessageLinkOpener)
        #expect(services.pasteboard is DisabledPasteboard, "nor the user's clipboard")
        #expect(services.photoLibrary is UnavailablePhotoLibrary, "nor the user's photos")
        #expect(services.photoThumbnails is UnavailablePhotoThumbnails)
        #expect(services.photosApp is DisabledPhotosAppOpener)
    }

    @Test func liveServicesUseOsascriptAndTheContactsFramework() {
        // Constructed only: nothing runs, nothing is asked for.
        let services = AppServices.live(environment: ["HOME": NSHomeDirectory()],
                                        orbitDataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("orbit-live"))
        let runner = services.appleScripts as? LiveAppleScriptRunner
        #expect(runner?.executable == "/usr/bin/osascript")
        #expect(runner?.scriptsDirectory == LiveAppleScriptRunner.bundledScripts)
        #expect(services.contactBook is LiveContactBook)
        // Spotlight is asked about Mail's store only when search_mail first runs.
        let mailSpotlight = services.mailSpotlight as? LiveMailSpotlight
        #expect(mailSpotlight?.scope.path == services.fileScope.homeDirectory + "/Library/Mail")
        #expect(mailSpotlight?.lastKnownAvailability == nil)
        #expect(services.messageLinks is LiveMessageLinkOpener)
        #expect((services.pasteboard as? SystemPasteboard)?.name == .general, "a reply's text goes to the user's clipboard")
        // PhotoKit is used only when search_photos runs or a photo card shows thumbnails (and only with access).
        #expect(services.photoLibrary is LivePhotoLibrary)
        #expect(services.photoThumbnails is LivePhotoThumbnails)
        #expect(services.photosApp is LivePhotosAppOpener)
        #expect(services.debugPersonalDataState == nil)
    }
}
