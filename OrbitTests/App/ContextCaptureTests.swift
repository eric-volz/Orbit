import Foundation
import Testing
@testable import Orbit

/// The context chips when the panel opens (D5), on a capture the test sets,
/// never another app: when Orbit captures, when it drops a capture, and when
/// an open keeps the chips the user still has.
@Suite("Context chips when the panel opens")
@MainActor
struct ContextCaptureTests {
    typealias F = FrontmostContextTests

    struct Harness {
        let capture: ContextCapture
        let capturer: MockFrontmostContext
        let panelState: PanelState
        let settings: SettingsStore
        let announcer: RecordingAnnouncer
    }

    static var finderSelection: FrontmostContext {
        var context = FrontmostContext(app: F.finder)
        context.finderPaths = ["~/Documents/Angebot.pdf", "~/Documents/Rechnung.pdf"]
        context.finderSelectionCount = 2
        return context
    }

    static var selectedText: FrontmostContext {
        var context = FrontmostContext(app: F.textEdit)
        context.selectedText = "Lieferung bis Freitag"
        return context
    }

    private func harness(_ context: FrontmostContext = finderSelection, budget: Duration = .seconds(5)) -> Harness {
        let capturer = MockFrontmostContext(context)
        let panelState = PanelState()
        panelState.isVisible = true
        let settings = SettingsStore(defaults: AgentTestDefaults())
        let announcer = RecordingAnnouncer()
        let capture = ContextCapture(capturer: capturer, settings: settings, panelState: panelState, announcer: announcer,
                                     budget: budget)
        return Harness(capture: capture, capturer: capturer, panelState: panelState, settings: settings, announcer: announcer)
    }

    private func settled(_ harness: Harness) async -> Bool {
        await AgentHarness.eventually { !harness.capture.isCapturing }
    }

    @Test func anOpenTakesTheSelectionAsChips() async {
        let harness = harness()
        harness.capture.panelOpened()
        #expect(harness.capture.isCapturing)
        #expect(harness.panelState.attachments.isEmpty, "the panel appears at once, the chips follow")
        #expect(await settled(harness))
        #expect(harness.panelState.attachments.map(\.label) == ["With selection: Angebot.pdf and 1 more"])
        #expect(harness.capturer.captures == [.chips], "no window title for chips")
        #expect(harness.capture.lastOutcome == .chips && harness.capture.captureCount == 1)
        #expect(harness.announcer.announcements == ["Context added: With selection: Angebot.pdf and 1 more"])

        let text = self.harness(Self.selectedText)
        text.capture.panelOpened()
        #expect(await settled(text))
        #expect(text.panelState.attachments.map(\.label) == ["With selection: “Lieferung bis Freitag” (TextEdit)"])
    }

    @Test func noChipForTheAppAlone() async {
        let harness = harness(FrontmostContext(app: F.textEdit, windowTitle: "Angebot.rtf"))
        harness.capture.panelOpened()
        #expect(await settled(harness))
        #expect(harness.panelState.attachments.isEmpty)
        #expect(harness.capture.lastOutcome == .nothing)
        #expect(harness.announcer.announcements.isEmpty)
    }

    @Test func theSettingSwitchesItOff() async {
        let harness = harness()
        harness.settings.capturesSelectionOnOpen = false
        harness.capture.panelOpened()
        #expect(!harness.capture.isCapturing)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(harness.capturer.captures.isEmpty, "nothing is read")
        #expect(harness.panelState.attachments.isEmpty)
    }

    /// D5: chips appear when the capture finishes within its budget; otherwise it is dropped.
    @Test func aSlowCaptureIsDropped() async {
        let harness = harness(budget: .milliseconds(40))
        harness.capturer.delay(.seconds(2))
        harness.capture.panelOpened()
        #expect(await settled(harness))
        #expect(harness.panelState.attachments.isEmpty)
        #expect(harness.capture.lastOutcome == .dropped)
    }

