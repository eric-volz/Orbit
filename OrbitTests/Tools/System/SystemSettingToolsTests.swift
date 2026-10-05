import Foundation
import Testing
@testable import Orbit

/// `set_appearance` on a mock script runner (System Events never gets an
/// Apple Event) and `set_volume` on an output device in memory (Core Audio is
/// never touched): the cards, what changes after the user confirmed, and the
/// errors.
@Suite("set_appearance and set_volume")
struct SystemSettingToolsTests {
    static func context(scripts: MockAppleScriptRunner = MockAppleScriptRunner(),
                        volume: MockAudioVolume = MockAudioVolume()) -> SystemToolContext {
        SystemToolContext(shortcuts: MockShortcuts(), systemEvents: SystemEventsService(runner: scripts), volume: volume)
    }

    // MARK: set_appearance

    @Test func switchesToDarkThroughItsScript() async throws {
        let scripts = MockAppleScriptRunner(output: #"{"dark":true,"changed":true}"#)
        let result = try await SetAppearanceTool(context: Self.context(scripts: scripts)).run(arguments: ToolArguments(["dark": true]))
        #expect(scripts.runs == [.init(script: "system-appearance", arguments: ["dark"])])
        #expect(result.text == "macOS now uses the dark appearance.")
        #expect(result.card == .info(InfoItem(title: "Dark appearance", detail: "Turned on for all apps.", systemImage: "moon.fill")))
        #expect(result.summary == "Dark appearance turned on")
    }

    @Test func alreadyLightChangesNothing() async throws {
        let scripts = MockAppleScriptRunner(output: #"{"dark":false,"changed":false}"#)
        let result = try await SetAppearanceTool(context: Self.context(scripts: scripts)).run(arguments: ToolArguments(["dark": "false"]))
        #expect(scripts.runs.map(\.arguments) == [["light"]])
        #expect(result.text == "macOS already used the light appearance; nothing changed.")
        #expect(result.summary == "Appearance was already light")
    }

    @Test func theCardSaysWhatChanges() {
        let tool = SetAppearanceTool(context: Self.context())
        let dark = tool.confirmationRequest(for: ToolArguments(["dark": true]))
        #expect(dark.title == "Change appearance" && dark.confirmLabel == "Switch")
        #expect(dark.message == "Orbit switches macOS to the dark appearance.")
        #expect(dark.fields == [ConfirmationField(id: "dark", label: "Appearance", value: "Dark", kind: .readOnly)])
        #expect(tool.confirmationRequest(for: ToolArguments(["dark": false])).fields.first?.value == "Light")
        #expect(tool.riskLevel == .write && tool.requiredPermissions == [.automationSystemEvents] && tool.category == .system)
    }

    /// A refused Apple Event names Automation: System Events, so the chat offers "Open Settings".
    @Test func aRefusalNamesThePermission() async throws {
        let refused = MockAppleScriptRunner { _, _ in throw OsascriptFailure.error(number: -1743, message: "Not authorized", app: .systemEvents) }
        await #expect(throws: ToolError.permissionDenied(.automationSystemEvents)) {
            try await SetAppearanceTool(context: Self.context(scripts: refused)).run(arguments: ToolArguments(["dark": true]))
        }
        #expect(AgentLoop.permissionNotice(for: .automationSystemEvents) == "Orbit is not allowed to control System Events.")
        let garbled = MockAppleScriptRunner(output: "ok")
        await #expect(throws: ToolError.failed("Orbit could not read System Events's answer.")) {
            try await SetAppearanceTool(context: Self.context(scripts: garbled)).run(arguments: ToolArguments(["dark": true]))
        }
        await #expect(throws: ToolError.unavailable("System Events is not available in this debug session (ORBIT_DEBUG_FILE_SCOPE is set without ORBIT_DEBUG_FAKE_PERSONAL_DATA).")) {
            try await SetAppearanceTool(context: SystemToolContext(shortcuts: MockShortcuts(),
                                                                   systemEvents: SystemEventsService(runner: DisabledAppleScriptRunner()),
                                                                   volume: MockAudioVolume()))
                .run(arguments: ToolArguments(["dark": true]))
        }
    }

    // MARK: set_volume

    @Test func theCardShowsLevelAndDeviceAndTheLevelCanBeEdited() async throws {
        let volume = MockAudioVolume()
        let tool = SetVolumeTool(context: Self.context(volume: volume))
        let prepared = try await tool.prepareForConfirmation(ToolArguments(["level": 40]))
        #expect(prepared == ToolArguments(["level": 40, "_device": "Test-Lautsprecher", "_device_id": "test-speakers",
                                           "_current_level": 50]))
        let request = tool.confirmationRequest(for: prepared)
        #expect(request.title == "Change volume" && request.confirmLabel == "Set")
        #expect(request.message == "Orbit sets the volume of your output device.")
        #expect(request.fields == [
            ConfirmationField(id: "level", label: "Volume (0 to 100)", value: "40", kind: .text),
            ConfirmationField(id: "_current_level", label: "Current", value: "50%", kind: .readOnly),
            ConfirmationField(id: "_device", label: "Output device", value: "Test-Lautsprecher", kind: .readOnly),
        ])
        #expect(volume.changes.isEmpty, "preparing changes nothing")
        // The device, its identifier and the current level are no arguments (tool-private): edits never set them,
        // they stay for the run, and the schema checks only the parameters.
        let edited = tool.applyingEdits(["level": "55", "_device": "x"], to: prepared)
        #expect(edited == ToolArguments(["level": "55", "_device": "Test-Lautsprecher", "_device_id": "test-speakers",
                                         "_current_level": 50]))
        #expect(tool.inputSchema.validate(.object(edited.parameters.values)).isValid)
    }

    @Test func setsTheLevel() async throws {
        let volume = MockAudioVolume()
        let result = try await SetVolumeTool(context: Self.context(volume: volume))
            .run(arguments: ToolArguments(["level": 40, "_device": "Test-Lautsprecher"]))
        #expect(volume.changes == [.init(volume: 0.4, muted: nil)])
        #expect(result.text == "The volume of the output device \"Test-Lautsprecher\" is now at 40 % (before: 50 %).")
        #expect(result.card == .info(InfoItem(title: "Volume: 40%", detail: "Test-Lautsprecher", systemImage: "speaker.wave.2.fill")))
        #expect(result.summary == "Volume set to 40%")
    }

    /// A level above 0 unmutes a muted device, unless muting was asked for; the card says so.
    @Test func aLevelUnmutes() async throws {
        let muted = AudioOutputDevice(name: "Kopfhörer", volume: 0.2, isMuted: true, canSetVolume: true, canMute: true)
        let volume = MockAudioVolume(muted)
        let tool = SetVolumeTool(context: Self.context(volume: volume))
        let prepared = try await tool.prepareForConfirmation(ToolArguments(["level": 30]))
        #expect(prepared["muted"] == false)
        #expect(tool.confirmationRequest(for: prepared).fields.map(\.value) == ["30", "20% (muted)", "On", "Kopfhörer"])
        let result = try await tool.run(arguments: prepared)
        #expect(volume.changes == [.init(volume: 0.3, muted: false)])
        #expect(result.text == "The volume of the output device \"Kopfhörer\" is now at 30 %, unmuted (before: 20 %).")

        let stayMuted = try await tool.prepareForConfirmation(ToolArguments(["level": 30, "muted": true]))
        #expect(stayMuted["muted"] == true)
        let zero = try await tool.prepareForConfirmation(ToolArguments(["level": 0]))
        #expect(zero["muted"] == nil, "0 does not unmute")
    }

    @Test func muting() async throws {
        let volume = MockAudioVolume()
        let tool = SetVolumeTool(context: Self.context(volume: volume))
        let prepared = try await tool.prepareForConfirmation(ToolArguments(["muted": true]))
        let request = tool.confirmationRequest(for: prepared)
        #expect(request.message == "Orbit mutes the sound.")
        #expect(request.fields.map(\.id) == ["muted", "_device"])
        let result = try await tool.run(arguments: prepared)
        #expect(volume.changes == [.init(volume: nil, muted: true)])
        #expect(result.text == "The volume of the output device \"Test-Lautsprecher\" is now muted.")
        #expect(result.card == .info(InfoItem(title: "Sound off", detail: "Test-Lautsprecher", systemImage: "speaker.slash.fill")))
        #expect(result.summary == "Sound muted")
    }

    /// D4: a device without volume control is refused before the card: nothing to confirm.
    @Test func aDeviceWithoutVolumeControlIsRefused() async throws {
        let volume = MockAudioVolume(MockAudioVolume.hdmi)
        let tool = SetVolumeTool(context: Self.context(volume: volume))
        await #expect(throws: ToolError.failed("The current output device \"Test-Monitor (HDMI)\" does not let macOS change its volume (e.g. an HDMI or digital output). Nothing changed; the user can change it on the device itself.")) {
            try await tool.prepareForConfirmation(ToolArguments(["level": 40]))
        }
        await #expect(throws: ToolError.failed("The current output device \"Test-Monitor (HDMI)\" cannot be muted by macOS. Nothing changed.")) {
            try await tool.prepareForConfirmation(ToolArguments(["muted": true]))
        }
        #expect(volume.changes.isEmpty)
    }

    @Test func badRequests() async throws {
        let tool = SetVolumeTool(context: Self.context())
        await #expect(throws: ToolError.invalidArgument("Give 'level' (0 to 100), 'change' (e.g. 15 for louder, -15 for quieter) or 'muted'. The current volume of the output device \"Test-Lautsprecher\" is 50 %.")) {
            try await tool.prepareForConfirmation(ToolArguments())
        }
        await #expect(throws: ToolError.invalidArgument("'level' must be between 0 and 100.")) {
            try await tool.prepareForConfirmation(ToolArguments(["level": 140]))
        }
        #expect(!tool.inputSchema.validate(["level": 140]).isValid, "the schema stops it first")
        await #expect(throws: ToolError.unavailable("Changing the volume is not available in this debug session (ORBIT_DEBUG_FILE_SCOPE is set without ORBIT_DEBUG_FAKE_PERSONAL_DATA).")) {
            try await SetVolumeTool(context: SystemToolContext(shortcuts: MockShortcuts(),
                                                              systemEvents: SystemEventsService(runner: MockAppleScriptRunner()),
                                                              volume: UnavailableAudioVolume()))
                .prepareForConfirmation(ToolArguments(["level": 10]))
        }
    }

    // MARK: Louder and quieter (UX-1)

    /// "Lauter"/"Leiser" (louder, quieter): a change from the current level; the card shows both, nobody has to ask for a number.
    @Test func louderAndQuieterChangeTheCurrentLevel() async throws {
        let volume = MockAudioVolume()
        let tool = SetVolumeTool(context: Self.context(volume: volume))
        let louder = try await tool.prepareForConfirmation(ToolArguments(["change": 15]))
        #expect(louder["level"] == 65 && louder["change"] == nil, "the card shows the level that will be set")
        #expect(tool.confirmationRequest(for: louder).fields.map { "\($0.label)=\($0.value)" }
            == ["Volume (0 to 100)=65", "Current=50%", "Output device=Test-Lautsprecher"])
        let result = try await tool.run(arguments: louder)
        #expect(volume.changes == [.init(volume: 0.65, muted: nil)])
        #expect(result.text == "The volume of the output device \"Test-Lautsprecher\" is now at 65 % (before: 50 %).")

        #expect(try await tool.prepareForConfirmation(ToolArguments(["change": -15]))["level"] == 50, "from the new level")
        #expect(try await tool.prepareForConfirmation(ToolArguments(["change": 80]))["level"] == 100, "at most 100")
        #expect(try await tool.prepareForConfirmation(ToolArguments(["change": -100]))["level"] == 0)
        #expect(tool.inputSchema.jsonValue["properties"]?["change"]?["minimum"] == -100)
        #expect(tool.description.contains("For \"louder\" (\"lauter\") or \"quieter\" (\"leiser\") give 'change' instead"))
        #expect(tool.description.contains("so do not ask the user for a number"))
    }

    /// V5-3: "Quieter" on a muted output keeps it muted, and the card says so ("Current: 50% (muted)",
    /// "Sound: Off"); only the level it has once unmuted goes down. "Louder" unmutes it, as a level does.
    @Test func quieterKeepsAMutedDeviceMuted() async throws {
        let muted = AudioOutputDevice(name: "Kopfhörer", volume: 0.5, isMuted: true, canSetVolume: true, canMute: true,
                                      identifier: "phones")
        let volume = MockAudioVolume(muted)
        let tool = SetVolumeTool(context: Self.context(volume: volume))
        let quieter = try await tool.prepareForConfirmation(ToolArguments(["change": -15]))
        #expect(quieter["level"] == 35 && quieter["muted"] == true)
        #expect(tool.confirmationRequest(for: quieter).fields.map { "\($0.label)=\($0.value)" }
            == ["Volume (0 to 100)=35", "Current=50% (muted)", "Sound=Off", "Output device=Kopfhörer"])
        let result = try await tool.run(arguments: quieter)
        #expect(volume.changes == [.init(volume: 0.35, muted: true)])
        #expect(volume.device.isMuted == true, "still silent")
        #expect(result.text == "The volume of the output device \"Kopfhörer\" is now at 35 % and muted (before: 50 %).")
        #expect(result.summary == "Volume set to 35%, sound off")
        #expect(result.card == .info(InfoItem(title: "Sound off", detail: "Kopfhörer", systemImage: "speaker.slash.fill")))

        // A level edited on that card stays muted too, as the card said.
        let edited = try await tool.prepareForConfirmation(tool.applyingEdits(["level": "20"], to: quieter))
        #expect(edited["level"] == 20 && edited["muted"] == true)

        let louder = try await SetVolumeTool(context: Self.context(volume: MockAudioVolume(muted)))
            .prepareForConfirmation(ToolArguments(["change": 15]))
        #expect(louder["level"] == 65 && louder["muted"] == false, "louder unmutes")
        #expect(tool.confirmationRequest(for: louder).fields.map(\.value) == ["65", "50% (muted)", "On", "Kopfhörer"])
        #expect(tool.description.contains("while a negative 'change' keeps it muted"))
    }

    @Test func aChangeNeedsAReadableLevelAndNoLevel() async throws {
        let tool = SetVolumeTool(context: Self.context())
        await #expect(throws: ToolError.invalidArgument("Give either 'level' or 'change', not both.")) {
            try await tool.prepareForConfirmation(ToolArguments(["level": 40, "change": 15]))
        }
        let unreadable = AudioOutputDevice(name: "USB-Box", volume: nil, isMuted: false, canSetVolume: true, canMute: true,
                                           identifier: "usb")
        await #expect(throws: ToolError.invalidArgument("Orbit cannot read the current volume of the output device \"USB-Box\", so it cannot change it by 15 points. Give 'level' (0 to 100) instead.")) {
            try await SetVolumeTool(context: Self.context(volume: MockAudioVolume(unreadable)))
                .prepareForConfirmation(ToolArguments(["change": 15]))
        }
        await #expect(throws: ToolError.self) {
            try await SetVolumeTool(context: Self.context(volume: MockAudioVolume(MockAudioVolume.hdmi)))
                .prepareForConfirmation(ToolArguments(["change": 15]))
        }
    }

    // MARK: What is reported (SYS-1)

    /// Core Audio applies a change asynchronously: the result reports the level and muting that were set,
    /// not a read-back that may still be the old one.
    @Test func theResultReportsWhatWasSet() async throws {
        let volume = MockAudioVolume(appliesChangesLater: true)
        let tool = SetVolumeTool(context: Self.context(volume: volume))
        let result = try await tool.run(arguments: try await tool.prepareForConfirmation(ToolArguments(["level": 30])))
        #expect(volume.changes == [.init(volume: 0.3, muted: nil)])
        #expect(result.text == "The volume of the output device \"Test-Lautsprecher\" is now at 30 % (before: 50 %).")
        #expect(result.card == .info(InfoItem(title: "Volume: 30%", detail: "Test-Lautsprecher", systemImage: "speaker.wave.1.fill")))
        #expect(result.summary == "Volume set to 30%")

        let mute = try await tool.run(arguments: try await tool.prepareForConfirmation(ToolArguments(["muted": true])))
        #expect(mute.text == "The volume of the output device \"Test-Lautsprecher\" is now muted.")
        #expect(mute.summary == "Sound muted")
    }

    // MARK: The confirmed device (SEC-2)

    /// The card names the device; the run changes only that one, not headphones that became the output meanwhile.
    @Test func onlyTheDeviceTheCardNamedChanges() async throws {
        let volume = MockAudioVolume()
        let tool = SetVolumeTool(context: Self.context(volume: volume))
        let prepared = try await tool.prepareForConfirmation(ToolArguments(["level": 100]))
        #expect(prepared[SetVolumeTool.deviceIDKey] == "test-speakers")
        volume.switchTo(MockAudioVolume.headphones)
        await #expect(throws: ToolError.failed("The output device changed since the user saw the card: it is now \"Test-Kopfhörer\". Nothing changed. Ask the user again before you set the volume of this device.")) {
            try await tool.run(arguments: prepared)
        }
        #expect(volume.changes.isEmpty)

        // The device stayed: the change goes to it, by its identifier.
        volume.switchTo(MockAudioVolume.speakers)
        _ = try await tool.run(arguments: prepared)
        #expect(volume.changes == [.init(volume: 1, muted: nil)] && volume.targets == ["test-speakers"])
        // Without a card (never from the agent loop): the device it just checked.
        _ = try await tool.run(arguments: ToolArguments(["level": 20]))
        #expect(volume.targets == ["test-speakers", "test-speakers"])
    }

    @Test func levelsInPercent() {
        #expect(AudioVolumeLevel.percent(fromScalar: 0.404) == 40)
        #expect(AudioVolumeLevel.percent(fromScalar: 1.2) == 100 && AudioVolumeLevel.percent(fromScalar: -1) == 0)
        #expect(AudioVolumeLevel.scalar(fromPercent: 55) == 0.55 && AudioVolumeLevel.scalar(fromPercent: 300) == 1)
        let tool = SetVolumeTool(context: Self.context())
        #expect(tool.riskLevel == .write && tool.requiredPermissions.isEmpty, "Core Audio needs no permission")
    }
}

