import Foundation
import Network
import os

/// A parsed HTTP/1.1 request. Bodies must be sent with Content-Length.
struct HTTPRequest: Sendable {
    var method: String
    /// The request target without the query string, e.g. "/v1/messages".
    var path: String
    /// Header names are lowercased.
    var headers: [String: String]
    var body: Data

    /// The API key from `x-api-key` or `Authorization: Bearer …`, if any.
    var apiKey: String? {
        if let key = headers["x-api-key"], !key.isEmpty { return key }
        if let authorization = headers["authorization"], authorization.lowercased().hasPrefix("bearer ") {
            return String(authorization.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
}

enum HTTPError: Error {
    /// The client closed the connection before sending a complete request.
    case closed
    case malformed(String)
    case headerTooLarge
    case bodyTooLarge
    case lengthRequired

    /// Status code for the error response, nil when nothing can be sent.
    var status: Int? {
        switch self {
        case .closed: nil
        case .malformed: 400
        case .headerTooLarge: 431
        case .bodyTooLarge: 413
        case .lengthRequired: 411
        }
    }
}

enum HTTP {
    static let maximumHeaderSize = 64 * 1024
    static let maximumBodySize = 64 * 1024 * 1024

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 100: "Continue"
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 402: "Payment Required"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 408: "Request Timeout"
        case 409: "Conflict"
        case 411: "Length Required"
        case 413: "Content Too Large"
        case 422: "Unprocessable Content"
        case 429: "Too Many Requests"
        case 431: "Request Header Fields Too Large"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        case 529: "Overloaded"
        default: "Status \(status)"
        }
    }

    /// Serializes a response head. Every response closes the connection.
    static func head(status: Int, headers: [(String, String)]) -> Data {
        var text = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
        for (name, value) in headers {
            text += "\(name): \(value)\r\n"
        }
        text += "Connection: close\r\n\r\n"
        return Data(text.utf8)
    }

    /// Reads one request (head plus Content-Length body) from the connection.
    /// Answers `Expect: 100-continue` so clients like curl send the body at once.
    static func readRequest(from connection: NWConnection) async throws -> HTTPRequest {
        let separator = Data("\r\n\r\n".utf8)
        var buffer = Data()
        var headEnd: Range<Data.Index>?
        while headEnd == nil {
            let (chunk, isComplete) = try await connection.receiveChunk()
            if let chunk { buffer.append(chunk) }
            headEnd = buffer.range(of: separator)
            if headEnd == nil {
                if buffer.count > maximumHeaderSize { throw HTTPError.headerTooLarge }
                if isComplete { throw buffer.isEmpty ? HTTPError.closed : HTTPError.malformed("incomplete request head") }
            }
        }
        guard let headEnd else { throw HTTPError.closed }
        guard let headText = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
            throw HTTPError.malformed("request head is not UTF-8")
        }
        var lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            throw HTTPError.malformed("bad request line")
        }
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPError.malformed("bad header line") }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = headers[name].map { "\($0), \(value)" } ?? value
        }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target

        if let transferEncoding = headers["transfer-encoding"], transferEncoding.lowercased() != "identity" {
            throw HTTPError.lengthRequired
        }
        let contentLength: Int
        if let lengthText = headers["content-length"] {
            guard let length = Int(lengthText), length >= 0 else { throw HTTPError.malformed("bad Content-Length") }
            guard length <= maximumBodySize else { throw HTTPError.bodyTooLarge }
            contentLength = length
        } else {
            contentLength = 0
        }

        var body = Data(buffer[headEnd.upperBound...])
        if body.count < contentLength, headers["expect"]?.lowercased() == "100-continue" {
            try await connection.sendData(Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
        }
        while body.count < contentLength {
            let (chunk, isComplete) = try await connection.receiveChunk()
            if let chunk { body.append(chunk) }
            if isComplete && body.count < contentLength { throw HTTPError.malformed("body shorter than Content-Length") }
        }
        if body.count > contentLength { body = body.prefix(contentLength) }
        return HTTPRequest(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: body)
    }
}

// MARK: - NWConnection + async/await

extension NWConnection {
    /// Receives up to 64 KB. `isComplete` is true once the peer closed its side.
    func receiveChunk() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (data, isComplete))
                }
            }
        }
    }

    func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}

/// Tracks whether the client went away while a response streams, so streaming
/// stops right away (e.g. when the app cancels a request).
final class DisconnectMonitor: Sendable {
    private let disconnected = OSAllocatedUnfairLock(initialState: false)

    var isDisconnected: Bool { disconnected.withLock { $0 } }

    func markDisconnected() {
        disconnected.withLock { $0 = true }
    }

    /// Waits for the peer to close its side (or for any unexpected data/error).
    func watch(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [self] _, _, isComplete, error in
            if isComplete || error != nil {
                markDisconnected()
            }
        }
    }
}
