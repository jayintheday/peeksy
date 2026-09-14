import Foundation
import Testing

@testable import PeeksyCore

// MARK: - The second agent

/// A whole agent, in forty lines, living entirely in the test target.
///
/// THIS FILE IS THE TEST. Not the assertions below it — the file itself. The
/// core's claim is that adding an agent is a compile-time checklist and touches
/// nothing else, so what matters is what had to change to make a second one
/// work:
///
///   1. `AgentSource` gained a case (`HookEnvelope.source` is typed);
///   2. `EventRouter` gained an injectable adapter lookup;
///   3. this adapter.
///
/// And what did NOT change: `Session`, `SessionState`, `SessionOrigin`,
/// `SessionRegistry`, `HookEnvelope`, `ReapPolicy`, `SliceRow`, or any view.
/// Had any of those needed an edit, the seam would be in the wrong place and
/// this file would be the place to say so.
///
/// The wire format is deliberately NOTHING like Claude Code's — different key
/// names, a different envelope shape, a nested location object, a string pid,
/// and lowercase event names — because an adapter that only works for a format
/// that already looks like ours proves nothing.
enum MockAdapter: AgentAdapter {
    static var source: AgentSource { .mock }
    static var processNames: Set<String> { ["mock-agent"] }

    static func normalize(_ raw: RawPayload, now: Date) -> HookEnvelope? {
        guard let id = raw.string("conversation"), !id.isEmpty else { return nil }

        return HookEnvelope(
            source: source,
            sessionID: id,
            hookEventName: mapEvent(raw.string("kind")),
            cwd: RawPayload.asString(raw.path("location", "directory")),
            notificationType: raw.string("why"),
            toolName: raw.string("action"),
            toolSummary: raw.string("action").map { "Mock: \($0)" },
            // A pid that arrives as a STRING. `RawPayload` coerces, which is why
            // the coercion lives there and not in `ClaudeCodeAdapter`.
            pid: RawPayload.asInt(raw.path("location", "process")).map(Int32.init),
            tty: RawPayload.asString(raw.path("location", "terminal")),
            receivedAt: now
        )
    }

    /// The agent's vocabulary, mapped onto ours. Unknown verbs fall through to
    /// `""`, which the registry's `default:` treats as activity — never a
    /// decode failure.
    private static func mapEvent(_ kind: String?) -> String {
        switch kind {
        case "begin": return "SessionStart"
        case "thinking": return "UserPromptSubmit"
        case "acting": return "PreToolUse"
        case "asking": return "PermissionRequest"
        case "settled": return "Stop"
        case "finish": return "SessionEnd"
        default: return kind ?? ""
        }
    }
}

private let mockLookup: EventRouter.AdapterLookup = { component in
    component.lowercased() == "mock" ? MockAdapter.self : AgentRegistry.adapter(forPathComponent: component)
}

// MARK: - Tests

@Suite("M6: the adapter seam holds for a second agent")
struct MockAdapterSeamTests {

    private func envelope(_ json: String) -> HookEnvelope? {
        MockAdapter.normalize(RawPayload(Data(json.utf8))!, now: t0)
    }

