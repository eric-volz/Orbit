import Foundation

/// Composition root: creates and owns the long-lived objects.
@MainActor
final class AppEnvironment {
    let settings: SettingsStore
    let secrets: any SecretStoring
    /// macOS's permissions: tools whose permission is denied are switched off
    /// and the agent is told (the agent loop reads them through `PermissionStatusProviding`).
    let permissions: PermissionManager
    let registry: ToolRegistry
    let agentLoop: AgentLoop
    let instantSearch: InstantSearch
    let panelState: PanelState
    /// Chat history in ~/Library/Application Support/Orbit (opened lazily, off the main thread).
    let conversationStore: ConversationStore
    /// Runs Claude Code for the Claude-subscription provider; `shutdown()` at quit.
    let claudeCodeRuntime: ClaudeCodeRuntime
    /// Claude Code's status and sign-in (Settings, the onboarding, the chat's
    /// notice); `shutdown()` at quit ends a sign-in that still runs.
    let claudeCodeAccount: ClaudeCodeAccountService
    /// System access for tools and instant search (live in the app, fakes in tests).
    let services: AppServices
    /// Quick Look previews of the files in file cards.
    let quickLook: QuickLookController
    /// After a pause the panel opens in search mode, the chat one step away.
    let chatParking: ChatParking
    /// The context chips captured when the user opens the panel.
    let contextCapture: ContextCapture
    /// Lists Accessibility and Automation: Finder while something reads the context.
    private var contextPermissions: ContextPermissionSync?

    /// The app's environment: the user's settings, the keychain, the chat
    /// history in Application Support and the live providers.
    convenience init(services: AppServices) {
        let settings = SettingsStore()
        settings.applyFirstLaunchProviderDefault()
        let claudeCodeRuntime = ClaudeCodeRuntime()
        self.init(services: services, settings: settings, secrets: Self.makeSecretStore(settings: settings),
                  conversationStore: ConversationStore(), claudeCodeRuntime: claudeCodeRuntime,
                  providerFactory: .live(claudeCodeRuntime: claudeCodeRuntime))
    }

    /// Tests pass settings, secrets, a chat history and providers of their own,
    /// so the environment touches nothing of the user's.
    init(services: AppServices, settings: SettingsStore, secrets: any SecretStoring, conversationStore: ConversationStore,
         claudeCodeRuntime: ClaudeCodeRuntime, providerFactory: LLMProviderFactory) {
        self.settings = settings
        self.services = services
        self.secrets = secrets
        let panelState = PanelState()
        self.panelState = panelState
        let registry = ToolRegistry(tools: Self.makeTools(services: services, keyboardHandoff: panelState))
        self.registry = registry
        self.permissions = PermissionManager(access: services.permissionAccess, tools: registry.infos)
        self.instantSearch = InstantSearch(services: services)
        self.quickLook = QuickLookController(panel: services.quickLookPanel)
        self.conversationStore = conversationStore
        self.claudeCodeRuntime = claudeCodeRuntime
        let claudeCodeAccount = ClaudeCodeAccountService { @MainActor in settings.claudeCodePath }
        self.claudeCodeAccount = claudeCodeAccount
        let contactBook = services.contactBook
        let agentLoop = AgentLoop(dependencies: AgentDependencies(
            settings: settings,
            secrets: secrets,
            registry: registry,
            store: conversationStore,
            permissions: permissions,
            providerFactory: providerFactory,
            // "My Card", only when Orbit may already read contacts (never asks).
            userName: { await contactBook.userName() },
            claudeCodeAccount: claudeCodeAccount,
            announcer: services.announcer,
            panelHasKeyboard: { panelState.hasKeyboard() }
        ))
        self.agentLoop = agentLoop
        // Shown, or back from Mail's reply window: VoiceOver hears a waiting card with the keys that decide it.
        panelState.keyboardDidReturn = { [weak agentLoop] in agentLoop?.announcePendingConfirmation() }
        self.chatParking = ChatParking(agentLoop: agentLoop, panelState: panelState)
        self.contextCapture = ContextCapture(capturer: services.frontmostContext, settings: settings, panelState: panelState,
                                             announcer: services.announcer)
        contextPermissions = ContextPermissionSync(settings: settings, registry: registry, permissions: permissions)
    }

    // MARK: Shared actions (used by keyboard handling in SwiftUI and AppKit alike)

    /// Escape: closes a Quick Look preview first; otherwise stops a running
    /// response; otherwise closes the panel.
    func handleEscape() {
        if quickLook.close() {
            return
        }
        if agentLoop.isRunning {
            agentLoop.cancel()
        } else {
            panelState.closePanel()
        }
    }

    /// ⌘N / "New Chat": the input's button, the Chat menu, the menu bar
    /// menu and a notice alike: back to search mode with an empty chat (a
    /// parked chat is closed too). When the chat ends with a notice that it can
    /// no longer answer the request (it no longer fits the model, or a refusal
    /// blocks it), that request goes into the input (`AgentLoop.requestForNewChat`)
    /// unsent, and without its context chips (what was selected may have
    /// changed). Every other chat leaves the input empty.
    func startNewChat() {
        let request = agentLoop.requestForNewChat
        quickLook.close()
        chatParking.unpark()
        agentLoop.newChat()
        panelState.inputText = request ?? ""
        instantSearch.clear()
    }

    // MARK: Factories

    /// All tools, registered here. `keyboardHandoff` is the
    /// panel, which stays visible while Mail's reply window takes the keyboard.
    nonisolated static func makeTools(services: AppServices,
                                      keyboardHandoff: any KeyboardHandoffAnnouncing = NoKeyboardHandoff()) -> [any Tool] {
        FileTools.all(context: FileToolContext(services: services))
            + MailTools.all(context: MailToolContext(services: services, keyboardHandoff: keyboardHandoff))
            + NotesTools.all(context: NotesToolContext(services: services))
            + ContactTools.all(context: ContactToolContext(services: services))
            + CalendarTools.all(context: CalendarToolContext(services: services))
            + ReminderTools.all(context: CalendarToolContext(services: services))
            + PhotoTools.all(context: PhotoToolContext(services: services))
            + AppTools.all(context: AppToolContext(services: services))
            + SystemTools.all(context: SystemToolContext(services: services))
    }

    private static func makeSecretStore(settings: SettingsStore) -> any SecretStoring {
        #if DEBUG
        // ORBIT_DEBUG_API_KEY: use an in-memory key so debug runs never touch the keychain.
        if let key = ProcessInfo.processInfo.environment["ORBIT_DEBUG_API_KEY"] {
            return InMemorySecretStore([SecretAccount.apiKey(for: settings.providerKind): key])
        }
        #endif
        return KeychainStore()
    }
}
