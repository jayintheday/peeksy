import Dispatch
import Foundation
import Testing
@testable import PeeksyCore

/// Exercise the shipped shell bridge through a real socket, not a second
/// implementation of its JSON encoder. Only process discovery is fixture-backed.
@Suite("Codex shell bridge")
struct CodexBridgeTests {
    private var script: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("hooks/peeksy-codex-hook.sh")
    }

    private func run(socket: URL, path: String? = nil, payload: String) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PEEKSY_SOCK"] = socket.path
        if let path { environment["PATH"] = path }
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: bytes, as: UTF8.self))
    }

    @Test("Missing socket exits silently before running any external command")
    func absent() throws {
        let (status, output) = try run(socket: URL(fileURLWithPath: "/tmp/peeksy-absent-\(UUID().uuidString)"),
                                       path: "/nonexistent", payload: "{}")
        #expect(status == 0)
        #expect(output.isEmpty)
    }

    @Test("Native and shared hosts deliver usable metadata", arguments: [false, true])
    func delivery(shared: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ps = dir.appendingPathComponent("ps")
        // First inspect an intermediate shell; its parent is the native binary.
        let fixture = """
        #!/bin/sh
        case "$*" in
            *args=*) echo '/opt/codex\(shared ? " app-server" : "")' ;;
            *'-p 4242 '*) echo '1 ttys007 /opt/codex' ;;
            *) echo '4242 ttys007 /bin/sh' ;;
        esac
        """
        try Data(fixture.utf8).write(to: ps)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ps.path)
        let box = CodexEnvelopeBox()
        let router = EventRouter(deliver: { box.append($0) }, sessionCount: { 0 })
        let socket = URL(fileURLWithPath: "/tmp/peeksy-codex-\(UUID().uuidString).sock")
        let server = UnixSocketServer(path: socket, queue: DispatchQueue(label: "codex-test")) { router.respond(to: $0) }
        try server.start()
        defer { server.stop() }
        let (status, output) = try run(socket: socket, path: dir.path + ":/usr/bin:/bin", payload: #"{"session_id":"session","hook_event_name":"PermissionRequest","turn_id":"turn","tool_name":"Bash","tool_input":{"command":"echo \"quoted\"\nnext"}}"#)
        #expect(status == 0)
        #expect(output.isEmpty) // Must never approve, block, or inject model context.
        let e = try #require(box.first)
        #expect(e.pid == 4242)
        #expect(e.tty == "ttys007")
        #expect(e.dedicatedProcess == !shared)
        #expect(e.toolSummary == "Bash: echo \"quoted\" next")
        var registry = SessionRegistry()
        registry.apply(e, now: e.receivedAt)
        #expect(registry["session", source: .codex]?.state == .needsAttention)
    }

    @Test("Process bootstrap excludes app servers, remote UIs and helper executables")
    func processDiscovery() {
        let listing = """
        1 0 ttys001 /usr/local/bin/codex
        2 0 ttys002 /usr/local/bin/codex
        3 0 ttys003 /usr/local/bin/codex-code-mode-host
        4 0 ?? /Applications/ChatGPT.app/Contents/Resources/codex
        """
        let found = ProcessScan.parsePS(listing, names: CodexAdapter.processNames)
        #expect(found.map(\.pid) == [1, 2])
        let pids = ProcessScan.dedicatedCodexPids("""
        1 /usr/local/bin/codex
        2 /usr/local/bin/codex app-server
        5 /usr/local/bin/codex --remote unix://
        6 /usr/local/bin/codex --remote=unix://
        """)
        #expect(pids == [1])
    }
}

private final class CodexEnvelopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var envelopes: [HookEnvelope] = []
    func append(_ e: HookEnvelope) { lock.lock(); defer { lock.unlock() }; envelopes.append(e) }
    var first: HookEnvelope? { lock.lock(); defer { lock.unlock() }; return envelopes.first }
}
