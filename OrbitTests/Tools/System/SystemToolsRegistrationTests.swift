import Foundation
import Testing
@testable import Orbit

/// The app and system tools as the app registers them, and the services
/// behind them: tests and restricted debug sessions reach nothing of the Mac.
@Suite("App and system tools registration")
struct SystemToolsRegistrationTests {
    @Test func theAppRegistersTheAppAndSystemTools() {
        let tools = AppEnvironment.makeTools(services: .fake()).filter { [.apps, .system].contains($0.category) }
        #expect(tools.map(\.name) == ["open_app", "open_url", "get_frontmost_context", "list_shortcuts", "run_shortcut",
                                      "set_appearance", "set_volume"])
        #expect(tools.map(\.category) == [.apps, .apps, .apps, .system, .system, .system, .system])
        #expect(tools.map(\.riskLevel) == [.draft, .write, .read, .read, .write, .write, .write],
                "an app opens at once; a link (unless the user typed it), a shortcut, the appearance and the volume only after confirmation")
        #expect(tools.map(\.maxCallsPerRequest) == [nil, 3, nil, nil, nil, nil, nil])
        #expect(tools.map(\.requiredPermissions) == [[], [], [], [], [], [.automationSystemEvents], []])
        #expect(ToolRegistry(tools: tools).infos.map(\.displayName)
            == ["Open app", "Open link", "Read frontmost app", "List shortcuts", "Run shortcut",
                "Change appearance", "Change volume"])
        #expect(tools.map(\.executionTimeout) == [nil, nil, nil, nil, .seconds(135), nil, nil])
        for tool in tools {
            #expect(tool.description.count > 200, "\(tool.name) says precisely when to use it")
            #expect(!tool.statusText(for: ToolArguments()).isEmpty)
        }
    }

    /// D4: no dedicated Focus tool, because there is no public way; run_shortcut explains the user's own shortcut.
    @Test func focusIsSwitchedThroughTheUsersShortcut() {
        let names = AppEnvironment.makeTools(services: .fake()).map(\.name)
        #expect(!names.contains { $0.contains("focus") || $0.contains("disturb") })
        let runShortcut = AppEnvironment.makeTools(services: .fake()).first { $0.name == "run_shortcut" }
        #expect(runShortcut?.description.contains("Focus and Do Not Disturb: macOS gives Orbit no other way to switch them.") == true)
    }

    @Test func servicesForTestsAndDefaultsReachNothing() async throws {
        let fake = AppServices.fake()
        #expect(fake.appLauncher is RecordingAppLauncher && fake.shortcuts is MockShortcuts)
        #expect(fake.audioVolume is MockAudioVolume && fake.frontmostContext is MockFrontmostContext)
        let defaults = AppServices(spotlight: MockSpotlight(), workspace: MockWorkspace(), fileScope: fake.fileScope,
                                   fileAccess: fake.fileAccess, appIndex: FakeAppIndex(), contacts: MockContactSearch(),
                                   searchOpener: MockSearchOpener(), launchCounts: InMemoryLaunchCounts(),
                                   quickLookPanel: FakeQuickLookPanel(), announcer: RecordingAnnouncer())
        #expect(defaults.appLauncher is DisabledAppLauncher && defaults.shortcuts is UnavailableShortcuts)
        #expect(defaults.audioVolume is UnavailableAudioVolume && defaults.frontmostContext is UnavailableFrontmostContext)
        #expect(await defaults.frontmostContext.capture(.tool) == FrontmostContext(gaps: [.noApp]))
        await #expect(throws: ShortcutsError.unavailable) { try await defaults.shortcuts.shortcuts(in: nil) }
        await #expect(throws: AudioVolumeError.unavailable) { try await defaults.audioVolume.outputDevice() }
    }

    /// A debug session restricted with ORBIT_DEBUG_FILE_SCOPE (and no fake data) opens, runs and reads nothing.
    @Test func aRestrictedDebugSessionReachesNothing() throws {
        let folder = try TemporaryFolder("orbit-restricted")
        defer { folder.remove() }
        let services = AppServices.live(environment: [FileSearchScope.debugScopeVariable: FileFixtures.root],
                                        orbitDataDirectory: folder.url)
        #expect(services.appLauncher is DisabledAppLauncher)
        #expect(services.shortcuts is UnavailableShortcuts)
        #expect(services.audioVolume is UnavailableAudioVolume)
        #expect(services.frontmostContext is UnavailableFrontmostContext)
        #expect(services.debugFrontmostScene == nil)
    }

    #if DEBUG
    @MainActor
    @Test func theDebugCommandIsKnown() {
        #expect(DebugAutomation.commandNames.contains("fake-frontmost"))
    }
    #endif
}
