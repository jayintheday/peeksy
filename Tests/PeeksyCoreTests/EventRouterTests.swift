import Foundation
import Testing

@testable import PeeksyCore

/// Collects whatever the router delivered. A class because the router's
/// `Deliver` closure is `@Sendable` and must not capture a value type.
final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var envelopes: [HookEnvelope] = []

    func add(_ e: HookEnvelope) {
        lock.lock()
        envelopes.append(e)
        lock.unlock()
    }

    var all: [HookEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return envelopes
    }
}

@Suite("EventRouter")
struct EventRouterTests {
    private func makeRouter(sessions: Int = 0) -> (EventRouter, Collected) {
        let collected = Collected()
        let router = EventRouter(
            clock: { t0 },
            pid: 4242,
            deliver: { collected.add($0) },
            sessionCount: { sessions }
        )
        return (router, collected)
    }

    private func post(_ body: String, to path: String = "/v1/event/claude-code") -> HTTPParse.Request {
        HTTPParse.Request(method: "POST", path: path, body: Data(body.utf8))
    }

    private func text(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    @Test("a good event is delivered and answered 204")
    func goodEvent() {
        let (router, collected) = makeRouter()
        let response = text(
            router.respond(
                to: post(#"{"session_id":"abc","hook_event_name":"PreToolUse","_meta":{"pid":9,"tty":"ttys003"}}"#)
            )
        )

        #expect(response.hasPrefix("HTTP/1.1 204 No Content\r\n"))
        #expect(collected.all.count == 1)
        #expect(collected.all.first?.sessionID == "abc")
        #expect(collected.all.first?.receivedAt == t0) // the injected clock, not Date()
    }

    // FAIL-OPEN IS ABSOLUTE. Every one of these is a bug on our side or a
    // mangled payload, and every one still gets a 204: the hook runs inside the
    // user's coding session and must never see a failure or retry.
    @Test(
        "every broken event still gets 204",
        arguments: [
            "not json at all",
            "",
            "[]",
            "null",
            #"{"hook_event_name":"PreToolUse"}"#, // no session_id
            #"{"session_id":""}"#, // empty session_id
            #"{"session_id":"a","hook_event_name":"WhoKnows"}"#,
        ]
    )
    func brokenEventsStillGet204(body: String) {
        let (router, _) = makeRouter()
        #expect(text(router.respond(to: post(body))).hasPrefix("HTTP/1.1 204 No Content\r\n"))
    }

    @Test("an unknown source is 204 too, and delivers nothing")
    func unknownSource() {
        let (router, collected) = makeRouter()
        let response = text(router.respond(to: post(#"{"session_id":"a"}"#, to: "/v1/event/aider")))

        #expect(response.hasPrefix("HTTP/1.1 204 No Content\r\n"))
        #expect(collected.all.isEmpty)
    }

    @Test("a missing source component is 204 too")
    func emptySource() {
        let (router, collected) = makeRouter()

        #expect(text(router.respond(to: post("{}", to: "/v1/event/"))).hasPrefix("HTTP/1.1 204"))
        #expect(collected.all.isEmpty)
    }

    @Test("204 still carries Content-Length and Connection: close")
    func noContentHeaders() {
        let (router, _) = makeRouter()
        let response = text(router.respond(to: post("{}")))

        #expect(response.contains("Content-Length: 0\r\n"))
        #expect(response.contains("Connection: close\r\n"))
        #expect(response.hasSuffix("\r\n\r\n"))
    }

    @Test("health reports the version, the session count and our pid")
    func health() {
        let (router, _) = makeRouter(sessions: 3)
        let response = text(router.respond(to: HTTPParse.Request(method: "GET", path: "/v1/health", body: Data())))

        #expect(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(response.contains("Content-Type: application/json\r\n"))
        #expect(response.contains("Connection: close\r\n"))
        #expect(response.hasSuffix(#"{"ok":true,"version":"0.1.0","sessions":3,"pid":4242}"#))
        #expect(response.contains("Content-Length: 53\r\n"))
    }

    @Test("the health body is valid JSON")
    func healthIsValidJSON() throws {
        let (router, _) = makeRouter(sessions: 7)
        let response = router.respond(to: HTTPParse.Request(method: "GET", path: "/v1/health", body: Data()))
        let separator = try #require(response.range(of: Data("\r\n\r\n".utf8)))
        let object = try JSONSerialization.jsonObject(with: Data(response[separator.upperBound...]))
        let json = try #require(object as? [String: Any])

        #expect(json["ok"] as? Bool == true)
        #expect(json["sessions"] as? Int == 7)
        #expect(json["pid"] as? Int == 4242)
        #expect(json["version"] as? String == "0.1.0")
    }

    @Test("anything else is 404 — and still closes the connection")
    func notFound() {
        let (router, _) = makeRouter()
        for request in [
            HTTPParse.Request(method: "GET", path: "/", body: Data()),
            HTTPParse.Request(method: "POST", path: "/v1/health", body: Data()),
            HTTPParse.Request(method: "GET", path: "/v1/event/claude-code", body: Data()),
            HTTPParse.Request(method: "DELETE", path: "/v1/sessions", body: Data()),
        ] {
            let response = text(router.respond(to: request))
            #expect(response.hasPrefix("HTTP/1.1 404 Not Found\r\n"), "\(request.method) \(request.path)")
            #expect(response.contains("Connection: close\r\n"))
            #expect(response.contains("Content-Length: 10\r\n"))
        }
    }

    @Test("routing into a live registry produces the state the UI will render")
    func endToEndIntoRegistry() {
        let box = RegistryHarness()
        let router = EventRouter(
            clock: { t0 },
            deliver: { box.apply($0) },
            sessionCount: { box.count }
        )

        _ = router.respond(
            to: post(
                """
                {"_meta":{"pid":77,"tty":"ttys007"},"session_id":"abc",
                 "cwd":"/Users/x/Desktop/TestRepo/peeksy","hook_event_name":"PreToolUse",
                 "tool_name":"Bash","tool_input":{"command":"npm test"}}
                """
            )
        )

        #expect(box.count == 1)
        let s = box.session("abc")
        #expect(s?.state == .working)
        #expect(s?.tty == "ttys007")
        #expect(s?.projectDisplay == "TestRepo/peeksy")
        #expect(s?.lastToolSummary == "Bash: npm test")
    }
}

/// Stands in for the daemon's `RegistryBox`: the registry is a struct, so
/// somebody has to own it behind a lock.
final class RegistryHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var registry = SessionRegistry(isPidAlive: { _ in true })

    func apply(_ e: HookEnvelope) {
        lock.lock()
        registry.apply(e, now: e.receivedAt)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return registry.sessions.count
    }

    func session(_ id: String) -> Session? {
        lock.lock()
        defer { lock.unlock() }
        return registry[id]
    }
}
