import Foundation

/// A message file from Mail's store, parsed for what Orbit shows of it: the
/// subject, the sender, the Message-ID, the readable text and the read flag.
///
/// An .emlx file is the message's length in bytes on the first line, the
/// RFC 5322 message, then a property list with Mail's flags. The parser is
/// pure, linear and bounded (at most `maxMessageBytes` of a message, the first
/// `maxHeaderCharacters` of the subject and the sender, a limited MIME depth
/// and part count), because a message's content is chosen by its sender:
/// headers with RFC 2047 encoded words, MIME parts with base64 or
/// quoted-printable transfer encoding and any charset macOS knows. The text is
/// the plain-text part, or the HTML part as text; parts that are attachments
/// are skipped.
struct MailMessageFile: Sendable, Hashable {
    var subject: String?
    /// The From header, decoded ("Lisa Beispiel <lisa@example.com>").
    var from: String?
    /// Without angle brackets.
    var messageID: String?
    /// The readable text, line breaks as "\n"; at most the requested characters.
    var text: String
    /// Bit 0 of Mail's flags in an .emlx file; nil without them.
    var isRead: Bool?

    /// Bytes of a message looked at (an attachment beyond is never decoded).
    static let maxMessageBytes = 2 * 1024 * 1024
    /// Characters (counted as Unicode scalars, since one character can hold
    /// any number of them) of the Subject and From headers decoded: Orbit shows
    /// at most a few hundred, and a sender may make them hundreds of kilobytes long.
    static let maxHeaderCharacters = 4_000

    /// Parses an .emlx file; nil when it does not start with the message's length.
    static func parse(emlx data: Data, maxTextCharacters: Int) -> MailMessageFile? {
        let bytes = [UInt8](data.prefix(maxMessageBytes + 64 * 1024))
        guard let newline = bytes.firstIndex(of: 0x0A), newline <= 12 else { return nil }
        let lengthText = String(decoding: bytes[..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard let length = Int(lengthText), length > 0 else { return nil }
        let start = newline + 1
        let end = min(bytes.count, start + length)
        var message = parse(message: bytes[start..<end], maxTextCharacters: maxTextCharacters)
        if start + length <= bytes.count {
            message.isRead = flags(inPropertyList: Data(bytes[(start + length)...])).map { $0 & 1 == 1 }
        }
        return message
    }

    /// Parses a plain RFC 5322 message.
    static func parse(message bytes: ArraySlice<UInt8>, maxTextCharacters: Int) -> MailMessageFile {
        let part = MIMEPart(bytes: bytes.prefix(maxMessageBytes))
        let text = MIMEText.text(of: part, depth: 0).map(MIMEText.normalizingLineBreaks) ?? ""
        func decoded(_ header: String) -> String {
            let capped = String(String.UnicodeScalarView(header.unicodeScalars.prefix(maxHeaderCharacters)))
            return Truncation.collapsingCombiningMarks(MIMEText.singleLine(MIMEText.decodingEncodedWords(capped)))
        }
        return MailMessageFile(
            subject: part.header("subject").map(decoded),
            from: part.header("from").map(decoded),
            messageID: part.header("message-id").map(MailText.bareMessageID).flatMap { $0.isEmpty ? nil : $0 },
            text: Truncation.prefix(text, maxCharacters: maxTextCharacters),
            isRead: nil
        )
    }

    private static func flags(inPropertyList data: Data) -> Int64? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let flags = plist["flags"] as? NSNumber else { return nil }
        return flags.int64Value
    }
}

/// One MIME entity: its headers (unfolded, names lowercased) and its body bytes.
struct MIMEPart {
    var headers: [(name: String, value: String)]
    var body: ArraySlice<UInt8>

