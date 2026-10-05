import Foundation

/// A parsed HTTP/1.x request of the MCP bridge.
struct HTTPRequest: Sendable, Hashable {
    var method: String
    /// Origin-form request target, e.g. "/mcp" or "/mcp?x=1".
    var target: String
    var version: String
    /// Lowercased names; repeated fields joined with ", ".
    var headers: [String: String]
    var body: Data

    var path: String {
        String(target.prefix { $0 != "?" && $0 != "#" })
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// Whether the connection stays open after the response.
    var keepsAlive: Bool {
        let connection = header("connection")?.lowercased() ?? ""
        if version == "HTTP/1.0" {
            return connection.contains("keep-alive")
        }
        return !connection.contains("close")
    }
}

/// A response of the MCP bridge.
struct HTTPResponse: Sendable, Hashable {
    var status: Int
    var headers: [(name: String, value: String)]
    var body: Data

    init(status: Int, headers: [(name: String, value: String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func == (lhs: HTTPResponse, rhs: HTTPResponse) -> Bool {
        lhs.status == rhs.status && lhs.body == rhs.body
            && lhs.headers.map { "\($0.name):\($0.value)" } == rhs.headers.map { "\($0.name):\($0.value)" }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(status)
        hasher.combine(body)
    }

    static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: value.jsonData())
    }

    static func empty(_ status: Int, headers: [(name: String, value: String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: headers)
    }

    /// The wire form. `Content-Length` and `Connection` are always set here.
    func serialized(keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
        for header in headers where !["content-length", "connection"].contains(header.name.lowercased()) {
            head += "\(header.name): \(header.value)\r\n"
        }
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        head += "Cache-Control: no-store\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 415: "Unsupported Media Type"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 501: "Not Implemented"
        case 503: "Service Unavailable"
        default: "Status \(status)"
        }
    }
}

/// Incremental HTTP/1.1 request parser with strict limits. Supports
/// `Content-Length` and chunked bodies; rejects everything ambiguous (both
/// length headers, obsolete line folding, malformed request lines).
struct HTTPRequestParser {
    struct Limits: Sendable, Hashable {
        var maxHeaderBytes = 16 * 1024
        var maxHeaderCount = 64
        var maxBodyBytes = 4 * 1024 * 1024
    }

    enum Outcome: Sendable, Hashable {
        case needsMoreData
        case request(HTTPRequest)
        /// The request is invalid; answer with this status and close.
        case failure(status: Int)
    }

    let limits: Limits
    private var buffer = Data()

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// Bytes received but not consumed by a request yet.
    var bufferedByteCount: Int { buffer.count }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete request (consuming its bytes), if one is buffered.
    mutating func next() -> Outcome {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else {
            return buffer.count > limits.maxHeaderBytes ? .failure(status: 431) : .needsMoreData
        }
        guard headerEnd.lowerBound - buffer.startIndex <= limits.maxHeaderBytes else { return .failure(status: 431) }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .failure(status: 400)
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3 else { return .failure(status: 400) }
        let method = String(requestLine[0])
        let target = String(requestLine[1])
        let version = String(requestLine[2])
        guard !method.isEmpty, method.allSatisfy({ $0.isLetter && $0.isUppercase }),
              target.hasPrefix("/"), version == "HTTP/1.1" || version == "HTTP/1.0" else {
            return .failure(status: 400)
        }
        guard lines.count <= limits.maxHeaderCount else { return .failure(status: 431) }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":"), let first = line.first, first != " ", first != "\t" else {
                return .failure(status: 400)
            }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else {
                return .failure(status: 400)
            }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }

        let bodyStart = headerEnd.upperBound
        let body: Data
        let consumed: Data.Index
        if let encoding = headers["transfer-encoding"] {
            guard headers["content-length"] == nil else { return .failure(status: 400) }
            guard encoding.lowercased() == "chunked" else { return .failure(status: 501) }
            switch decodeChunked(from: bodyStart) {
            case .needsMoreData: return .needsMoreData
            case .failure(let status): return .failure(status: status)
            case .complete(let data, let end):
                body = data
                consumed = end
            }
        } else if let lengthText = headers["content-length"] {
            guard !lengthText.isEmpty, lengthText.allSatisfy(\.isASCII), lengthText.allSatisfy(\.isNumber),
                  lengthText.count <= 12, let length = Int(lengthText) else { return .failure(status: 400) }
            guard length <= limits.maxBodyBytes else { return .failure(status: 413) }
            guard buffer.endIndex - bodyStart >= length else { return .needsMoreData }
            body = buffer[bodyStart..<(bodyStart + length)]
            consumed = bodyStart + length
        } else {
            body = Data()
            consumed = bodyStart
        }

        buffer = Data(buffer[consumed...])
        return .request(HTTPRequest(method: method, target: target, version: version, headers: headers, body: Data(body)))
    }

    private enum ChunkOutcome {
        case needsMoreData
        case failure(status: Int)
        case complete(Data, end: Data.Index)
    }

    private func decodeChunked(from start: Data.Index) -> ChunkOutcome {
        let lineBreak = Data("\r\n".utf8)
        var body = Data()
        var position = start
        while true {
            guard let sizeEnd = buffer[position...].range(of: lineBreak) else {
                return buffer.endIndex - position > 1024 ? .failure(status: 400) : .needsMoreData
            }
            let sizeLine = String(decoding: buffer[position..<sizeEnd.lowerBound], as: UTF8.self)
            let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !sizeText.isEmpty, sizeText.count <= 8, let size = Int(sizeText, radix: 16), size >= 0 else {
                return .failure(status: 400)
            }
            position = sizeEnd.upperBound
            if size == 0 {
                // Trailer fields (ignored) end with an empty line.
                guard let trailerEnd = buffer[position...].range(of: lineBreak) else { return .needsMoreData }
                if trailerEnd.lowerBound == position {
                    return .complete(body, end: trailerEnd.upperBound)
                }
                guard let end = buffer[position...].range(of: Data("\r\n\r\n".utf8)) else {
                    return buffer.endIndex - position > limits.maxHeaderBytes ? .failure(status: 431) : .needsMoreData
                }
                return .complete(body, end: end.upperBound)
            }
            guard body.count + size <= limits.maxBodyBytes else { return .failure(status: 413) }
            guard buffer.endIndex - position >= size + 2 else { return .needsMoreData }
            body.append(buffer[position..<(position + size)])
            position += size
            guard buffer[position..<(position + 2)] == lineBreak else { return .failure(status: 400) }
            position += 2
        }
    }
}
