#if DEBUG
import AppKit
import Testing
@testable import Orbit

@Suite("DebugKeyStroke")
struct DebugKeyStrokeTests {
    @Test func parsesEscape() throws {
        let stroke = try #require(DebugKeyStroke(spec: "escape"))
        #expect(stroke.keyCode == 53)
        #expect(stroke.characters == "\u{1B}")
        #expect(stroke.modifiers.isEmpty)
        #expect(DebugKeyStroke(spec: "esc") == stroke)
    }

    @Test func parsesCommandShortcuts() throws {
        let newChat = try #require(DebugKeyStroke(spec: "cmd-n"))
        #expect(newChat.keyCode == 45)
        #expect(newChat.characters == "n")
        #expect(newChat.charactersIgnoringModifiers == "n")
        #expect(newChat.modifiers == .command)

        let send = try #require(DebugKeyStroke(spec: "cmd-return"))
        #expect(send.keyCode == 36)
        #expect(send.characters == "\r")
        #expect(send.modifiers == .command)
    }

    @Test(arguments: [
        ("cmd-1", UInt16(18)), ("cmd-2", 19), ("cmd-3", 20), ("cmd-4", 21), ("cmd-5", 23),
        ("cmd-6", 22), ("cmd-7", 26), ("cmd-8", 28), ("cmd-9", 25),
    ])
    func parsesCommandDigits(spec: String, keyCode: UInt16) throws {
        let stroke = try #require(DebugKeyStroke(spec: spec))
        #expect(stroke.keyCode == keyCode)
        #expect(stroke.characters == String(spec.last!))
        #expect(stroke.modifiers == .command)
    }

    @Test func shiftProducesUppercaseAndBackTab() throws {
        let redo = try #require(DebugKeyStroke(spec: "cmd-shift-z"))
        #expect(redo.characters == "Z")
        #expect(redo.charactersIgnoringModifiers == "Z")
        #expect(redo.modifiers == [.command, .shift])

        let backTab = try #require(DebugKeyStroke(spec: "shift-tab"))
        #expect(backTab.characters == "\u{19}")
    }

    @Test func arrowsCarryFunctionAndNumericPadFlags() throws {
        let up = try #require(DebugKeyStroke(spec: "up"))
        #expect(up.keyCode == 126)
        #expect(up.characters == "\u{F700}")
        #expect(up.modifiers == [.function, .numericPad])
        let down = try #require(DebugKeyStroke(spec: "Down"))
        #expect(down.keyCode == 125)
    }

    @Test func controlLettersProduceControlCharacters() throws {
        let stroke = try #require(DebugKeyStroke(spec: "ctrl-a"))
        #expect(stroke.characters == "\u{01}")
        #expect(stroke.charactersIgnoringModifiers == "a")
        #expect(stroke.modifiers == .control)
    }

    @Test(arguments: ["", "cmd-", "hyper-x", "cmd-shift", "f13", "cmd--"])
    func rejectsUnknownSpecs(spec: String) {
        #expect(DebugKeyStroke(spec: spec) == nil)
    }

    @Test @MainActor func createsKeyEvents() throws {
        let stroke = try #require(DebugKeyStroke(spec: "cmd-v"))
        let event = try #require(stroke.event(.keyDown, windowNumber: 0, timestamp: 1))
        #expect(event.type == .keyDown)
        #expect(event.keyCode == 9)
        #expect(event.charactersIgnoringModifiers == "v")
        #expect(event.modifierFlags.contains(.command))
    }
}

@Suite("SnapshotInspector")
struct SnapshotInspectorTests {
    private func pixels(_ count: Int, _ rgba: (UInt8, UInt8, UInt8, UInt8)) -> [UInt8] {
        Array((0..<count).flatMap { _ in [rgba.0, rgba.1, rgba.2, rgba.3] })
    }

    @Test func transparentIsBlank() {
        #expect(SnapshotInspector.isBlank(rgba: pixels(100, (0, 0, 0, 0))))
        #expect(SnapshotInspector.isBlank(rgba: []))
    }

    @Test func uniformOpaqueIsBlank() {
        #expect(SnapshotInspector.isBlank(rgba: pixels(100, (240, 240, 240, 255))))
    }

    @Test func mostlyTransparentWithTextIsBlank() {
        // Text drawn without the material behind it: the panel background is missing.
        let rendering = pixels(80, (0, 0, 0, 0)) + pixels(20, (20, 20, 20, 255))
        #expect(SnapshotInspector.isBlank(rgba: rendering))
    }

    @Test func opaqueContentIsNotBlank() {
        let rendering = pixels(80, (236, 236, 236, 255)) + pixels(20, (20, 20, 20, 255))
        #expect(!SnapshotInspector.isBlank(rgba: rendering))
    }

