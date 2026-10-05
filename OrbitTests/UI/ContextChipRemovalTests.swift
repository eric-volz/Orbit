import Foundation
import SwiftUI
import Testing
@testable import Orbit

/// UX-3: the context chips can be removed without the mouse: ⌫ in the empty
/// input removes the last one, like a token in a token field, and VoiceOver
/// hears which one (the keyboard stays in the input). The key handling itself
/// runs in `RootViewKeyboardTests` (gated window tests).
@Suite("Context chips from the keyboard")
struct ContextChipRemovalTests {
    static let finder = ContextAttachment(kind: .finderSelection(paths: ["~/Documents/Angebot.pdf"]),
                                          label: "Mit Auswahl: Angebot.pdf")
    static let text = ContextAttachment(kind: .selectedText(text: "Lieferung bis Freitag", appName: "Mail"),
                                        label: "Mit Auswahl: „Lieferung bis Freitag“ (Mail)")

    @Test func backspaceInTheEmptyInputRemovesTheLastChip() {
        #expect(ContextChipRemoval.chipToRemove(inputText: "", attachments: [Self.finder, Self.text]) == Self.text)
        #expect(ContextChipRemoval.chipToRemove(inputText: "", attachments: [Self.finder]) == Self.finder)
    }

    @Test func withTextOrWithoutChipsBackspaceEditsTheText() {
        #expect(ContextChipRemoval.chipToRemove(inputText: "Was ist das", attachments: [Self.finder]) == nil)
        #expect(ContextChipRemoval.chipToRemove(inputText: " ", attachments: [Self.finder]) == nil, "⌫ deletes the space first")
        #expect(ContextChipRemoval.chipToRemove(inputText: "", attachments: []) == nil)
    }

    /// The Mac's ⌫ key arrives as DEL (U+007F), not as SwiftUI's `.delete` (backspace, U+0008), so the input listens
    /// for DEL too (the gated `RootViewKeyboardTests.backspaceRemovesTheLastChipFromTheEmptyInput` presses the key).
    @Test func theInputListensForTheMacsBackspaceKey() {
        #expect(InputBar.backspace.character.unicodeScalars.map(\.value) == [0x7F])
        #expect(KeyEquivalent.delete.character.unicodeScalars.map(\.value) == [0x08], "not the key's character")
    }

    @Test func voiceOverHearsWhichChipWasRemoved() {
        #expect(ContextChipRemoval.announcement(for: Self.text) == "Context removed: Mit Auswahl: „Lieferung bis Freitag“ (Mail)")
    }
}
