import Dispatch
import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

@testable import AgentNotchCore

/// A minimal blocking client, so the server tests exercise real sockets rather
/// than a mock of the thing most likely to be wrong.
enum TestClient {
    /// Send raw bytes and read until EOF. `nil` when the connection failed.
    static func send(_ bytes: Data, to path: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var addr = UnixSocketServer.address(for: path)
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        // Do not let a broken server wedge the whole suite.
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var sent = 0
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while sent < raw.count {
                let n = write(fd, base.advanced(by: sent), raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            response.append(contentsOf: chunk[0..<n])
        }
        return String(data: response, encoding: .utf8)
    }

    static func post(_ body: String, path: String, route: String = "/v1/event/claude-code") -> String? {
        let request = """
            POST \(route) HTTP/1.1\r
            Host: agent-notch\r
            Content-Type: application/json\r
            Content-Length: \(body.utf8.count)\r
            \r
            \(body)
            """
        return send(Data(request.utf8), to: path)
    }
}

/// A socket path short enough to fit `sun_path` no matter where the test runs.
func scratchSocket() -> URL {
    URL(fileURLWithPath: "/tmp/an-t-\(UUID().uuidString.prefix(8)).sock")
}

@Suite("UnixSocketServer", .serialized)
struct UnixSocketServerTests {
    private func makeServer(
        at url: URL,
        handler: @escaping @Sendable (HTTPParse.Request) -> Data = { _ in
            EventRouter.response(status: 204, reason: "No Content", contentType: nil, body: Data())
        }
    ) -> UnixSocketServer {
        UnixSocketServer(
            path: url,
            queue: DispatchQueue(label: "test.io.\(UUID().uuidString)"),
            onRequest: handler
        )
    }

    @Test("a POST round-trips over a real unix socket")
    func roundTrip() throws {
        let url = scratchSocket()
        let seen = Collected()
        let server = makeServer(at: url) { request in
            if let raw = RawPayload(request.body),
               let envelope = ClaudeCodeAdapter.normalize(raw, now: t0) {
                seen.add(envelope)
            }
            return EventRouter.response(status: 204, reason: "No Content", contentType: nil, body: Data())
        }

        try server.start()
        defer { server.stop() }

        #expect(server.isRunning)
        #expect(FileManager.default.fileExists(atPath: url.path))

        let response = TestClient.post(
            #"{"session_id":"abc","hook_event_name":"PreToolUse","_meta":{"pid":9,"tty":"ttys003"}}"#,
            path: url.path
        )

        #expect(response?.hasPrefix("HTTP/1.1 204 No Content") == true)
        #expect(seen.all.first?.sessionID == "abc")
    }

    @Test("the socket file is created 0600 and its directory 0700")
    func permissions() throws {
        let dir = URL(fileURLWithPath: "/tmp/an-t-dir-\(UUID().uuidString.prefix(8))")
        let url = dir.appendingPathComponent("hook.sock")
        let server = makeServer(at: url)

        try server.start()
        defer {
            server.stop()
            try? FileManager.default.removeItem(at: dir)
        }

        let socketMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int

        #expect(socketMode == 0o600)
        #expect(dirMode == 0o700)
    }

    @Test("stop() unlinks the socket file")
    func stopUnlinks() throws {
        let url = scratchSocket()
        let server = makeServer(at: url)

        try server.start()
        #expect(FileManager.default.fileExists(atPath: url.path))

        server.stop()
        #expect(!server.isRunning)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a second instance on a LIVE socket is refused")
    func alreadyRunning() throws {
        let url = scratchSocket()
        let first = makeServer(at: url)
        try first.start()
        defer { first.stop() }

        let second = makeServer(at: url)
        #expect(throws: UnixSocketServer.StartError.alreadyRunning(existingPID: nil)) {
            try second.start()
        }
        #expect(!second.isRunning)

        // The live one is untouched.
        #expect(TestClient.post("{}", path: url.path)?.hasPrefix("HTTP/1.1 204") == true)
    }

