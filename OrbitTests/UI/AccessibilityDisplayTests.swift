import AppKit
import SwiftUI
import Testing
@testable import Orbit

/// macOS's display options (System Settings > Accessibility > Display), what
/// VoiceOver reads of states shown by a symbol or a color, and keyboard paths
/// (D3). Windows here are never ordered in.
@MainActor
@Suite("Accessibility display options")
struct AccessibilityDisplayTests {
    // MARK: Reduce Motion

    /// The panel's height change is animated; with Reduce Motion it takes the new height at once.
    @Test func reduceMotionResizesThePanelAtOnce() {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: 0, width: 720, height: 58), styleMask: [.borderless],
                              backing: .buffered, defer: true)
        let animator = PanelFrameAnimator(window: window)
        let target = CGRect(x: -20_000, y: 0, width: 720, height: 400)
        animator.reducesMotion = { true }
        animator.animate(to: target)
        #expect(window.frame == target && !animator.isAnimating)

        animator.reducesMotion = { false }
        animator.animate(to: CGRect(x: -20_000, y: 0, width: 720, height: 120))
        #expect(animator.isAnimating, "animated without the option")
        animator.finish()
        #expect(window.frame.height == 120)
    }

    /// A11Y-5: the note under the input changes the height above the chat or the results; with Reduce Motion
    /// it comes and goes at once instead of sliding them by its height.
    @Test func reduceMotionShowsTheInputHintAtOnce() {
        let hints = InputHintPresenter(announcer: RecordingAnnouncer())
        hints.reducesMotion = { true }
        #expect(hints.animation == nil)
        hints.show(.stillRunning)
        #expect(hints.hint == .stillRunning)
        hints.hide()
        #expect(hints.hint == nil)

        hints.reducesMotion = { false }
        #expect(hints.animation == .easeOut(duration: 0.15), "animated without the option")
    }

    // MARK: Reduce Transparency and Increase Contrast

    @Test func theDisplayOptionsChangeThePanelsBackgroundAndEdge() {
        // Never ordered front.
        let panel = OrbitPanel(rootView: EmptyView())
        panel.applyDisplayOptions(AccessibilityDisplayOptions())
        #expect(!panel.hasOpaqueBackground, "the material shows")
        panel.applyDisplayOptions(AccessibilityDisplayOptions(reduceTransparency: true))
        #expect(panel.hasOpaqueBackground, "Reduce Transparency: opaque")
        panel.applyDisplayOptions(AccessibilityDisplayOptions(increaseContrast: true))
        #expect(!panel.hasOpaqueBackground && panel.displayOptions.increaseContrast)
    }

    @Test func increaseContrastDrawsClearEdges() {
        let hairline = PanelBorderView.edge(isDark: true, increasedContrast: false, backingScale: 2)
        let clear = PanelBorderView.edge(isDark: true, increasedContrast: true, backingScale: 2)
        #expect(hairline.width == 0.5 && clear.width == 1)
        #expect(clear.alpha > hairline.alpha * 3)
        #expect(PanelBorderView.edge(isDark: false, increasedContrast: true, backingScale: 1).alpha >= 0.5)
        #expect(Theme.cardStrokeOpacity(increasedContrast: true) >= 5 * Theme.cardStrokeOpacity(increasedContrast: false))
        #expect(PhotoGridLayout.edge(isSelected: false, isFocused: false, increasedContrast: true, differentiateWithoutColor: false)
            == (1, Theme.increasedContrastEdgeOpacity))
        #expect(PhotoGridLayout.edge(isSelected: false, isFocused: false, increasedContrast: false, differentiateWithoutColor: false)
            == (0.5, 0.06))
    }

    // MARK: Differentiate Without Color

    /// Which row has the keyboard is told by more than the accent color.
    @Test func theSelectionWithTheKeyboardIsOutlined() {
        #expect(!Theme.outlinesSelection(isFocused: true, increasedContrast: false, differentiateWithoutColor: false))
        #expect(Theme.outlinesSelection(isFocused: true, increasedContrast: false, differentiateWithoutColor: true))
        #expect(!Theme.outlinesSelection(isFocused: false, increasedContrast: false, differentiateWithoutColor: true),
                "the outline itself tells the keyboard's row")
        #expect(Theme.outlinesSelection(isFocused: false, increasedContrast: true, differentiateWithoutColor: false))
        // A tile without the keyboard has a thinner ring.
        let focused = PhotoGridLayout.edge(isSelected: true, isFocused: true, increasedContrast: false, differentiateWithoutColor: true)
        let unfocused = PhotoGridLayout.edge(isSelected: true, isFocused: false, increasedContrast: false, differentiateWithoutColor: true)
        #expect(focused.width > unfocused.width)
        #expect(PhotoGridLayout.edge(isSelected: true, isFocused: false, increasedContrast: false, differentiateWithoutColor: false).width
            == focused.width, "unchanged without the option")
    }

    @Test func anOverdueReminderIsNotToldByItsColorAlone() {
        let now = FlexibleDate.parse("2026-10-05T12:00:00+02:00")!.date
        let overdue = ReminderItem(id: "r1", title: "Telekom zahlen", due: FlexibleDate.parse("2026-10-04T09:00:00+02:00")!.date,
                                   dueHasTime: true, isCompleted: false, listName: "Erinnerungen")
        let calendar = Calendar.berlin
        let locale = Locale(identifier: "de_DE")
        #expect(ReminderCardFormat.details(for: overdue, isOverdue: true, differentiateWithoutColor: true, calendar: calendar,
                                           locale: locale) == "Overdue · So. 4. Okt., 09:00 · Erinnerungen")
        #expect(ReminderCardFormat.details(for: overdue, isOverdue: true, differentiateWithoutColor: false, calendar: calendar,
                                           locale: locale) == "So. 4. Okt., 09:00 · Erinnerungen")
        // VoiceOver's value of the row says it too (it said "Not completed" before).
        #expect(ReminderCardFormat.state(of: overdue, now: now, calendar: calendar) == "Overdue")
        var done = overdue
        done.isCompleted = true
        #expect(ReminderCardFormat.state(of: done, now: now, calendar: calendar) == "Completed")
        var later = overdue
        later.due = FlexibleDate.parse("2026-10-06T09:00:00+02:00")!.date
        #expect(ReminderCardFormat.state(of: later, now: now, calendar: calendar) == "Not completed")
    }

    @Test func theCurrentOnboardingStepIsWiderWithoutColor() {
        #expect(OnboardingStepIndicator.dotWidth(isCurrent: true, differentiateWithoutColor: true)
            > OnboardingStepIndicator.dotWidth(isCurrent: false, differentiateWithoutColor: true))
        #expect(OnboardingStepIndicator.dotWidth(isCurrent: true, differentiateWithoutColor: false)
            == OnboardingStepIndicator.dotWidth(isCurrent: false, differentiateWithoutColor: false))
    }

    // MARK: VoiceOver

    /// The notice's symbol tells errors and warnings apart on the screen; VoiceOver hears it in words.
    @Test func aNoticeSaysWhatItIs() {
        #expect(NoticeRow.accessibilityLabel(Notice(style: .error, message: "Der Server ist nicht erreichbar."))
            == "Error: Der Server ist nicht erreichbar.")
        #expect(NoticeRow.accessibilityLabel(Notice(style: .warning, message: "Die Unterhaltung ist zu lang."))
            == "Warning: Die Unterhaltung ist zu lang.")
        #expect(NoticeRow.accessibilityLabel(Notice(style: .info, message: "Canceled.")) == "Canceled.")
    }

    // MARK: Keyboard

    @Test func fileCardsRevealAndCopyThePathFromTheKeyboard() {
        #expect(FileCardKeyCommand(key: KeyEquivalent("R"), modifiers: [.command, .shift]) == .reveal)
        #expect(FileCardKeyCommand(key: KeyEquivalent("r"), modifiers: [.command, .shift]) == .reveal)
        #expect(FileCardKeyCommand(key: KeyEquivalent("c"), modifiers: [.command, .option]) == .copyPath)
        #expect(FileCardKeyCommand(key: KeyEquivalent("r"), modifiers: .command) == nil, "⌘R retries a failed answer")
        #expect(FileCardKeyCommand(key: KeyEquivalent("c"), modifiers: .command) == nil, "⌘C copies text")
        #expect(FileCardKeyCommand(key: KeyEquivalent("c"), modifiers: [.command, .option, .shift]) == nil)
        #expect(FileCardKeyCommand.reveal.shortcut == KeyboardShortcut("r", modifiers: [.command, .shift]))
    }

    /// "Copy Path" changes nothing on the screen: VoiceOver hears that it worked.
    @Test func copyingAPathIsAnnounced() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("orbit-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let announcer = RecordingAnnouncer()
        let coordinator = FileCardCoordinator(quickLook: nil, workspace: nil, pasteboard: pasteboard, announcer: announcer)
        coordinator.copyPath(FileItem(path: "/Users/orbit-test/Documents/a.pdf", name: "a.pdf"))
        #expect(pasteboard.string(forType: .string) == "/Users/orbit-test/Documents/a.pdf")
        #expect(announcer.announcements == ["Path copied"])
    }

    /// ⌘1 to ⌘5 choose a Settings tab, also without Full Keyboard Access.
    @Test func commandNumbersChooseASettingsTab() throws {
        #expect(SettingsTab.forShortcut(characters: "1", keyCode: 18, modifiers: .command) == .general)
        #expect(SettingsTab.forShortcut(characters: "4", keyCode: 21, modifiers: .command) == .permissions)
        #expect(SettingsTab.forShortcut(characters: "5", keyCode: 23, modifiers: .command) == .privacy)
        #expect(SettingsTab.forShortcut(characters: "3", keyCode: 85, modifiers: [.command, .numericPad]) == .tools, "keypad")
        #expect(SettingsTab.forShortcut(characters: "6", keyCode: 22, modifiers: .command) == nil)
        #expect(SettingsTab.forShortcut(characters: "2", keyCode: 19, modifiers: []) == nil)
        #expect(SettingsTab.forShortcut(characters: "2", keyCode: 19, modifiers: [.command, .option]) == nil)
        #expect(SettingsTab.forShortcut(characters: "a", keyCode: 0, modifiers: .command) == nil)

        _ = NSApplication.shared
        // Never ordered in.
        let window = SettingsWindow(contentRect: NSRect(x: -20_000, y: 0, width: 100, height: 100), styleMask: [.titled],
                                    backing: .buffered, defer: true)
        var chosen: [SettingsTab] = []
        window.selectTab = { chosen.append($0) }
        #expect(window.performKeyEquivalent(with: try Self.key("2", keyCode: 19)))
        #expect(chosen == [.model])
    }

    /// A11Y-2: on French and Belgian AZERTY, Czech and similar layouts the number row types "&", "é", "+", "ě" …
    /// without Shift: ⌘ (or ⇧⌘, which types the digit there) with its keys chooses the tabs too.
    @Test func commandNumbersChooseASettingsTabOnEveryLayout() throws {
        _ = NSApplication.shared
        // Never ordered in.
        let window = SettingsWindow(contentRect: NSRect(x: -20_000, y: 0, width: 100, height: 100), styleMask: [.titled],
                                    backing: .buffered, defer: true)
        var chosen: [SettingsTab] = []
        window.selectTab = { chosen.append($0) }
        for event in [try Self.key("&", keyCode: 18), try Self.key("é", keyCode: 19), try Self.key("\"", keyCode: 20),
                      try Self.key("+", keyCode: 18), try Self.key("ě", keyCode: 19),
                      try Self.key("4", keyCode: 21, modifiers: [.command, .shift]),
                      try Self.key("(", keyCode: 23)] {
            #expect(window.performKeyEquivalent(with: event))
        }
        #expect(chosen == [.general, .model, .tools, .general, .model, .permissions, .privacy])
        // ⌘ with a letter, or with ⌥: no tab.
        #expect(!window.performKeyEquivalent(with: try Self.key("a", keyCode: 0)))
        #expect(!window.performKeyEquivalent(with: try Self.key("&", keyCode: 18, modifiers: [.command, .option])))
        #expect(chosen.count == 7)
    }

    /// A11Y-2: in the panel, ⌘ with the number row's key opens that instant result on these layouts too:
    /// the key press reaches its views as the digit it stands for (`CommandNumberKey`).
    @Test func commandNumbersReachThePanelAsDigitsOnEveryLayout() throws {
        _ = NSApplication.shared
        // Never ordered in.
        let panel = OrbitPanel(rootView: EmptyView())
        let recorder = KeyRecorder()
        panel.contentView?.addSubview(recorder)
        #expect(panel.makeFirstResponder(recorder))

        panel.sendEvent(try Self.key("&", keyCode: 18))
        panel.sendEvent(try Self.key("ç", keyCode: 25))
        panel.sendEvent(try Self.key("2", keyCode: 19))
        panel.sendEvent(try Self.key("a", keyCode: 0))
        panel.sendEvent(try Self.key("&", keyCode: 18, modifiers: []))
        #expect(recorder.keysDown == ["1", "9", "2", "a", "&"], "only ⌘ with the number row stands for a digit")
        #expect(recorder.modifiers.first == .command)

        _ = panel.performKeyEquivalent(with: try Self.key("é", keyCode: 19))
        #expect(recorder.keyEquivalents == ["2"])
        #expect(CommandNumberKey.digitEvent(for: try Self.key("2", keyCode: 19)) == nil, "already a digit")
    }

    /// A key press with the characters a layout types for it (here with ⌘).
    private static func key(_ characters: String, keyCode: UInt16,
                            modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                                      keyCode: keyCode))
    }

    /// Records the key presses that reach it.
    private final class KeyRecorder: NSView {
        private(set) var keysDown: [String] = []
        private(set) var modifiers: [NSEvent.ModifierFlags] = []
        private(set) var keyEquivalents: [String] = []

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            keysDown.append(event.charactersIgnoringModifiers ?? "")
            modifiers.append(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            keyEquivalents.append(event.charactersIgnoringModifiers ?? "")
            return false
        }
    }
}

private extension Calendar {
    static var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }
}
