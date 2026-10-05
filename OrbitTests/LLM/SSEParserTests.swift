import Foundation
import Testing
@testable import Orbit

@Suite("SSE parser")
struct SSEParserTests {
    /// Parses a whole stream, fed in chunks of `chunkSize` bytes (nil = at once).
    private func parse(_ text: String, chunkSize: Int? = nil, flush: Bool = true) -> [SSEEvent] {
        parse(bytes: Array(text.utf8), chunkSize: chunkSize, flush: flush)
    }

    private func parse(bytes: [UInt8], chunkSize: Int? = nil, flush: Bool = true) -> [SSEEvent] {
        var parser = SSEParser()
        var events: [SSEEvent] = []
        let size = max(1, chunkSize ?? bytes.count)
        for start in stride(from: 0, to: bytes.count, by: size) {
            events += parser.feed(bytes[start..<min(start + size, bytes.count)])
        }
        if flush {
            events += parser.flush()
        }
        return events
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func supportsAllLineEndings(newline: String) {
        let text = ["event: a", "data: 1", "", "data: 2", "", ""].joined(separator: newline)
        #expect(parse(text) == [SSEEvent(event: "a", data: "1"), SSEEvent(data: "2")])
    }

    @Test func mixedLineEndingsInOneStream() {
        let text = "data: 1\r\n\r\ndata: 2\n\ndata: 3\r\rdata: 4\r\n\n"
        #expect(parse(text).map(\.data) == ["1", "2", "3", "4"])
    }

    @Test func linesSplitAcrossChunksAtEveryPosition() {
        let text = "event: content_block_delta\r\ndata: {\"text\":\"Grüße 👋\"}\r\n\r\n: keep-alive\r\ndata: x\r\n\r\n"
        let expected = [SSEEvent(event: "content_block_delta", data: "{\"text\":\"Grüße 👋\"}"), SSEEvent(data: "x")]
        for chunkSize in 1...12 {
            #expect(parse(text, chunkSize: chunkSize) == expected, "chunk size \(chunkSize)")
        }
    }

    @Test func crlfSplitBetweenChunksIsOneLineEnding() {
        var parser = SSEParser()
        #expect(parser.feed(Array("data: a\r".utf8)).isEmpty)
        #expect(parser.feed(Array("\n".utf8)).isEmpty) // the LF of the CRLF, not a blank line
        #expect(parser.feed(Array("\r".utf8)) == [SSEEvent(data: "a")])
        #expect(parser.feed(Array("\ndata: b\n\n".utf8)) == [SSEEvent(data: "b")])
    }

    @Test func multiByteUTF8SplitAcrossChunks() {
        let text = "data: Grüße aus Köln, 5 € 👋🏽\n\n"
        let bytes = Array(text.utf8)
        for split in 1..<bytes.count {
            var parser = SSEParser()
            let events = parser.feed(bytes[..<split]) + parser.feed(bytes[split...])
            #expect(events == [SSEEvent(data: "Grüße aus Köln, 5 € 👋🏽")], "split at \(split)")
        }
    }

    @Test func commentLinesAreIgnored() {
        let text = ": this is a comment\ndata: a\n:another\n\n:\n\n"
        #expect(parse(text) == [SSEEvent(data: "a")])
    }

    @Test func multipleDataLinesAreJoinedWithNewline() {
        #expect(parse("data: first\ndata: second\ndata:\ndata: fourth\n\n") == [SSEEvent(data: "first\nsecond\n\nfourth")])
    }

    @Test func fieldWithoutColonHasEmptyValue() {
        #expect(parse("data\n\n") == [SSEEvent(data: "")])
        #expect(parse("data\ndata\n\n") == [SSEEvent(data: "\n")])
        #expect(parse("event\ndata: x\n\n") == [SSEEvent(data: "x")])
    }

    @Test func onlyOneLeadingSpaceIsStripped() {
        #expect(parse("data:  two spaces\n\n") == [SSEEvent(data: " two spaces")])
        #expect(parse("data:no space\n\n") == [SSEEvent(data: "no space")])
        #expect(parse("data: colon: inside\n\n") == [SSEEvent(data: "colon: inside")])
    }

    @Test func byteOrderMarkAtStartIsSkipped() {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let bytes = bom + Array("data: a\n\n".utf8)
        for chunkSize in 1...4 {
            #expect(parse(bytes: bytes, chunkSize: chunkSize) == [SSEEvent(data: "a")], "chunk size \(chunkSize)")
        }
    }

    @Test func byteOrderMarkLaterIsNotSkipped() {
        let bytes = Array("data: a\n\n".utf8) + [0xEF, 0xBB, 0xBF] + Array("data: b\n\n".utf8)
        // "\u{FEFF}data" is an unknown field name, so the second event has no data.
        #expect(parse(bytes: bytes) == [SSEEvent(data: "a")])
    }

    @Test func flushDispatchesEventWithoutFinalBlankLine() {
        #expect(parse("data: a\n\ndata: b\n", flush: false) == [SSEEvent(data: "a")])
        #expect(parse("data: a\n\ndata: b\n") == [SSEEvent(data: "a"), SSEEvent(data: "b")])
        #expect(parse("data: a\n\ndata: b") == [SSEEvent(data: "a"), SSEEvent(data: "b")])
        #expect(parse("event: x\ndata: c\r") == [SSEEvent(event: "x", data: "c")])
    }

    @Test func flushResetsTheParser() {
        var parser = SSEParser()
        _ = parser.feed(Array("id: 7\nevent: x\ndata: a".utf8))
        #expect(parser.flush() == [SSEEvent(event: "x", data: "a", id: "7")])
        #expect(parser.flush().isEmpty)
        #expect(parser.feed(Array("data: b\n\n".utf8)) == [SSEEvent(data: "b")])
    }

    @Test func eventsWithoutDataAreNotDispatched() {
        #expect(parse("event: ping\n\nevent: other\n\n").isEmpty)
        // The event type does not leak into the next event.
        #expect(parse("event: ping\n\ndata: a\n\n") == [SSEEvent(data: "a")])
    }

    @Test func lastEventIDPersistsUntilReset() {
        let text = "id: 1\ndata: a\n\ndata: b\n\nid\ndata: c\n\nid: bad\u{0}id\ndata: d\n\n"
        #expect(parse(text) == [
            SSEEvent(data: "a", id: "1"),
            SSEEvent(data: "b", id: "1"),
            SSEEvent(data: "c", id: nil),
            SSEEvent(data: "d", id: nil),
        ])
    }

    @Test func retryAndUnknownFieldsAreIgnored() {
        #expect(parse("retry: 3000\nfoo: bar\ndata: a\n\n") == [SSEEvent(data: "a")])
    }

    @Test func manyEventsInOneChunk() {
        let text = (1...50).map { "event: e\ndata: \($0)\n\n" }.joined()
        let events = parse(text)
        #expect(events.count == 50)
        #expect(events.last == SSEEvent(event: "e", data: "50"))
    }

    @Test func blankLinesBetweenEventsDoNotCreateEvents() {
        #expect(parse("\n\n\ndata: a\n\n\n\n").map(\.data) == ["a"])
    }

    @Test func invalidUTF8IsReplacedNotDropped() {
        let bytes = Array("data: a".utf8) + [0xFF] + Array("b\n\n".utf8)
        #expect(parse(bytes: bytes) == [SSEEvent(data: "a\u{FFFD}b")])
    }
}