    @Test("a STALE socket file left by a crash is taken over, not fatal")
    func staleSocketTakeover() throws {
        let url = scratchSocket()

        // Simulate the corpse: bind a socket to the path, then drop the fd
        // without unlinking — exactly what a `kill -9` leaves behind.
        let orphan = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = UnixSocketServer.address(for: url.path)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(orphan, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        Darwin.close(orphan)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(UnixSocketServer.isLive(path: url.path) == false)

        let server = makeServer(at: url)
        try server.start() // must NOT throw
        defer { server.stop() }

        #expect(server.isRunning)
        #expect(TestClient.post("{}", path: url.path)?.hasPrefix("HTTP/1.1 204") == true)
    }

    @Test("a regular file squatting on the path is never deleted")
    func regularFileIsNotClobbered() throws {
        let url = scratchSocket()
        try Data("precious".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let server = makeServer(at: url)
        #expect(throws: (any Error).self) { try server.start() }

        let survivors = try Data(contentsOf: url)
        #expect(survivors == Data("precious".utf8))
    }

    @Test("a path over the sun_path limit is refused before any syscall")
    func pathTooLong() {
        let url = URL(fileURLWithPath: "/tmp/" + String(repeating: "x", count: 120) + ".sock")
        let server = makeServer(at: url)

        #expect(throws: UnixSocketServer.StartError.self) { try server.start() }
        #expect(!server.isRunning)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("a request split across two writes is reassembled")
    func splitWrite() throws {
        let url = scratchSocket()
        let seen = Collected()
        let server = makeServer(at: url) { request in
            if let raw = RawPayload(request.body), let e = ClaudeCodeAdapter.normalize(raw, now: t0) {
                seen.add(e)
            }
            return EventRouter.response(status: 204, reason: "No Content", contentType: nil, body: Data())
        }
        try server.start()
        defer { server.stop() }

        let body = #"{"session_id":"split","hook_event_name":"Stop"}"#
        let whole = Data(
            "POST /v1/event/claude-code HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8
        )

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = UnixSocketServer.address(for: url.path)
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(connected == 0)

        func writeAll(_ slice: Data) {
            slice.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                _ = write(fd, raw.baseAddress, raw.count)
            }
        }
        writeAll(whole.prefix(whole.count - 20))
        usleep(50_000) // let the server see a partial request and keep waiting
        writeAll(Data(whole.suffix(20)))

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var chunk = [UInt8](repeating: 0, count: 1024)
        let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }

        #expect(n > 0)
        #expect(String(bytes: chunk[0..<max(0, n)], encoding: .utf8)?.hasPrefix("HTTP/1.1 204") == true)
        #expect(seen.all.first?.sessionID == "split")
    }

    @Test("a malformed request is answered 400 rather than hanging the client")
    func malformedRequest() throws {
        let url = scratchSocket()
        let server = makeServer(at: url)
        try server.start()
        defer { server.stop() }

        let response = TestClient.send(Data("GARBAGE\r\n\r\n".utf8), to: url.path)
        #expect(response?.hasPrefix("HTTP/1.1 400 Bad Request") == true)
    }

    @Test("health answers over the socket")
    func healthOverSocket() throws {
        let url = scratchSocket()
        let router = EventRouter(deliver: { _ in }, sessionCount: { 2 })
        let server = makeServer(at: url) { router.respond(to: $0) }
        try server.start()
        defer { server.stop() }

        let response = TestClient.send(Data("GET /v1/health HTTP/1.1\r\nHost: x\r\n\r\n".utf8), to: url.path)

        #expect(response?.hasPrefix("HTTP/1.1 200 OK") == true)
        #expect(response?.contains(#""sessions":2"#) == true)
    }

    @Test("many sequential connections all get served")
    func manyConnections() throws {
        let url = scratchSocket()
        let seen = Collected()
        let server = makeServer(at: url) { request in
            if let raw = RawPayload(request.body), let e = ClaudeCodeAdapter.normalize(raw, now: t0) {
                seen.add(e)
            }
            return EventRouter.response(status: 204, reason: "No Content", contentType: nil, body: Data())
        }
        try server.start()
        defer { server.stop() }

        for i in 0..<20 {
            let response = TestClient.post(#"{"session_id":"s\#(i)","hook_event_name":"PreToolUse"}"#, path: url.path)
            #expect(response?.hasPrefix("HTTP/1.1 204") == true)
        }
        #expect(seen.all.count == 20)
    }

    @Test("start() twice on the same instance is a no-op, not a crash")
    func doubleStart() throws {
        let url = scratchSocket()
        let server = makeServer(at: url)

        try server.start()
        try server.start()
        defer { server.stop() }

        #expect(server.isRunning)
    }

    @Test("stop() twice is safe")
    func doubleStop() throws {
        let url = scratchSocket()
        let server = makeServer(at: url)

        try server.start()
        server.stop()
        server.stop()

        #expect(!server.isRunning)
    }
}