    /// Splits `bytes` at the first empty line (CRLF or LF line breaks).
    init(bytes: ArraySlice<UInt8>) {
        var index = bytes.startIndex
        var headerEnd = bytes.endIndex
        var bodyStart = bytes.endIndex
        // A part may start with the empty line (no headers at all).
        if bytes.first == 0x0A {
            headerEnd = bytes.startIndex
            bodyStart = bytes.startIndex + 1
        } else if bytes.starts(with: [0x0D, 0x0A]) {
            headerEnd = bytes.startIndex
            bodyStart = bytes.startIndex + 2
        } else {
            while index < bytes.endIndex {
                guard let newline = bytes[index...].firstIndex(of: 0x0A) else { break }
                let next = newline + 1
                if next < bytes.endIndex, bytes[next] == 0x0A {
                    headerEnd = newline
                    bodyStart = next + 1
                    break
                }
                if next + 1 < bytes.endIndex, bytes[next] == 0x0D, bytes[next + 1] == 0x0A {
                    headerEnd = newline
                    bodyStart = next + 2
                    break
                }
                index = next
            }
        }
        headers = Self.headers(in: bytes[bytes.startIndex..<headerEnd])
        body = bodyStart <= bytes.endIndex ? bytes[bodyStart...] : []
    }

    /// The first value of header `name` (lowercased), unfolded.
    func header(_ name: String) -> String? {
        headers.first { $0.name == name }?.value
    }

    /// The media type ("text/plain" by default) and its parameters (names lowercased).
    var contentType: (type: String, parameters: [String: String]) {
        MIMEText.parameters(of: header("content-type") ?? "text/plain")
    }

    var isAttachment: Bool {
        guard let disposition = header("content-disposition") else { return false }
        return MIMEText.parameters(of: disposition).type == "attachment"
    }

    /// The body with its transfer encoding undone.
    var decodedBody: Data {
        switch (header("content-transfer-encoding") ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64": MIMEText.decodingBase64(body)
        case "quoted-printable": MIMEText.decodingQuotedPrintable(body)
        default: Data(body)
        }
    }

    /// The parts of a multipart body, at most `limit`; empty when there is no boundary.
    func subparts(limit: Int = MIMEText.maxParts) -> [MIMEPart] {
        guard let boundary = contentType.parameters["boundary"], !boundary.isEmpty, limit > 0 else { return [] }
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [MIMEPart] = []
        var partStart: Int?
        var lineStart = body.startIndex
        while lineStart < body.endIndex, parts.count < limit {
            let newline = body[lineStart...].firstIndex(of: 0x0A) ?? body.endIndex
            let line = body[lineStart..<newline]
            if line.starts(with: delimiter) {
                let rest = line.dropFirst(delimiter.count)
                let isClosing = rest.starts(with: [0x2D, 0x2D])
                let isDelimiter = isClosing || rest.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
                if isDelimiter {
                    if let start = partStart {
                        // The line break before the delimiter belongs to the delimiter.
                        var end = lineStart
                        if end > start, body[end - 1] == 0x0A { end -= 1 }
                        if end > start, body[end - 1] == 0x0D { end -= 1 }
                        parts.append(MIMEPart(bytes: body[start..<max(start, end)]))
                    }
                    if isClosing { return parts }
                    partStart = newline < body.endIndex ? newline + 1 : body.endIndex
                }
            }
            lineStart = newline < body.endIndex ? newline + 1 : body.endIndex
        }
        if let start = partStart, start < body.endIndex, parts.count < limit {
            parts.append(MIMEPart(bytes: body[start...]))
        }
        return parts
    }