    @Test func checksCGImages() throws {
        let width = 8, height = 8
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let empty = try #require(context.makeImage())
        #expect(SnapshotInspector.isBlank(empty))
        context.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let content = try #require(context.makeImage())
        #expect(!SnapshotInspector.isBlank(content))
    }
}

@Suite("DebugAutomation protocol")
struct DebugProtocolTests {
    @Test func parsesRequests() {
        let request = DebugRequest(userInfo: ["command": "type", "argument": "Hallo Welt", "replyID": "42"])
        #expect(request == DebugRequest(command: "type", argument: "Hallo Welt", replyID: "42"))
        #expect(DebugRequest(userInfo: ["command": "state", "replyID": "1"])?.argument == nil)
        #expect(DebugRequest(userInfo: ["command": "state"]) == nil)
        #expect(DebugRequest(userInfo: nil) == nil)
    }

    @Test @MainActor func summarizesChatItems() {
        let long = String(repeating: "x", count: 300)
        let user = DebugAutomation.summary(of: ChatItem(kind: .user(text: "Hallo", attachments: [])))
        #expect(user["kind"] == "user")
        #expect(user["text"] == "Hallo")
        let assistant = DebugAutomation.summary(of: ChatItem(kind: .assistant(text: long, isStreaming: true)))
        #expect(assistant["kind"] == "assistant")
        #expect(assistant["text"]?.stringValue?.count == 200)
        #expect(assistant["streaming"] == .bool(true))
        let card = DebugAutomation.summary(of: ChatItem(kind: .card(.files([]))))
        #expect(card["text"] == "files(0)")
        let notice = DebugAutomation.summary(of: ChatItem(kind: .notice(Notice(style: .error, message: "Fehler"))))
        #expect(notice["kind"] == "notice")
        #expect(notice["style"] == "error")
        #expect(notice["action"] == nil)
        let permission = DebugAutomation.summary(of: ChatItem(kind: .notice(Notice(
            style: .info, message: "Orbit is not allowed to control Mail.", action: .openPermissionSettings))))
        #expect(permission["action"] == "openPermissionSettings")
        #expect(permission["secondaryAction"] == nil)
        let twoButtons = DebugAutomation.summary(of: ChatItem(kind: .notice(Notice(
            style: .error, message: "Claude Code ist nicht angemeldet.", action: .signIn, secondaryAction: .retry))))
        #expect(twoButtons["action"] == "signIn")
        #expect(twoButtons["secondaryAction"] == "retry")
    }

    /// UX-1: the E2E run reads whether the panel stayed up for Mail's reply window.
    @Test @MainActor func summarizesTheKeyboardHandoff() {
        var handoff = KeyboardHandoff()
        #expect(DebugAutomation.summary(of: handoff) == ["phase": "idle", "app": .null])
        let id = handoff.begin(to: "com.apple.mail", now: Date())
        #expect(DebugAutomation.summary(of: handoff) == ["phase": "opening", "app": "com.apple.mail"])
        handoff.end(id, opened: true, now: Date())
        #expect(DebugAutomation.summary(of: handoff)["phase"] == "opened")
        handoff.keepPanelVisible()
        #expect(DebugAutomation.summary(of: handoff)["phase"] == "keptVisible")
    }

    @Test @MainActor func summarizesInstantResults() {
        let summary = DebugAutomation.summary(of: SearchLayout.groups(
            apps: [SearchResult(id: "a", kind: .app(url: URL(fileURLWithPath: "/Applications/Mail.app")), title: "Mail", subtitle: "Programm")],
            files: [SearchResult(id: "f", kind: .file(url: URL(fileURLWithPath: "/tmp/a.pdf")), title: "a.pdf", subtitle: "/tmp")],
            contacts: [SearchResult(id: "c", kind: .contact(identifier: "1"), title: "Marie")]))
        #expect(summary == [
            ["group": "apps", "title": "Mail", "subtitle": "Programm"],
            ["group": "files", "title": "a.pdf", "subtitle": "/tmp"],
            ["group": "contacts", "title": "Marie"],
        ])
    }
}

@Suite("DebugAutomation: permissions")
@MainActor
struct DebugPermissionStateTests {
    @Test func reportsThePermissionsAsRead() async {
        let manager = PermissionManager(access: MockPermissionAccess([.automationMail: .denied]),
                                        permissions: [.automationMail, .contacts])
        #expect(DebugAutomation.summary(of: manager) == ["automationMail": "unread", "contacts": "unread"])
        await manager.refresh()
        #expect(DebugAutomation.summary(of: manager) == ["automationMail": "denied", "contacts": "granted"])
    }

    @Test func knowsTheOnboardingCommands() {
        for command in ["open-onboarding", "close-onboarding", "snapshot-onboarding"] {
            #expect(DebugAutomation.commandNames.contains(command))
        }
    }
}

