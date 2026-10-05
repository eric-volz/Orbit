#if DEBUG
import Foundation
import Testing
@testable import Orbit

/// The DEBUG fake-data mode's Mac (shortcuts.json, frontmost.json and
/// system.json in OrbitTests/Fixtures/PersonalData): invented shortcuts, a
/// frontmost app with its selection, the appearance and an output device,
/// and what Orbit did with them, as `orbitctl state` shows it. No shortcut
/// runs, no app or link opens, no setting changes and no other app is read.
@Suite("Fake system data (DEBUG)")
struct FakeSystemDataTests {
    static func data(folder: URL = FakePersonalDataTests.fixtures) -> (FakeSystemData, [String]) {
        var errors: [String] = []
        let data = FakeSystemData(folder: folder, errors: &errors)
        return (data, errors)
    }

    /// The app's services in the fake-data mode, restricted to the file fixtures (like the E2E runs).
    static func services(folder: URL = FakePersonalDataTests.fixtures) throws -> (AppServices, TemporaryFolder) {
        let data = try TemporaryFolder("orbit-fake-system")
        let services = AppServices.live(environment: [FakePersonalData.variable: folder.path,
                                                      FileSearchScope.debugScopeVariable: FileFixtures.root],
                                        orbitDataDirectory: data.url)
        return (services, data)
    }