    @Test("a wire format nothing like Claude Code's maps onto HookEnvelope")
    func normalizesAForeignFormat() throws {
        let e = try #require(envelope("""
        {"conversation":"conv-9","kind":"acting","action":"shell",
         "location":{"directory":"/Users/x/proj","terminal":"ttys007","process":"4242"}}
        """))

        #expect(e.source == .mock)
        #expect(e.sessionID == "conv-9")
        #expect(e.hookEventName == "PreToolUse")
        #expect(e.cwd == "/Users/x/proj")
        #expect(e.tty == "ttys007")
        #expect(e.pid == 4242)
        #expect(e.toolSummary == "Mock: shell")
    }

    @Test("no session id means drop, exactly as for Claude Code")
    func dropsWithoutASessionID() {
        #expect(envelope(#"{"kind":"acting"}"#) == nil)
        #expect(envelope(#"{"conversation":"","kind":"acting"}"#) == nil)
    }

    @Test("the registry runs a mock session through every state, unmodified")
    func registryNeedsNoChanges() throws {
        var r = registry(alive: [4242])

        // The point: `SessionRegistry` has no idea a second agent exists. It
        // sees `HookEnvelope`, which is the whole seam.
        r.apply(try #require(envelope(#"{"conversation":"c1","kind":"begin","location":{"terminal":"ttys007","process":"4242"}}"#)), now: t0)
        #expect(r["c1", source: .mock]?.state == .idle)
        #expect(r["c1", source: .mock]?.source == .mock)

        r.apply(try #require(envelope(#"{"conversation":"c1","kind":"acting","action":"shell"}"#)), now: t0)
        #expect(r["c1", source: .mock]?.state == .working)
        #expect(r["c1", source: .mock]?.lastToolSummary == "Mock: shell")

        r.apply(try #require(envelope(#"{"conversation":"c1","kind":"asking","action":"write"}"#)), now: t0)
        #expect(r["c1", source: .mock]?.state == .needsAttention)
        #expect(r["c1", source: .mock]?.pendingPermission != nil)

        // The keyboard backstop, which is Claude-Code-shaped reasoning, still
        // applies — because it is a property of the ENVELOPE, not of the agent.
        r.apply(try #require(envelope(#"{"conversation":"c1","kind":"acting","action":"shell"}"#)), now: t0)
        #expect(r["c1", source: .mock]?.pendingPermission == nil)

        r.apply(try #require(envelope(#"{"conversation":"c1","kind":"settled"}"#)), now: t0)
        #expect(r["c1", source: .mock]?.state == .done)

        r.apply(try #require(envelope(#"{"conversation":"c1","kind":"finish"}"#)), now: t0)
        #expect(r.sessions.isEmpty)
    }

    @Test("an unknown verb bumps activity and changes nothing else")
    func unknownVerbIsNotAFailure() throws {
        var r = registry()
        r.apply(try #require(envelope(#"{"conversation":"c1","kind":"begin"}"#)), now: t0)
        let later = t0.addingTimeInterval(30)
        r.apply(try #require(envelope(#"{"conversation":"c1","kind":"teleported"}"#)), now: later)

        #expect(r["c1", source: .mock]?.state == .idle)
        #expect(r["c1", source: .mock]?.updatedAt == later)
    }

    @Test("two agents coexist in one registry and sort by state, not by source")
    func twoAgentsInOneList() throws {
        var r = registry()
        r.apply(env("Stop", id: "claude-1"), now: t0)
        r.apply(try #require(envelope(#"{"conversation":"mock-1","kind":"asking","action":"write"}"#)), now: t0)

        let ordered = r.ordered()
        #expect(ordered.count == 2)
        // needsAttention outranks done regardless of who raised it.
        #expect(ordered[0].id == "mock-1")
        #expect(ordered[0].source == .mock)
        #expect(ordered[1].source == .claudeCode)
        #expect(r.aggregate().attentionCount == 1)
    }

    @Test("POST /v1/event/mock reaches the registry over a real socket")
    func endToEndOverTheSocket() throws {
        // /tmp, not the scratchpad: sun_path is 104 bytes and the agent
        // scratchpad path is 123.
        let socket = URL(fileURLWithPath: "/tmp/peeksy-mock-\(getpid()).sock")
        try? FileManager.default.removeItem(at: socket)
        defer { try? FileManager.default.removeItem(at: socket) }

        let box = EnvelopeBox()
        let router = EventRouter(
            clock: { t0 },
            adapterLookup: mockLookup,
            deliver: { box.append($0) },
            sessionCount: { box.count }
        )
        let server = UnixSocketServer(
            path: socket,
            queue: DispatchQueue(label: "mock-seam")
        ) { router.respond(to: $0) }
        try server.start()
        defer { server.stop() }

        let status = post(
            """
            {"conversation":"wire-1","kind":"acting","action":"shell",
             "location":{"terminal":"ttys011","process":9001}}
            """,
            to: socket, path: "/v1/event/mock")
        #expect(status == 204)

        let delivered = try #require(box.wait())
        #expect(delivered.source == .mock)
        #expect(delivered.sessionID == "wire-1")
        #expect(delivered.tty == "ttys011")
        #expect(delivered.pid == 9001)

        var r = registry()
        r.apply(delivered, now: t0)
        #expect(r["wire-1", source: .mock]?.state == .working)
    }

    @Test("the SHIPPED app treats /v1/event/mock as unknown, and still answers 204")
    func mockIsInertInProduction() throws {
        // No `mock` in AgentRegistry.all, so the default lookup finds nothing.
        // Fail-open means the hook still sees a 2xx: a non-2xx here would make
        // curl start reporting failures inside somebody's coding session.
        #expect(AgentRegistry.adapter(forPathComponent: "mock") == nil)
        #expect(!AgentRegistry.all.contains { $0.source == .mock })

        let box = EnvelopeBox()
        let router = EventRouter(deliver: { box.append($0) }, sessionCount: { 0 })
        let response = router.respond(to: HTTPParse.Request(
            method: "POST", path: "/v1/event/mock",
            body: Data(#"{"conversation":"x","kind":"acting"}"#.utf8)))

        #expect(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 204 "))
        #expect(box.count == 0)
    }

    @Test("every AgentSource still round-trips through its raw value")
    func sourcesRoundTrip() {
        for source in AgentSource.allCases {
            #expect(AgentSource(rawValue: source.rawValue) == source)
            #expect(!source.displayName.isEmpty)
        }
        #expect(AgentSource(rawValue: "mock") == .mock)
    }
}

// MARK: - Test plumbing

/// Collects envelopes delivered from the socket's io queue.
private final class EnvelopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var envelopes: [HookEnvelope] = []

    func append(_ envelope: HookEnvelope) {
        lock.lock(); envelopes.append(envelope); lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return envelopes.count
    }

    /// Poll rather than use an expectation: the delivery hop is a queue, not an
    /// actor, and a busy-wait with a deadline keeps the test synchronous.
    func wait(timeout: TimeInterval = 2) -> HookEnvelope? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let first = envelopes.first
            lock.unlock()
            if let first { return first }
            usleep(2_000)
        }
        return nil
    }
}

/// Minimal HTTP POST over a Unix domain socket. Returns the status code.
private func post(_ body: String, to socket: URL, path: String) -> Int? {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socket.path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: pathBytes)
    }

    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) }
    }
    guard connected == 0 else { return nil }

    let payload = Data(body.utf8)
    let request = "POST \(path) HTTP/1.1\r\nHost: peeksy\r\n"
        + "Content-Type: application/json\r\nContent-Length: \(payload.count)\r\n\r\n"
    var out = Data(request.utf8)
    out.append(payload)
    _ = out.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }

    var buffer = [UInt8](repeating: 0, count: 512)
    let read = recv(fd, &buffer, buffer.count, 0)
    guard read > 0 else { return nil }
    let response = String(decoding: buffer[0..<read], as: UTF8.self)
    let fields = response.split(separator: " ")
    guard fields.count > 1 else { return nil }
    return Int(fields[1])
}
