import Foundation

/// The system access Orbit's tools, instant search and cards use: Spotlight,
/// opening files, where file searches may look, the app index, contacts,
/// opening search results and their launch counts, the Quick Look panel,
/// VoiceOver announcements, AppleScript (Notes, Mail), the contact book,
/// Spotlight for Mail's messages, opening messages from mail cards, the
/// clipboard (the text of replies), macOS's permissions, the calendars and
/// reminders (EventKit) and showing their items in Calendar and Reminders,
/// the Photos library (PhotoKit), the thumbnails of photo cards and opening
/// Photos, opening apps and links for the agent, the Shortcuts app, the
/// volume of the output device and the context of the frontmost app. The app
/// passes `live()`; tests and snapshot environments pass fakes, so they cannot
/// reach the user's files, apps, contacts, notes, mail, calendars, reminders,
/// photos, shortcuts, clipboard or other apps' windows, change a system
/// setting, show a preview window or speak by construction.
struct AppServices: Sendable {
    var spotlight: any SpotlightQuerying
    var workspace: any FileWorkspace
    var fileScope: FileSearchScope
    var fileAccess: FileAccessPolicy
    /// Apps for instant search.
    var appIndex: any AppIndexing
    /// Contacts for instant search.
    var contacts: any ContactSearching
    /// Opens instant-search results.
    var searchOpener: any SearchResultOpening
    var launchCounts: any LaunchCountStoring
    /// The Quick Look panel for file cards.
    var quickLookPanel: any QuickLookPanel
    /// Tells VoiceOver what the arrow keys selected in instant search and file cards.
    var announcer: any Announcing
    /// Runs Orbit's AppleScripts (Notes; Mail; showing a photo in Photos).
    var appleScripts: any AppleScriptRunning
    /// Contacts for the tools and the user's name in the system prompt.
    var contactBook: any ContactBook
    /// Spotlight's index of Mail's messages (search_mail uses it when it works).
    var mailSpotlight: any MailSpotlightSearching
    /// Opens messages from mail cards (message:// links).
    var messageLinks: any MessageLinkOpening
    /// The clipboard: the text of a reply for Mail's reply window ("Copy Text").
    var pasteboard: any PasteboardWriting
    /// Reads and requests macOS's permissions (`PermissionManager`).
    var permissionAccess: any PermissionAccessing
    /// Events and reminders (EventKit) for the calendar and reminder tools.
    var calendarStore: any CalendarStore
    /// Shows events in Calendar and reminders in Reminders (event and reminder cards).
    var calendarApps: any CalendarAppOpening
    /// The Photos library (PhotoKit, metadata only) for search_photos.
    var photoLibrary: any PhotoLibrary
    /// Thumbnails for photo cards (PhotoKit; never downloads from iCloud).
    var photoThumbnails: any PhotoThumbnailProviding
    /// Opens Photos when a photo card cannot show the photo itself.
    var photosApp: any PhotosAppOpening
    /// Opens apps and links for the agent (`open_app`, `open_url`).
    var appLauncher: any AppLaunching
    /// The user's shortcuts (`list_shortcuts`, `run_shortcut`).
    var shortcuts: any ShortcutsService
    /// The volume of the output device (`set_volume`).
    var audioVolume: any AudioVolumeControlling
    /// The frontmost app and what is selected there (context chips, `get_frontmost_context`).
    var frontmostContext: any FrontmostContextCapturing
    /// DEBUG: what the fake personal data recorded (`orbitctl state`); nil otherwise.
    var debugPersonalDataState: (@Sendable () -> JSONValue)?
    /// DEBUG: lists the fake frontmost scenes (nil) or switches to one
    /// (`orbitctl fake-frontmost`); nil without fake data.
    var debugFrontmostScene: (@Sendable (String?) -> JSONValue)?

