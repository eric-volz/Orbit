import Foundation

/// One Server-Sent Event from a `text/event-stream` response.
struct SSEEvent: Sendable, Hashable {
    /// The `event:` field; nil for events without one (the default type "message").
    var event: String?
    /// The event's `data:` lines, joined with "\n".
    var data: String
    /// The stream's last event ID. As in the WHATWG spec, an `id:` field persists
    /// for later events; nil when none was set or it was reset to empty.
    var id: String?

    init(event: String? = nil, data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Incremental, byte-level parser for Server-Sent Events, following the WHATWG
/// "event stream interpretation" rules.
///
/// Feed it the response body in chunks of any size: chunks may split lines, CRLF
/// pairs and multi-byte UTF-8 characters anywhere. Lines end with LF, CRLF or a
/// lone CR; a UTF-8 byte order mark at the start of the stream is skipped. Call
/// `flush()` when the stream has ended to dispatch an event that was not
/// terminated by a blank line.
///
/// Do not read SSE with `URLSession.AsyncBytes.lines`: it drops the empty lines
/// that terminate events.
struct SSEParser: Sendable {
    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let colon = UInt8(ascii: ":")
    private static let space = UInt8(ascii: " ")
    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Bytes of the current, not yet terminated line.
    private var line: [UInt8] = []
    /// A CR ended the previous line; a directly following LF belongs to it.
    private var lastByteWasCarriageReturn = false
    private var isAtStreamStart = true
    private var eventType = ""
    /// One entry per `data:` field of the pending event.
    private var dataLines: [String] = []
    private var lastEventID = ""

    init() {}

    /// Consumes the next chunk of the stream and returns the events it completed.
    mutating func feed(_ bytes: some Sequence<UInt8>) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            switch byte {
            case Self.lineFeed:
                if lastByteWasCarriageReturn {
                    lastByteWasCarriageReturn = false
                } else {
                    processLine(into: &events)
                }
            case Self.carriageReturn:
                processLine(into: &events)
                lastByteWasCarriageReturn = true
            default:
                lastByteWasCarriageReturn = false
                line.append(byte)
            }
        }
        return events
    }

    /// Ends the stream: processes an unterminated last line, dispatches a pending
    /// event that lacks its final blank line, and resets the parser.
    mutating func flush() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !line.isEmpty {
            processLine(into: &events)
        }
        dispatch(into: &events)
        self = SSEParser()
        return events
    }

    // MARK: Private

    private mutating func processLine(into events: inout [SSEEvent]) {
        defer { line.removeAll(keepingCapacity: true) }
        var bytes = line[...]
        if isAtStreamStart {
            isAtStreamStart = false
            if bytes.starts(with: Self.byteOrderMark) {
                bytes = bytes.dropFirst(Self.byteOrderMark.count)
            }
        }
        guard let first = bytes.first else {
            dispatch(into: &events)
            return
        }
        if first == Self.colon {
            return // Comment line.
        }

        let field: String
        let value: String
        if let colonIndex = bytes.firstIndex(of: Self.colon) {
            field = String(decoding: bytes[..<colonIndex], as: UTF8.self)
            var valueStart = bytes.index(after: colonIndex)
            if valueStart < bytes.endIndex, bytes[valueStart] == Self.space {
                valueStart = bytes.index(after: valueStart)
            }
            value = String(decoding: bytes[valueStart...], as: UTF8.self)
        } else {
            field = String(decoding: bytes, as: UTF8.self)
            value = ""
        }

        switch field {
        case "event":
            eventType = value
        case "data":
            dataLines.append(value)
        case "id":
            if !value.contains("\u{0}") {
                lastEventID = value
            }
        default:
            break // "retry" (we never reconnect) and unknown fields are ignored.
        }
    }

    private mutating func dispatch(into events: inout [SSEEvent]) {
        defer {
            eventType = ""
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return }
        events.append(SSEEvent(
            event: eventType.isEmpty ? nil : eventType,
            data: dataLines.joined(separator: "\n"),
            id: lastEventID.isEmpty ? nil : lastEventID
        ))
    }
}