@Suite("DebugAutomation: Quick Look state")
@MainActor
struct DebugQuickLookStateTests {
    @Test func reportsThePreviewWithoutFileNames() {
        let panel = FakeQuickLookPanel()
        let quickLook = QuickLookController(panel: panel)
        #expect(DebugAutomation.summary(of: quickLook) == ["visible": false, "hasKeyboard": false, "index": .null, "count": 0])
        quickLook.show(source: UUID(), urls: [URL(fileURLWithPath: "/tmp/a.pdf"), URL(fileURLWithPath: "/tmp/b.pdf")], index: 1)
        panel.isKey = true
        #expect(DebugAutomation.summary(of: quickLook) == ["visible": true, "hasKeyboard": true, "index": 1, "count": 2])
    }
}

@Suite("DebugChannel")
struct DebugChannelTests {
    @Test func theTokenFileIsPrivateAndNewPerLaunch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-channel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = DebugChannel(directory: directory)
        let first = try channel.createToken()
        #expect(first.count == 64)
        let attributes = try FileManager.default.attributesOfItem(atPath: channel.tokenURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let second = try channel.createToken()
        #expect(second != first)
        #expect(try String(contentsOf: channel.tokenURL, encoding: .utf8) == second)
    }

    @Test func onlyTheExactTokenMatches() {
        #expect(DebugChannel.matches("abc", "abc"))
        #expect(!DebugChannel.matches("abd", "abc"))
        #expect(!DebugChannel.matches("ab", "abc"))
        #expect(!DebugChannel.matches("", ""), "no token set means nothing matches")
    }

    @Test func repliesGoToPrivateFilesNamedByUUID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-channel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let channel = DebugChannel(directory: directory)
        _ = try channel.createToken()
        #expect(channel.replyURL(for: "../../etc/passwd") == nil)
        let id = UUID().uuidString
        try channel.writeReply(Data("{}".utf8), for: id)
        let url = try #require(channel.replyURL(for: id))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func snapshotsOnlyReplacePNGFilesInTemporaryOrDataFolders() throws {
        let data = URL(fileURLWithPath: "/Users/test/Library/Application Support/Orbit", isDirectory: true)
        let temp = NSTemporaryDirectory()
        #expect(DebugChannel.isAllowedSnapshotPath(temp + "orbit-\(UUID().uuidString).png", dataDirectory: data))
        #expect(DebugChannel.isAllowedSnapshotPath("/private/tmp/x/panel.png", dataDirectory: data))
        #expect(DebugChannel.isAllowedSnapshotPath(data.path + "/shots/panel.PNG", dataDirectory: data))
        #expect(!DebugChannel.isAllowedSnapshotPath(temp + "panel.txt", dataDirectory: data))
        #expect(!DebugChannel.isAllowedSnapshotPath(NSHomeDirectory() + "/Documents/Steuer.png", dataDirectory: data))
        #expect(!DebugChannel.isAllowedSnapshotPath("/tmp/../Users/test/Documents/x.png", dataDirectory: data))

        // An existing file is replaced only if it is a PNG.
        let existing = temp + "orbit-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: existing) }
        try Data("not a png".utf8).write(to: URL(fileURLWithPath: existing))
        #expect(!DebugChannel.isAllowedSnapshotPath(existing, dataDirectory: data))
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0]).write(to: URL(fileURLWithPath: existing))
        #expect(DebugChannel.isAllowedSnapshotPath(existing, dataDirectory: data))
    }

    @Test func requestsCarryTheToken() throws {
        let request = try #require(DebugRequest(userInfo: ["command": "state", "replyID": "r", "token": "t"]))
        #expect(request.token == "t")
        #expect(DebugRequest(userInfo: ["command": "state", "replyID": "r"])?.token == "")
    }
}

@Suite("Outside clicks")
struct OutsideClickTests {
    @Test func textInputHelpersDoNotCloseThePanel() {
        #expect(PanelController.isTextInputHelper(bundleIdentifier: "com.apple.CharacterPaletteIM",
                                                  bundlePath: "/System/Library/Input Methods/CharacterPalette.app"))
        #expect(PanelController.isTextInputHelper(bundleIdentifier: "com.apple.inputmethod.Kotoeri.RomajiTyping", bundlePath: nil))
        #expect(PanelController.isTextInputHelper(bundleIdentifier: "com.apple.TextInputUI.xpc.CursorUIViewService", bundlePath: nil))
        #expect(!PanelController.isTextInputHelper(bundleIdentifier: "com.apple.finder", bundlePath: "/System/Library/CoreServices/Finder.app"))
        #expect(!PanelController.isTextInputHelper(bundleIdentifier: nil, bundlePath: nil))
    }
}
#endif
