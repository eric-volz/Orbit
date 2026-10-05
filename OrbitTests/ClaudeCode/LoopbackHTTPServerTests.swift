import Darwin
import Foundation
import os
import Testing
@testable import Orbit

@Suite("MCP bridge HTTP server")
struct LoopbackHTTPServerTests {
    /// A blocking TCP client for tests (runs off the cooperative pool).
    final class Client: Sendable {
        let fd: Int32

        init(host: String = "127.0.0.1", port: UInt16) throws {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            inet_pton(AF_INET, host, &address.sin_addr)
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            // No close(fd) here: the object is fully initialized, so throwing runs
            // deinit, which closes it; closing twice could hit another thread's
            // reused descriptor (EXC_GUARD crash of the test process).
            guard result == 0 else {
                throw POSIXError(.ECONNREFUSED)
            }
        }

        deinit {
            close(fd)
        }

        func send(_ text: String) {
            let bytes = Array(text.utf8)
            _ = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        }

        /// Reads one response (headers + Content-Length body); nil at EOF or timeout.
        func readResponse() -> (status: Int, headers: [String: String], body: String)? {
            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                    var lines = head.components(separatedBy: "\r\n")
                    let statusLine = lines.removeFirst().split(separator: " ")
                    var headers: [String: String] = [:]
                    for line in lines {
                        let parts = line.split(separator: ":", maxSplits: 1)
                        if parts.count == 2 {
                            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
                        }
                    }
                    let length = Int(headers["content-length"] ?? "0") ?? 0
                    while buffer.count - range.upperBound < length {
                        let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                        guard count > 0 else { return nil }
                        buffer.append(contentsOf: chunk[0..<count])
                    }
                    let body = String(decoding: buffer[range.upperBound..<(range.upperBound + length)], as: UTF8.self)
                    return (Int(statusLine.dropFirst().first ?? "") ?? 0, headers, body)
                }
                let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
                guard count > 0 else { return nil }
                buffer.append(contentsOf: chunk[0..<count])
            }
        }

        /// Whether the server closed the connection (EOF within the timeout).
        /// nil when the server dropped the connection, else what happened instead.
        func closedByPeer(timeoutSeconds: Int = 5) -> String? {
            var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var byte: UInt8 = 0
            let received = recv(fd, &byte, 1, 0)
            let code = errno
            // An orderly close, or an error because the server stopped before it
            // accepted the connection (reset, abort): either way it is gone.
            // Only a timeout means the connection is still open.
            if received == 0 { return nil }
            if received < 0, code != EAGAIN, code != EWOULDBLOCK { return nil }
            return received > 0 ? "received data" : "still open (errno \(code))"
        }
    }

    private func onBackgroundThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    private func echoServer(configuration: LoopbackHTTPServer.Configuration = LoopbackHTTPServer.Configuration(),
                            seen: OSAllocatedUnfairLock<[String]>) -> LoopbackHTTPServer {
        LoopbackHTTPServer(configuration: configuration) { request in
            seen.withLock { $0.append("\(request.method) \(request.target) \(String(decoding: request.body, as: UTF8.self))") }
            return .json(["path": .string(request.path)])
        }
    }

    @Test func servesSeveralRequestsOnOneConnection() async throws {
        let seen = OSAllocatedUnfairLock(initialState: [String]())
        let server = echoServer(seen: seen)
        defer { server.stop() }
        let port = try await server.start()
        #expect(port > 0 && server.port == port)
        let responses = try await onBackgroundThread { () -> [Int] in
            let client = try Client(port: port)
            client.send("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 5\r\n\r\nfirst")
            let first = client.readResponse()
            client.send("POST /other HTTP/1.1\r\nHost: 127.0.0.1\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nsecond\r\n0\r\n\r\n")
            let second = client.readResponse()
            return [first?.status ?? 0, second?.status ?? 0,
                    first?.headers["connection"] == "keep-alive" ? 1 : 0,
                    second?.body == #"{"path":"/other"}"# ? 1 : 0]
        }
        #expect(responses == [200, 200, 1, 1])
        #expect(seen.withLock { $0 } == ["POST /mcp first", "POST /other second"])
    }

    @Test func answersBadRequestsAndCloses() async throws {
        let seen = OSAllocatedUnfairLock(initialState: [String]())
        var configuration = LoopbackHTTPServer.Configuration()
        configuration.limits.maxBodyBytes = 16
        let server = echoServer(configuration: configuration, seen: seen)
        defer { server.stop() }
        let port = try await server.start()
        let result = try await onBackgroundThread { () -> (Int, Bool) in
            let client = try Client(port: port)
            client.send("POST /mcp HTTP/1.1\r\nContent-Length: 1000\r\n\r\n")
            let status = client.readResponse()?.status ?? 0
            return (status, client.closedByPeer() == nil)
        }
        #expect(result.0 == 413)
        #expect(result.1)
        #expect(seen.withLock { $0.isEmpty })
    }

    @Test func incompleteRequestsTimeOut() async throws {
        var configuration = LoopbackHTTPServer.Configuration()
        configuration.requestTimeout = .milliseconds(300)
        let server = echoServer(configuration: configuration, seen: OSAllocatedUnfairLock(initialState: []))
        defer { server.stop() }
        let port = try await server.start()
        let status = try await onBackgroundThread { () -> Int in
            let client = try Client(port: port)
            client.send("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc")
            return client.readResponse()?.status ?? 0
        }
        #expect(status == 408)
    }

    @Test func aDisconnectCancelsTheHandler() async throws {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let started = OSAllocatedUnfairLock(initialState: false)
        let server = LoopbackHTTPServer { _ in
            started.withLock { $0 = true }
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.withLock { $0 = true }
            }
            return .empty(200)
        }
        defer { server.stop() }
        let port = try await server.start()
        let client = try await onBackgroundThread { () -> Client in
            let client = try Client(port: port)
            client.send("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}")
            return client
        }
        #expect(await LLMTest.eventually { started.withLock { $0 } })
        shutdown(client.fd, SHUT_RDWR)
        #expect(await LLMTest.eventually { cancelled.withLock { $0 } })
    }

    @Test func stopClosesConnectionsAndRefusesNewOnes() async throws {
        let server = echoServer(seen: OSAllocatedUnfairLock(initialState: []))
        let port = try await server.start()
        let client = try await onBackgroundThread { try Client(port: port) }
        server.stop()
        let problem = try await onBackgroundThread { client.closedByPeer() }
        #expect(problem == nil)
        let refused = await LLMTest.eventually {
            (try? Client(port: port)) == nil
        }
        #expect(refused)
        await #expect(throws: LoopbackHTTPServer.Failure.self) { _ = try await server.start() }
    }

    @Test func listensOnLoopbackOnly() async throws {
        guard let address = Self.externalIPv4Address() else { return } // no other interface on this machine
        let server = echoServer(seen: OSAllocatedUnfairLock(initialState: []))
        defer { server.stop() }
        let port = try await server.start()
        let connected = try await onBackgroundThread { (try? Client(host: address, port: port)) != nil }
        #expect(!connected)
    }

    /// The first non-loopback IPv4 address of this Mac, if any.
    static func externalIPv4Address() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  (entry.pointee.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                              NI_NUMERICHOST) == 0 else { continue }
            return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        return nil
    }
}