    init(spotlight: any SpotlightQuerying, workspace: any FileWorkspace, fileScope: FileSearchScope,
         fileAccess: FileAccessPolicy, appIndex: any AppIndexing, contacts: any ContactSearching,
         searchOpener: any SearchResultOpening, launchCounts: any LaunchCountStoring,
         quickLookPanel: any QuickLookPanel, announcer: any Announcing,
         appleScripts: any AppleScriptRunning = DisabledAppleScriptRunner(),
         contactBook: any ContactBook = UnavailableContactBook(),
         mailSpotlight: any MailSpotlightSearching = UnavailableMailSpotlight(),
         messageLinks: any MessageLinkOpening = DisabledMessageLinkOpener(),
         pasteboard: any PasteboardWriting = DisabledPasteboard(),
         permissionAccess: any PermissionAccessing = FixedPermissionAccess(),
         calendarStore: any CalendarStore = UnavailableCalendarStore(),
         calendarApps: any CalendarAppOpening = DisabledCalendarAppOpener(),
         photoLibrary: any PhotoLibrary = UnavailablePhotoLibrary(),
         photoThumbnails: any PhotoThumbnailProviding = UnavailablePhotoThumbnails(),
         photosApp: any PhotosAppOpening = DisabledPhotosAppOpener(),
         appLauncher: any AppLaunching = DisabledAppLauncher(),
         shortcuts: any ShortcutsService = UnavailableShortcuts(),
         audioVolume: any AudioVolumeControlling = UnavailableAudioVolume(),
         frontmostContext: any FrontmostContextCapturing = UnavailableFrontmostContext(),
         debugPersonalDataState: (@Sendable () -> JSONValue)? = nil) {
        self.spotlight = spotlight
        self.workspace = workspace
        self.fileScope = fileScope
        self.fileAccess = fileAccess
        self.appIndex = appIndex
        self.contacts = contacts
        self.searchOpener = searchOpener
        self.launchCounts = launchCounts
        self.quickLookPanel = quickLookPanel
        self.announcer = announcer
        self.appleScripts = appleScripts
        self.contactBook = contactBook
        self.mailSpotlight = mailSpotlight
        self.messageLinks = messageLinks
        self.pasteboard = pasteboard
        self.permissionAccess = permissionAccess
        self.calendarStore = calendarStore
        self.calendarApps = calendarApps
        self.photoLibrary = photoLibrary
        self.photoThumbnails = photoThumbnails
        self.photosApp = photosApp
        self.appLauncher = appLauncher
        self.shortcuts = shortcuts
        self.audioVolume = audioVolume
        self.frontmostContext = frontmostContext
        self.debugPersonalDataState = debugPersonalDataState
    }

