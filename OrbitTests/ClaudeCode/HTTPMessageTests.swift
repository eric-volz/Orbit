import Foundation
import Testing
@testable import Orbit

@Suite("MCP bridge HTTP parsing")
struct HTTPMessageTests {
    private func parse(_ text: String, limits: HTTPRequestParser.Limits = HTTPRequestParser.Limits()) -> HTTPRequestParser.Outcome {
        var parser = HTTPRequestParser(limits: limits)
        parser.append(Data(text.utf8))
        return parser.next()
    }

    @Test func parsesARequestWithABody() throws {
        let outcome = parse("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:5\r\nContent-Type: application/json\r\nContent-Length: 7\r\nX-A: 1\r\nX-A: 2\r\n\r\n{\"a\":1}")
        guard case .request(let request) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(request.method == "POST")
        #expect(request.path == "/mcp")
        #expect(request.header("HOST") == "127.0.0.1:5")
        #expect(request.header("x-a") == "1, 2")
        #expect(request.body == Data("{\"a\":1}".utf8))
        #expect(request.keepsAlive)
    }

    @Test func waitsForTheWholeRequestAcrossChunks() throws {
        let text = "POST /mcp HTTP/1.1\r\nContent-Length: 11\r\n\r\nhello world"
        var parser = HTTPRequestParser()
        for chunk in LLMTest.byteChunks(text, size: 3) {
            if case .request = parser.next() { Issue.record("too early") }
            parser.append(chunk)
        }
        guard case .request(let request) = parser.next() else {
            Issue.record("no request")
            return
        }
        #expect(request.body == Data("hello world".utf8))
        #expect(parser.next() == .needsMoreData)
    }

    @Test func handlesPipelinedRequestsOnOneConnection() throws {
        var parser = HTTPRequestParser()
        parser.append(Data("GET /a HTTP/1.1\r\n\r\nPOST /b HTTP/1.1\r\nContent-Length: 2\r\nConnection: close\r\n\r\nokGET".utf8))
        guard case .request(let first) = parser.next(), case .request(let second) = parser.next() else {
            Issue.record("expected two requests")
            return
        }
        #expect(first.target == "/a" && first.body.isEmpty)
        #expect(second.target == "/b" && second.body == Data("ok".utf8) && !second.keepsAlive)
        #expect(parser.next() == .needsMoreData)
        #expect(parser.bufferedByteCount == 3)
    }

    @Test func decodesChunkedBodies() throws {
        let outcome = parse("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4;ext=1\r\nWiki\r\n5\r\npedia\r\n0\r\nTrailer: x\r\n\r\n")
        guard case .request(let request) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(request.body == Data("Wikipedia".utf8))
        #expect(parse("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWi") == .needsMoreData)
    }

    @Test(arguments: [
        ("GARBAGE\r\n\r\n", 400),
        ("POST mcp HTTP/1.1\r\n\r\n", 400),
        ("POST /mcp HTTP/2\r\n\r\n", 400),
        ("post /mcp HTTP/1.1\r\n\r\n", 400),
        ("POST /mcp HTTP/1.1\r\nBad Header\r\n\r\n", 400),
        ("POST /mcp HTTP/1.1\r\nX: a\r\n folded\r\n\r\n", 400),
        ("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n", 400),
        ("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n", 400),
        ("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n", 400),
        ("POST /mcp HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n", 501),
        ("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n", 400),
        ("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n", 413),
    ])
    func rejectsMalformedOrOversizedRequests(text: String, status: Int) {
        #expect(parse(text) == .failure(status: status))
    }

    @Test func enforcesTheLimits() {
        let limits = HTTPRequestParser.Limits(maxHeaderBytes: 64, maxHeaderCount: 2, maxBodyBytes: 4)
        #expect(parse("GET /mcp HTTP/1.1\r\nX: " + String(repeating: "a", count: 100), limits: limits) == .failure(status: 431))
        #expect(parse("GET /mcp HTTP/1.1\r\nA: 1\r\nB: 2\r\nC: 3\r\n\r\n", limits: limits) == .failure(status: 431))
        #expect(parse("POST /mcp HTTP/1.1\r\nContent-Length: 5\r\n\r\n", limits: limits) == .failure(status: 413))
        #expect(parse("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nabcde\r\n0\r\n\r\n", limits: limits)
                == .failure(status: 413))
    }

    @Test func http10ClosesUnlessAskedToKeepAlive() {
        guard case .request(let plain) = parse("GET / HTTP/1.0\r\n\r\n"),
              case .request(let keepAlive) = parse("GET / HTTP/1.0\r\nConnection: Keep-Alive\r\n\r\n") else {
            Issue.record("no request")
            return
        }
        #expect(!plain.keepsAlive)
        #expect(keepAlive.keepsAlive)
    }

    @Test func serializesResponses() {
        let response = HTTPResponse.json(["ok": true])
        let text = String(decoding: response.serialized(keepAlive: true), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.contains("Content-Length: 11\r\n"))
        #expect(text.contains("Connection: keep-alive\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{\"ok\":true}"))
        let closing = String(decoding: HTTPResponse.empty(405, headers: [("Allow", "POST")]).serialized(keepAlive: false),
                             as: UTF8.self)
        #expect(closing.hasPrefix("HTTP/1.1 405 Method Not Allowed\r\n"))
        #expect(closing.contains("Allow: POST\r\n") && closing.contains("Connection: close\r\n"))
    }
}
