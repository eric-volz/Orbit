import AppKit
import Testing
@testable import Orbit

/// The clipboard service. The app writes the general pasteboard; these tests
/// write only private, named pasteboards, never the user's clipboard.
@Suite("Pasteboard")
@MainActor
struct PasteboardTests {
    @Test func theTextReplacesWhatWasThere() async throws {
        let name = NSPasteboard.Name("orbit-test-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: name)
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string, .rtf], owner: nil)
        pasteboard.setString("vorher", forType: .string)
        pasteboard.setData(Data(#"{\rtf1 vorher}"#.utf8), forType: .rtf)

        let text = "Hallo Lisa,\n\nDonnerstag um 14 Uhr passt mir. 👨‍👩‍👧\n\nErika"
        #expect(await SystemPasteboard(name: name).write(text))
        #expect(pasteboard.string(forType: .string) == text)
        #expect(pasteboard.data(forType: .rtf) == nil, "nothing of the old contents is left")
    }

    @Test func theAppWritesTheGeneralPasteboardTestsNever() async {
        // Only compared, never written here.
        #expect(SystemPasteboard.general.name == .general)
        #expect(await DisabledPasteboard().write("x") == false)
        let recording = RecordingPasteboard()
        #expect(await recording.write("a"))
        #expect(recording.texts == ["a"])
        #expect(await RecordingPasteboard(fails: true).write("b") == false)
    }
}