    /// D5: late results are dropped if the user already sent the message or closed the panel.
    @Test func lateResultsAreDropped() async throws {
        let sent = harness()
        sent.capturer.delay(.milliseconds(100))
        sent.capture.panelOpened()
        sent.capture.messageSent()
        try await Task.sleep(for: .milliseconds(250))
        #expect(sent.panelState.attachments.isEmpty, "the message went without them")
        #expect(sent.capture.lastOutcome == .dropped && !sent.capture.isCapturing)

        let closed = harness()
        closed.capturer.delay(.milliseconds(100))
        closed.capture.panelOpened()
        closed.panelState.isVisible = false
        closed.capture.panelClosed()
        try await Task.sleep(for: .milliseconds(250))
        #expect(closed.panelState.attachments.isEmpty)

        // A capture that finishes while the panel is hidden (without a close report) is dropped too.
        let hidden = harness()
        hidden.capturer.delay(.milliseconds(50))
        hidden.capture.panelOpened()
        hidden.panelState.isVisible = false
        #expect(await settled(hidden))
        #expect(hidden.panelState.attachments.isEmpty)
    }

    /// D5: a new open replaces the previous chips unless the input still holds
    /// unsent text with chips the user kept.
    @Test func aNewOpenReplacesTheChips() async {
        let harness = harness(Self.selectedText)
        let stale = ContextAttachment(kind: .finderSelection(paths: ["~/alt.pdf"]), label: "Mit Auswahl: alt.pdf")
        harness.panelState.attachments = [stale]
        harness.capture.panelOpened()
        #expect(harness.panelState.attachments.isEmpty, "the old selection's chips go at once")
        #expect(await settled(harness))
        #expect(harness.panelState.attachments.map(\.label) == ["With selection: “Lieferung bis Freitag” (TextEdit)"])

        // Nothing selected now: the stale chips do not come back.
        let nothing = self.harness(FrontmostContext(app: F.textEdit))
        nothing.panelState.attachments = [stale]
        nothing.capture.panelOpened()
        #expect(await settled(nothing))
        #expect(nothing.panelState.attachments.isEmpty)
    }

    @Test func unsentTextWithKeptChipsStays() async {
        let harness = harness(Self.selectedText)
        let kept = ContextAttachment(kind: .finderSelection(paths: ["~/Angebot.pdf"]), label: "Mit Auswahl: Angebot.pdf")
        harness.panelState.attachments = [kept]
        harness.panelState.inputText = "Fass das zusammen"
        harness.capture.panelOpened()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(harness.capturer.captures.isEmpty, "nothing is captured: the user's chips stay")
        #expect(harness.panelState.attachments == [kept])

        // Text without chips: the selection is taken.
        let textOnly = self.harness(Self.selectedText)
        textOnly.panelState.inputText = "Fass das zusammen"
        textOnly.capture.panelOpened()
        #expect(await settled(textOnly))
        #expect(textOnly.panelState.attachments.count == 1)
        #expect(ContextCapture.replacesChips(current: [kept], inputText: "  \n"), "blank text counts as none")
        #expect(!ContextCapture.replacesChips(current: [kept], inputText: "a"))
        #expect(ContextCapture.replacesChips(current: [], inputText: "a"))
    }

    /// A second open while the first capture runs: only the newest counts.
    @Test func onlyTheNewestOpenCounts() async {
        let harness = harness(Self.selectedText)
        harness.capturer.delay(.milliseconds(80))
        harness.capture.panelOpened()
        harness.capturer.set(Self.finderSelection)
        harness.capturer.delay(nil)
        harness.capture.panelOpened()
        #expect(await settled(harness))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(harness.panelState.attachments.map(\.label) == ["With selection: Angebot.pdf and 1 more"])
        #expect(harness.capture.captureCount == 2)
    }

    @Test func theSettingIsOnByDefaultAndPersisted() {
        let defaults = AgentTestDefaults()
        let settings = SettingsStore(defaults: defaults)
        #expect(settings.capturesSelectionOnOpen)
        settings.capturesSelectionOnOpen = false
        #expect(!SettingsStore(defaults: defaults).capturesSelectionOnOpen)
    }
}