    private static func headers(in bytes: ArraySlice<UInt8>) -> [(name: String, value: String)] {
        let text = MIMEText.decodedHeaderBytes(Data(bytes))
        var headers: [(name: String, value: String)] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if let first = line.first, first == " " || first == "\t" {
                // A folded line continues the previous header.
                if !headers.isEmpty { headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty, !name.contains(" ") else { continue }
            headers.append((name, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return headers
    }
}

/// Decoding helpers for MIME text.
enum MIMEText {
    static let maxDepth = 6
    /// Parts of one multipart read at most.
    static let maxParts = 100
    /// Parts of a whole message read at most while looking for its text (a
    /// real message has a few dozen; nested multiparts could have many thousands).
    static let maxPartsPerMessage = 200

    /// The readable text of a part: for multipart/alternative the plain part
    /// (else the HTML one), for other multiparts the first part with text,
    /// never an attachment. Reads at most `maxPartsPerMessage` parts.
    static func text(of part: MIMEPart, depth: Int) -> String? {
        var budget = maxPartsPerMessage
        return text(of: part, depth: depth, budget: &budget)
    }

    /// `budget`: how many more parts may be read.
    private static func text(of part: MIMEPart, depth: Int, budget: inout Int) -> String? {
        guard depth <= maxDepth, !part.isAttachment else { return nil }
        let (type, parameters) = part.contentType
        if type.hasPrefix("multipart/") {
            let subparts = part.subparts(limit: min(maxParts, budget))
            budget -= subparts.count
            if type == "multipart/alternative" {
                let candidates = subparts.filter { !$0.isAttachment }
                var plain: String?
                if let plainPart = candidates.first(where: { $0.contentType.type == "text/plain" }) {
                    plain = text(of: plainPart, depth: depth + 1, budget: &budget)
                }
                if let plain, !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return plain }
                for candidate in candidates.reversed() where candidate.contentType.type != "text/plain" {
                    if let found = text(of: candidate, depth: depth + 1, budget: &budget), !found.isEmpty { return found }
                }
                return plain
            }
            for subpart in subparts {
                if let found = text(of: subpart, depth: depth + 1, budget: &budget),
                   !found.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return found
                }
            }
            return nil
        }
        switch type {
        case "text/plain":
            return string(part.decodedBody, charset: parameters["charset"])
        case "text/html":
            return FileTextExtractor.plainText(fromHTML: string(part.decodedBody, charset: parameters["charset"]))
        default:
            return nil
        }
    }

    // MARK: Headers

    /// A media type with its parameters, e.g. `text/plain; charset="utf-8"` →
    /// ("text/plain", ["charset": "utf-8"]). Names are lowercased, quotes removed.
    static func parameters(of value: String) -> (type: String, parameters: [String: String]) {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        for character in value {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", inQuotes {
                escaped = true
            } else if character == "\"" {
                inQuotes.toggle()
            } else if character == ";", !inQuotes {
                pieces.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        pieces.append(current)
        let type = pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let name = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let parameterValue = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, parameters[name] == nil { parameters[name] = parameterValue }
        }
        return (type, parameters)
    }

    /// Header bytes as text: UTF-8 when valid (raw 8-bit headers), else Windows-1252.
    static func decodedHeaderBytes(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// RFC 2047 encoded words (`=?utf-8?Q?Gr=C3=BC=C3=9Fe?=`, `=?iso-8859-1?B?…?=`)
    /// decoded; whitespace between two encoded words is dropped, as the RFC says.
    /// One pass over the text: a candidate word is given up at the first "?"
    /// that does not fit (a payload never contains one), so a header made of
    /// broken words ("=?a?Q?b=?a?Q?b…") costs no more than a clean one.
    static func decodingEncodedWords(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let bytes = Array(text.utf8)
        var output = ""
        // `bytes[..<copied]` are in `output` (or dropped as whitespace between words).
        var copied = 0
        var index = 0
        var previousWasEncoded = false
        while index + 1 < bytes.count {
            guard bytes[index] == UInt8(ascii: "="), bytes[index + 1] == UInt8(ascii: "?") else {
                index += 1
                continue
            }
            guard let (decoded, end) = encodedWord(in: bytes, at: index) else {
                // Not an encoded word: "=?" stays text.
                previousWasEncoded = false
                index += 2
                continue
            }
            // "=" and "?" are ASCII, so these cuts never split a character.
            let before = String(decoding: bytes[copied..<index], as: UTF8.self)
            if !(previousWasEncoded && before.allSatisfy(\.isWhitespace)) {
                output += before
            }
            output += decoded
            previousWasEncoded = true
            index = end
            copied = end
        }
        output += String(decoding: bytes[copied...], as: UTF8.self)
        return output
    }

    /// Bytes looked at for an encoded word's charset (with an RFC 2231
    /// language, "utf-8*de") and its payload; real ones are far shorter.
    private static let maxCharsetBytes = 100
    private static let maxPayloadBytes = 8_000

    /// The encoded word that starts with the "=?" at `start`, and the index
    /// after its "?="; nil when there is none.
    private static func encodedWord(in bytes: [UInt8], at start: Int) -> (String, Int)? {
        let mark = UInt8(ascii: "?")
        // charset "?" encoding "?" payload "?="
        let charsetStart = start + 2
        var charsetEnd = charsetStart
        while charsetEnd < bytes.count, bytes[charsetEnd] != mark {
            guard charsetEnd - charsetStart < maxCharsetBytes else { return nil }
            charsetEnd += 1
        }
        guard charsetEnd + 2 < bytes.count, bytes[charsetEnd + 2] == mark else { return nil }
        let charset = String(decoding: bytes[charsetStart..<charsetEnd], as: UTF8.self)
            .split(separator: "*").first.map(String.init) ?? ""
        guard !charset.isEmpty, charset.count <= 40 else { return nil }
        let encoding = bytes[charsetEnd + 1]
        // The payload holds no "?": it ends at the next one, which must begin "?=".
        let payloadStart = charsetEnd + 3
        var payloadEnd = payloadStart
        while payloadEnd < bytes.count, bytes[payloadEnd] != mark {
            guard payloadEnd - payloadStart < maxPayloadBytes else { return nil }
            payloadEnd += 1
        }
        guard payloadEnd + 1 < bytes.count, bytes[payloadEnd + 1] == UInt8(ascii: "=") else { return nil }
        let payload = bytes[payloadStart..<payloadEnd]
        let payloadText = String(decoding: payload, as: UTF8.self)
        guard payloadText.count <= 2_000, !payloadText.contains(where: \.isNewline) else { return nil }
        let decoded: Data
        switch encoding {
        case UInt8(ascii: "B"), UInt8(ascii: "b"):
            decoded = decodingBase64(payload)
        case UInt8(ascii: "Q"), UInt8(ascii: "q"):
            decoded = decodingQuotedPrintable(payload, underscoreIsSpace: true)
        default:
            return nil
        }
        return (string(decoded, charset: charset), payloadEnd + 2)
    }

    // MARK: Bodies

    static func decodingBase64(_ bytes: ArraySlice<UInt8>) -> Data {
        var cleaned = bytes.filter { byte in
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte)
                || byte == 0x2B || byte == 0x2F
        }
        // Padding is optional for Orbit; whatever is left over is incomplete.
        cleaned.removeLast(cleaned.count % 4 == 1 ? 1 : 0)
        while cleaned.count % 4 != 0 { cleaned.append(0x3D) }
        return Data(base64Encoded: Data(cleaned)) ?? Data()
    }

    /// Quoted-printable: `=XX` is a byte, `=` at a line end a soft line break,
    /// anything else (also a broken `=`) stays as it is.
    static func decodingQuotedPrintable(_ bytes: ArraySlice<UInt8>, underscoreIsSpace: Bool = false) -> Data {
        var output = Data()
        output.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x41 + 10
            case 0x61...0x66: byte - 0x61 + 10
            default: nil
            }
        }
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == 0x3D {
                let next = index + 1
                if next < bytes.endIndex, bytes[next] == 0x0A {
                    index = next + 1
                    continue
                }
                if next + 1 < bytes.endIndex, bytes[next] == 0x0D, bytes[next + 1] == 0x0A {
                    index = next + 2
                    continue
                }
                if next + 1 < bytes.endIndex, let high = hexValue(bytes[next]), let low = hexValue(bytes[next + 1]) {
                    output.append(high << 4 | low)
                    index = next + 2
                    continue
                }
                output.append(byte)
            } else if byte == 0x5F, underscoreIsSpace {
                output.append(0x20)
            } else {
                output.append(byte)
            }
            index += 1
        }
        return output
    }

    /// Bytes in a charset; unknown or wrong charsets fall back to UTF-8, then
    /// Windows-1252. ISO-8859-1 and US-ASCII are read as Windows-1252, their
    /// superset (as browsers do).
    static func string(_ data: Data, charset: String?) -> String {
        let name = (charset ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased()
        if ["iso-8859-1", "latin1", "latin-1", "us-ascii", "ascii", "iso_8859-1", "windows-1252"].contains(name) {
            if let text = String(data: data, encoding: .windowsCP1252) { return text }
        } else if !name.isEmpty {
            let encoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return text
            }
        }
        return FileTextExtractor.decodeText(data, allowLegacyEncodings: true)?.text ?? String(decoding: data, as: UTF8.self)
    }

    /// "\r\n" and lone "\r" as "\n".
    static func normalizingLineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Whitespace runs (also line breaks) as single spaces, trimmed.
    static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