    /// The real Mac. Reads ORBIT_DEBUG_FILE_SCOPE and
    /// ORBIT_DEBUG_FAKE_PERSONAL_DATA once (DEBUG builds only):
    /// - with the file scope, instant search finds files only in that folder,
    ///   apps only in /System/Applications and that folder, and no contacts;
    ///   Notes, Mail, Contacts, Calendar, Reminders, Photos and the clipboard
    ///   are off for the tools too (unless fake data is given), and permissions
    ///   are not read (they count as granted);
    /// - with fake personal data, the tools, the user's name and instant
    ///   search use the invented notes, mail, contacts, events, reminders and
    ///   photos in that folder (`FakePersonalData`), and permissions come from
    ///   it too, so the user's Notes, Mail, Contacts, calendars, reminders,
    ///   photos and clipboard are never reached (what would go to the
    ///   clipboard, created events and reminders and what cards would show in
    ///   Calendar, Reminders or Photos are recorded; photo cards show invented
    ///   placeholder thumbnails), nothing is asked for and System Settings
    ///   never opens.
    /// In both cases Spotlight is never asked for Mail's messages. Nothing is
    /// scanned or queried until it is used. A restricted session without fake
    /// data opens no app or link, runs no shortcut, changes no setting and
    /// reads no other app; with fake data, those come from the invented
    /// `shortcuts.json`, `frontmost.json` and `system.json` and are recorded.
    static func live(environment: [String: String] = ProcessInfo.processInfo.environment,
                     orbitDataDirectory: URL = AppPaths.applicationSupport) -> AppServices {
        let scope = FileSearchScope.live(environment: environment)
        let policy = FileAccessPolicy(homeDirectory: scope.homeDirectory,
                                      orbitDataDirectory: FilePath.canonical(orbitDataDirectory.path),
                                      restriction: scope.restriction)
        let apps = AppIndexConfiguration.standard(homeDirectory: scope.homeDirectory, restriction: scope.restriction,
                                                  languages: AppIndexConfiguration.preferredLanguages())
        let isRestricted = scope.restriction != nil
        let contactBook: any ContactBook = isRestricted ? UnavailableContactBook() : LiveContactBook()
        let appleScripts: any AppleScriptRunning = isRestricted ? DisabledAppleScriptRunner()
            : LiveAppleScriptRunner(environment: environment)
        let permissionAccess: any PermissionAccessing = isRestricted ? FixedPermissionAccess()
            : LivePermissionAccess(contactBook: contactBook,
                                   fullDiskAccessProbe: LiveMailSpotlight.mailStore(home: scope.homeDirectory))
        let frontmostContext: any FrontmostContextCapturing = isRestricted ? UnavailableFrontmostContext()
            : FrontmostContextCapture(apps: LiveFrontmostApps(), accessibility: LiveAccessibilityReader(),
                                      finder: FinderService(runner: appleScripts), permissions: permissionAccess,
                                      policy: policy, homeDirectory: scope.homeDirectory)
        var services = AppServices(
            spotlight: LiveSpotlight(), workspace: LiveFileWorkspace(), fileScope: scope, fileAccess: policy,
            appIndex: LiveAppIndex(configuration: apps),
            contacts: isRestricted ? NoContactSearch() : LiveContactSearch(),
            searchOpener: LiveSearchResultOpener(), launchCounts: LaunchCounts(),
            quickLookPanel: LiveQuickLookPanel(), announcer: VoiceOverAnnouncer(),
            appleScripts: appleScripts,
            contactBook: contactBook,
            mailSpotlight: isRestricted ? UnavailableMailSpotlight()
                : LiveMailSpotlight(scope: LiveMailSpotlight.mailStore(home: scope.homeDirectory)),
            messageLinks: isRestricted ? DisabledMessageLinkOpener() : LiveMessageLinkOpener(),
            pasteboard: isRestricted ? DisabledPasteboard() : SystemPasteboard.general,
            permissionAccess: permissionAccess,
            // EventKit is touched only when a tool needs it (and only with access).
            calendarStore: isRestricted ? UnavailableCalendarStore() : LiveCalendarStore(),
            calendarApps: isRestricted ? DisabledCalendarAppOpener() : LiveCalendarAppOpener(),
            // PhotoKit is touched only when a tool or a card needs it (and only with access).
            photoLibrary: isRestricted ? UnavailablePhotoLibrary() : LivePhotoLibrary(),
            photoThumbnails: isRestricted ? UnavailablePhotoThumbnails() : LivePhotoThumbnails(),
            photosApp: isRestricted ? DisabledPhotosAppOpener() : LivePhotosAppOpener(),
            // Nothing runs or opens until a tool or the panel needs it.
            appLauncher: isRestricted ? DisabledAppLauncher() : LiveAppLauncher(opener: LiveSearchResultOpener()),
            shortcuts: isRestricted ? UnavailableShortcuts()
                : LiveShortcuts(inputDirectory: orbitDataDirectory.appendingPathComponent("ShortcutInput", isDirectory: true)),
            audioVolume: isRestricted ? UnavailableAudioVolume() : LiveAudioVolume(),
            frontmostContext: frontmostContext
        )
        #if DEBUG
        if let fake = FakePersonalData.fromEnvironment(environment) {
            services.appleScripts = FakeAppleScriptRunner(data: fake)
            services.contactBook = FakeContactBook(data: fake)
            services.contacts = FakeContactSearch(data: fake)
            services.mailSpotlight = UnavailableMailSpotlight()
            services.messageLinks = FakeMessageLinkOpener(data: fake)
            services.pasteboard = FakePasteboard(data: fake)
            services.permissionAccess = FakePermissionAccess(data: fake)
            services.calendarStore = FakeCalendarStore(data: fake.calendar)
            services.calendarApps = FakeCalendarAppOpener(data: fake.calendar)
            services.photoLibrary = FakePhotoLibrary(data: fake.photos)
            services.photoThumbnails = FakePhotoThumbnails(data: fake.photos)
            services.photosApp = FakePhotosAppOpener(data: fake.photos)
            services.appLauncher = FakeAppLauncher(data: fake.system)
            services.shortcuts = FakeShortcuts(data: fake.system)
            services.audioVolume = FakeAudioVolume(data: fake.system)
            services.frontmostContext = fake.system.contextCapture(
                finder: FinderService(runner: services.appleScripts), permissions: services.permissionAccess, policy: policy,
                homeDirectory: scope.homeDirectory)
            services.debugPersonalDataState = { fake.stateSummary() }
            services.debugFrontmostScene = { name in fake.system.selectScene(name) }
        }
        #endif
        return services
    }
}

extension FileToolContext {
    /// The file tools' context on these services.
    init(services: AppServices) {
        self.init(spotlight: services.spotlight, workspace: services.workspace, scope: services.fileScope,
                  policy: services.fileAccess)
    }
}