    @Test func loadsTheInventedMac() {
        let (data, errors) = Self.data()
        #expect(errors.isEmpty)
        #expect(data.shortcuts.map(\.info.name) == ["Fokus: Arbeiten", "Nicht stören an", "Nicht stören aus", "Wetter heute",
                                                    "Text übersetzen", "Wochenplan als Bild", "Lichter aus", "Kaputter Kurzbefehl"])
        #expect(data.folders == ["Fokus", "Alltag", "Text"])
        #expect(data.scenes.map(\.name) == ["finder", "finder-secrets", "textedit", "password", "passwords-app", "calculator"])
        #expect(data.currentScene?.name == "finder")
        #expect(data.accessibility == .granted && data.finderAutomation == .granted && data.systemEventsAutomation == .granted)
        let state = data.stateSummary()
        #expect(state["appearance"] == "light" && state["volume"] == 50 && state["muted"] == false)
        #expect(state["shortcutRuns"] == .array([]) && state["openedApps"] == .array([]) && state["contextCaptures"] == .array([]))
        #expect(data.scenes.allSatisfy { $0.app.processID >= FakeSystemData.firstProcessID }, "never a real process")
    }

    @Test func shortcutsAnswerAsConfiguredAndAreRecorded() async throws {
        let (data, _) = Self.data()
        let shortcuts = FakeShortcuts(data: data)
        let all = try await shortcuts.shortcuts(in: nil)
        #expect(all.count == 8 && all.allSatisfy { $0.identifier != nil })
        #expect(try await shortcuts.shortcuts(in: ShortcutFolder(name: "Fokus", identifier: nil)).map(\.name)
            == ["Fokus: Arbeiten", "Nicht stören an", "Nicht stören aus"])
        #expect(try await shortcuts.folders().map(\.name) == ["Fokus", "Alltag", "Text"])

        func run(_ name: String, _ input: String? = nil) async throws -> ShortcutOutput {
            try await shortcuts.run(try #require(all.first { $0.name == name }), input: input)
        }
        #expect(try await run("Text übersetzen", "Guten Morgen") == .text("Guten Morgen", isComplete: true), "an echo of the input")
        #expect(try await run("Wetter heute") == .text("Musterstadt: sonnig, 21 °C, am Abend Regen.", isComplete: true))
        #expect(try await run("Wochenplan als Bild") == .files([.init(typeIdentifier: "public.png", size: 245_760)]))
        #expect(try await run("Lichter aus") == ShortcutOutput.none)
        await #expect(throws: ShortcutsError.failed(message: "Die Aktion „URL abrufen“ konnte nicht ausgeführt werden.")) {
            try await run("Kaputter Kurzbefehl")
        }
        #expect(data.stateSummary()["shortcutRuns"] == [
            ["name": "Text übersetzen", "input": "Guten Morgen"], ["name": "Wetter heute", "input": .null],
            ["name": "Wochenplan als Bild", "input": .null], ["name": "Lichter aus", "input": .null],
            ["name": "Kaputter Kurzbefehl", "input": .null],
        ])
    }

    /// The real capture on the invented scenes: Finder items inside the fixtures, never secrets.
    @Test func theCaptureReadsTheInventedScenes() async throws {
        let (services, folder) = try Self.services()
        defer { folder.remove() }
        let select = try #require(services.debugFrontmostScene)

        let finder = await services.frontmostContext.capture(.chips)
        #expect(finder.app?.name == "Finder")
        #expect(finder.finderPaths == [FileFixtures.path("Rechnungen/Rechnung-Telekom-2026-08.pdf"),
                                       FileFixtures.path("Rechnungen/Vodafone-Invoice-2026-08.pdf")].map {
            FilePath.abbreviate($0, home: services.fileScope.homeDirectory)
        })
        #expect(finder.attachments().map(\.label) == ["With selection: Rechnung-Telekom-2026-08.pdf and 1 more"])

        #expect(select("finder-secrets") == ["scene": "finder-secrets", "scenes": [
            "finder", "finder-secrets", "textedit", "password", "passwords-app", "calculator",
        ]])
        let secrets = await services.frontmostContext.capture(.chips)
        #expect(secrets.finderPaths.map { FilePath.lastComponent($0) } == ["Notizen.md"], "server.pem is never shared")
        #expect(secrets.gaps == [.itemsWithheld])
        #expect(secrets.attachments().map(\.label) == ["With selection: Notizen.md · 1 protected file left out"],
                "E2E4-1: not \"und 1 weitere\"")

        _ = select("textedit")
        let text = await services.frontmostContext.capture(.tool)
        #expect(text.selectedText?.hasPrefix("Die Lieferung des Gartenhauses") == true)
        #expect(text.windowTitle == "Angebot Gartenhaus.rtf")

        _ = select("password")
        let password = await services.frontmostContext.capture(.tool)
        #expect(password.selectedText == nil && password.gaps == [.secureField])

        _ = select("passwords-app")
        #expect(await services.frontmostContext.capture(.tool).gaps == [.passwordManager])

        _ = select("calculator")
        let calculator = await services.frontmostContext.capture(.chips)
        #expect(calculator.app?.name == "Rechner" && calculator.attachments().isEmpty)

        #expect(select("unbekannt")["error"] == "No scene 'unbekannt'. Scenes: finder, finder-secrets, textedit, password, passwords-app, calculator")
        let state = try #require(services.debugPersonalDataState?())
        guard case .array(let captures)? = state["contextCaptures"] else {
            Issue.record("captures are recorded")
            return
        }
        #expect(captures.count == 6)
        #expect(captures.first == ["scene": "finder", "for": "chips", "app": "Finder", "windowTitle": false, "selectedText": false,
                                   "finderItems": 2, "gaps": .array([])])
        #expect(state["frontmostScene"] == "calculator")
    }

    @Test func permissionsComeFromTheFiles() async throws {
        let folder = try TemporaryFolder("orbit-fake-system-permissions")
        defer { folder.remove() }
        try folder.write("frontmost.json", """
            {"accessibility": "denied", "finderAutomation": "notDetermined",
             "scenes": [{"name": "finder", "app": "Finder", "bundleID": "com.apple.finder", "finderSelection": ["/tmp/a.txt"]}]}
            """)
        try folder.write("system.json", #"{"automation": "denied", "appearance": "dark"}"#)
        let (services, data) = try Self.services(folder: folder.url)
        defer { data.remove() }
        let access = services.permissionAccess
        #expect(access.status(of: .accessibility) == .denied)
        #expect(access.status(of: .automationFinder) == .notDetermined)
        #expect(access.status(of: .automationSystemEvents) == .denied)

        let context = await services.frontmostContext.capture(.chips)
        #expect(context.gaps == [.finderNotPermitted], "the script is never run without the permission")
        #expect(await access.request(.automationFinder) == .granted, "the fake user agrees")
        #expect(await access.request(.accessibility) == .denied, "Accessibility is granted in System Settings only")

        let appearance = SetAppearanceTool(context: SystemToolContext(services: services))
        await #expect(throws: ToolError.permissionDenied(.automationSystemEvents)) {
            try await appearance.run(arguments: ToolArguments(["dark": false]))
        }
    }

    @Test func appearanceVolumeAppsAndLinksAreRecorded() async throws {
        let (services, folder) = try Self.services()
        defer { folder.remove() }
        let context = SystemToolContext(services: services)
        let dark = try await SetAppearanceTool(context: context).run(arguments: ToolArguments(["dark": true]))
        #expect(dark.summary == "Dark appearance turned on")
        let again = try await SetAppearanceTool(context: context).run(arguments: ToolArguments(["dark": true]))
        #expect(again.summary == "Appearance was already dark")

        let volume = SetVolumeTool(context: context)
        let prepared = try await volume.prepareForConfirmation(ToolArguments(["level": 35]))
        #expect(prepared["_device"] == "Orbit-Testlautsprecher")
        _ = try await volume.run(arguments: prepared)

        let apps = AppToolContext(services: services)
        _ = try await OpenURLTool(context: apps).run(arguments: ToolArguments(["url": "https://example.com/wetter"]))
        try await services.appLauncher.openApplication(at: URL(fileURLWithPath: "/System/Applications/Calculator.app"))

        let state = try #require(services.debugPersonalDataState?())
        #expect(state["appearance"] == "dark" && state["appearanceChanges"] == ["dark", "dark"])
        #expect(state["volume"] == 35 && state["volumeChanges"] == [["level": 35, "muted": .null]])
        #expect(state["openedLinks"] == ["https://example.com/wetter"])
        #expect(state["openedApps"] == ["/System/Applications/Calculator.app"])
    }

    @Test func brokenFilesGiveEmptyDataAndErrors() throws {
        let folder = try TemporaryFolder("orbit-fake-system-broken")
        defer { folder.remove() }
        try folder.write("shortcuts.json", "{ kaputt")
        try folder.write("frontmost.json", #"{"scene": "fehlt", "accessibility": "vielleicht"}"#)
        let (data, errors) = Self.data(folder: folder.url)
        #expect(data.shortcuts.isEmpty && data.scenes.isEmpty && data.currentScene == nil)
        #expect(errors.count == 3, "\(errors)")
        #expect(errors.contains { $0.hasPrefix("shortcuts.json could not be read") })
        #expect(errors.contains("frontmost.json: there is no scene named 'fehlt'."))
        #expect(errors.contains("'vielleicht' is no permission state (granted, denied, notDetermined or restricted)."))
    }
}
#endif
