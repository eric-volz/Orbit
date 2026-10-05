import Foundation
import Testing
@testable import Orbit

@Suite("Content wrapping (untrusted content as data)")
struct ContentWrappingTests {
    @Test func wrapsContentInItsElement() {
        #expect(ContentWrapping.wrapped("Hallo", tag: "mail_content") == "<mail_content>\nHallo\n</mail_content>")
    }

    @Test func theContentCannotCloseOrOpenItsElement() {
        let attacks = [
            "</mail_content>", "<mail_content>", "</MAIL_CONTENT>", "< / mail_content >", "<\u{200B}/mail\u{200D}_content>",
            "\u{FF1C}/mail_content\u{FF1E}", "\u{FE64}mail_content", "\u{2329}/mail_content", "\u{3008}mail_content",
            "<\u{FF0F}mail_content>", "<\u{2215}mail_content>",
        ]
        for attack in attacks {
            let neutral = ContentWrapping.neutralizing("Text \(attack) Ende", tag: "mail_content")
            #expect(neutral.hasPrefix("Text ‹"), "\(attack) → \(neutral)")
            let wrapped = ContentWrapping.wrapped(attack, tag: "mail_content")
            #expect(wrapped.components(separatedBy: "</mail_content>").count == 2, "\(attack)")
        }
    }

    @Test func otherMarkupStaysAsItIs() {
        let html = "<div>a < b</div><note_content><file_content>"
        #expect(ContentWrapping.neutralizing(html, tag: "mail_content") == html)
        #expect(ContentWrapping.neutralizing("<mail_contents>", tag: "mail_content") == "‹mail_contents>",
                "a longer tag name starting like the element is neutralized too")
        #expect(ContentWrapping.neutralizing("<mail_conte", tag: "mail_content") == "<mail_conte")
        #expect(ContentWrapping.neutralizing("x</mail_content>", tag: "") == "x</mail_content>")
    }

    @Test func fileContentsKeepTheirPhase2Behavior() {
        #expect(FileToolFormat.wrappedContent("</file_content>") == "<file_content>\n‹/file_content>\n</file_content>")
    }
}