/// `set_appearance` and `set_volume` in the agent loop: nothing changes before the user confirmed.
@Suite("System settings in the agent loop")
@MainActor
struct SystemSettingsAgentTests {
    @Test func theAppearanceChangesOnlyAfterConfirmation() async throws {
        let scripts = MockAppleScriptRunner(output: #"{"dark":true,"changed":true}"#)
        let harness = AgentHarness(tools: SystemTools.all(context: SystemSettingToolsTests.context(scripts: scripts)),
                                   scripts: [MockScript.toolCalls([MockScript.call("a1", "set_appearance", ["dark": true])]),
                                             MockScript.answer("Dunkelmodus ist an.")])
        harness.agent.send("Mach den Dunkelmodus an")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        try await Task.sleep(for: .milliseconds(30))
        #expect(scripts.runs.isEmpty, "no Apple Event before the click")
        harness.agent.resolveConfirmation(try #require(harness.agent.pendingConfirmation).id, decision: .approved(edits: [:]))
        await harness.agent.waitUntilIdle()
        #expect(scripts.runs.map(\.script) == ["system-appearance"])
        #expect(harness.statuses.map(\.text) == ["Dark appearance turned on"])
        #expect(harness.cards.count == 1)
        harness.expectValidHistory()
    }

    /// SEC-2: AirPods connect while the card waits; the confirmed level never reaches them.
    @Test func aDeviceSwitchWhileTheCardWaitsChangesNothing() async throws {
        let volume = MockAudioVolume()
        let harness = AgentHarness(tools: SystemTools.all(context: SystemSettingToolsTests.context(volume: volume)),
                                   scripts: [MockScript.toolCalls([MockScript.call("v1", "set_volume", ["level": 100])]),
                                             MockScript.answer("Die Lautsprecher haben sich geändert.")])
        harness.agent.send("Mach die Lautsprecher ganz laut")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        let request = try #require(harness.agent.pendingConfirmation)
        #expect(request.fields.first { $0.id == SetVolumeTool.deviceKey }?.value == "Test-Lautsprecher")
        volume.switchTo(MockAudioVolume.headphones)
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: [:]))
        await harness.agent.waitUntilIdle()
        #expect(volume.changes.isEmpty)
        #expect(harness.confirmations.map(\.status) == [.failed])
        #expect(harness.result(for: "v1")?.content.hasPrefix("Error: The output device changed since the user saw the card: it is now \"Test-Kopfhörer\". Nothing changed.") == true)
        harness.expectValidHistory()
    }

    /// … also when the user edited the level: the check after the edit refuses, nothing runs.
    @Test func aDeviceSwitchBeforeAnEditedLevelChangesNothing() async throws {
        let volume = MockAudioVolume()
        let harness = AgentHarness(tools: SystemTools.all(context: SystemSettingToolsTests.context(volume: volume)),
                                   scripts: [MockScript.toolCalls([MockScript.call("v1", "set_volume", ["level": 100])]),
                                             MockScript.answer("Die Lautsprecher haben sich geändert.")])
        harness.agent.send("Mach die Lautsprecher ganz laut")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        volume.switchTo(MockAudioVolume.headphones)
        harness.agent.resolveConfirmation(try #require(harness.agent.pendingConfirmation).id, decision: .approved(edits: ["level": "90"]))
        await harness.agent.waitUntilIdle()
        #expect(volume.changes.isEmpty)
        #expect(harness.confirmations.map(\.status) == [.notRun])
        #expect(harness.statuses.map(\.text) == ["Failed"])
        #expect(harness.result(for: "v1")?.content
            == "Not run: the user edited the values and confirmed, but then the tool refused. Error: The output device changed since the user saw the card: it is now \"Test-Kopfhörer\". Nothing changed. Ask the user again before you set the volume of this device.")
    }

    /// V5-3: "Leiser" (quieter) while the output is muted: the card says the sound stays off, and confirming keeps it off.
    @Test func quieterWhileMutedStaysMuted() async throws {
        let volume = MockAudioVolume(AudioOutputDevice(name: "Kopfhörer", volume: 0.5, isMuted: true, canSetVolume: true,
                                                       canMute: true, identifier: "phones"))
        let harness = AgentHarness(tools: SystemTools.all(context: SystemSettingToolsTests.context(volume: volume)),
                                   scripts: [MockScript.toolCalls([MockScript.call("v1", "set_volume", ["change": -15])]),
                                             MockScript.answer("Leiser gestellt, der Ton bleibt aus.")])
        harness.agent.send("Leiser")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        let request = try #require(harness.agent.pendingConfirmation)
        #expect(request.fields.map { "\($0.label)=\($0.value)" }
            == ["Volume (0 to 100)=35", "Current=50% (muted)", "Sound=Off", "Output device=Kopfhörer"])
        harness.agent.resolveConfirmation(request.id, decision: .approved(edits: [:]))
        await harness.agent.waitUntilIdle()
        #expect(volume.changes == [.init(volume: 0.35, muted: true)])
        #expect(harness.confirmations.map(\.status) == [.approved])
        #expect(harness.statuses.map(\.text) == ["Volume set to 35%, sound off"])
        harness.expectValidHistory()
    }

    @Test func anEditedLevelIsChecked() async throws {
        let volume = MockAudioVolume()
        let harness = AgentHarness(tools: SystemTools.all(context: SystemSettingToolsTests.context(volume: volume)),
                                   scripts: [MockScript.toolCalls([MockScript.call("v1", "set_volume", ["level": 40])]),
                                             MockScript.answer("Erledigt.")])
        harness.agent.send("Lautstärke auf 40")
        #expect(await AgentHarness.eventually { harness.agent.pendingConfirmation != nil })
        harness.agent.resolveConfirmation(try #require(harness.agent.pendingConfirmation).id, decision: .approved(edits: ["level": "250"]))
        await harness.agent.waitUntilIdle()
        #expect(volume.changes.isEmpty)
        #expect(harness.confirmations.map(\.status) == [.notRun])

        let second = AgentHarness(tools: SystemTools.all(context: SystemSettingToolsTests.context(volume: volume)),
                                  scripts: [MockScript.toolCalls([MockScript.call("v1", "set_volume", ["level": 40])]),
                                            MockScript.answer("Erledigt.")])
        second.agent.send("Lautstärke auf 40")
        #expect(await AgentHarness.eventually { second.agent.pendingConfirmation != nil })
        second.agent.resolveConfirmation(try #require(second.agent.pendingConfirmation).id, decision: .approved(edits: ["level": "25"]))
        await second.agent.waitUntilIdle()
        #expect(volume.changes == [.init(volume: 0.25, muted: nil)], "the edited level")
        #expect(second.statuses.map(\.text) == ["Volume set to 25%"])
    }
}
