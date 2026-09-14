import Foundation
import Testing
@testable import PeeksyCore

@Suite("Codex integration")
struct CodexSupportTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ name: String, id: String = "same", turn: String? = "turn-1",
                       tool: String? = nil, summary: String? = nil, call: String? = nil,
                       dedicated: Bool? = true) -> HookEnvelope {
        HookEnvelope(source: .codex, sessionID: id, hookEventName: name,
                     cwd: "/work/project", toolName: tool, toolSummary: summary,
                     pid: 101, tty: "ttys001", receivedAt: now,
                     turnID: turn, toolUseID: call, dedicatedProcess: dedicated)
    }

    @Test("Codex maps native hook fields and never reads its unstable transcript")
    func normalizes() throws {
        let raw = try #require(RawPayload(Data(#"{"session_id":"thread-1","hook_event_name":"PreToolUse","turn_id":"turn-1","tool_use_id":"call-1","cwd":"/p","transcript_path":"/private/chat.jsonl","tool_name":"Bash","tool_input":{"command":"swift test"},"_meta":{"pid":101,"tty":"/dev/ttys001","dedicated_process":true}}"#.utf8)))
        let e = try #require(CodexAdapter.normalize(raw, now: now))
        #expect(e.source == .codex)
        #expect(e.key == "codex:thread-1")
        #expect(e.turnID == "turn-1")
        #expect(e.toolUseID == "call-1")
        #expect(e.toolSummary == "Bash: swift test")
        #expect(e.tty == "ttys001")
        #expect(e.dedicatedProcess == true)
        #expect(e.transcriptPath == nil)
    }

    @Test("Missing identities and parent-scoped subagent events are dropped")
    func rejectsUnusableEvents() throws {
        for json in [#"{"hook_event_name":"Stop"}"#,
                     #"{"session_id":" ","hook_event_name":"Stop"}"#,
                     #"{"session_id":"parent","hook_event_name":"SubagentStop"}"#] {
            #expect(CodexAdapter.normalize(try #require(RawPayload(Data(json.utf8))), now: now) == nil)
        }
    }

    @Test("Identical native IDs coexist across agents, including independent removal")
    func sourceIdentity() {
        var r = SessionRegistry()
        r.apply(HookEnvelope(source: .claudeCode, sessionID: "same", hookEventName: "Stop", receivedAt: now), now: now)
        r.apply(event("UserPromptSubmit"), now: now)
        #expect(r.sessions.count == 2)
        #expect(r["same"]?.state == .done)
        #expect(r["same", source: .codex]?.state == .working)
        let removed = r.remove(id: "same", source: .codex)
        #expect(removed)
        #expect(r["same"] != nil)
    }

    @Test("Bootstrap adoption is restricted to the same source even on the same tty")
    func adoption() {
        var r = SessionRegistry()
        let found = [DiscoveredProcess(pid: 101, tty: "ttys001", cwd: "/p")]
        r.seed(found, source: .claudeCode, now: now)
        r.seed(found, source: .codex, now: now)
        #expect(r.sessions.count == 2)
        r.apply(event("UserPromptSubmit"), now: now)
        #expect(r["boot:101"]?.origin == .bootstrap)
        #expect(r["boot:101", source: .codex] == nil)
        #expect(r["same", source: .codex]?.origin == .hook)
        #expect(r.sessions.count == 2)
    }

    @Test("Lifecycle, interruption and completion use the shared states")
    func lifecycle() {
        var r = SessionRegistry()
        for (name, state) in [("SessionStart", SessionState.idle), ("UserPromptSubmit", .working),
                              ("PermissionRequest", .needsAttention), ("Interrupt", .idle),
                              ("UserPromptSubmit", .working), ("Stop", .done)] {
            r.apply(event(name), now: now)
            #expect(r["same", source: .codex]?.state == state)
        }
        #expect(r["same", source: .codex]?.pendingPermission == nil)
        r.apply(event("SessionEnd"), now: now)
        #expect(r.sessions.isEmpty)
    }

    @Test("Late progress cannot reopen a completed or ended turn")
    func lateProgress() {
        var r = SessionRegistry()
        r.apply(event("Stop"), now: now)
        r.apply(event("PostToolUse"), now: now.addingTimeInterval(1))
        #expect(r["same", source: .codex]?.state == .done)
        #expect(r["same", source: .codex]?.updatedAt == now)
        r.apply(event("SessionEnd"), now: now)
        r.apply(event("PreToolUse"), now: now)
        #expect(r.sessions.isEmpty)
        r.apply(event("SessionStart", turn: nil), now: now)
        #expect(r["same", source: .codex]?.state == .idle)
    }

    @Test("A previous turn's Stop does not finish the next turn")
    func oldStop() {
        var r = SessionRegistry()
        r.apply(event("UserPromptSubmit", turn: "new"), now: now)
        r.apply(event("Stop", turn: "old"), now: now)
        #expect(r["same", source: .codex]?.state == .working)
        r.apply(event("PostToolUse", turn: "old"), now: now)
        #expect(r["same", source: .codex]?.turnID == "new")
    }

    @Test("Unrelated parallel progress cannot clear a permission request")
    func concurrentPermissions() {
        var r = SessionRegistry()
        r.apply(event("PermissionRequest", tool: "Bash", summary: "Bash: deploy"), now: now)
        r.apply(event("PermissionRequest", tool: "apply_patch", summary: "Edit: config"), now: now)
        r.apply(event("PostToolUse", tool: "Bash", summary: "Bash: test", call: "test"), now: now)
        #expect(r["same", source: .codex]?.pendingPermissions.count == 2)
        #expect(r["same", source: .codex]?.state == .needsAttention)
        r.apply(event("PostToolUse", tool: "Bash", summary: "Bash: deploy", call: "deploy"), now: now)
        #expect(r["same", source: .codex]?.pendingPermissions.count == 1)
        r.apply(event("PostToolUse", tool: "apply_patch", summary: "Edit: config", call: "edit"), now: now)
        #expect(r["same", source: .codex]?.pendingPermission == nil)
        #expect(r["same", source: .codex]?.state == .working)
    }

    @Test("Shared hosts age out even when codex itself is alive; terminal sessions survive")
    func liveness() {
        var r = SessionRegistry(isPidAlive: { _ in true })
        r.apply(event("Stop", id: "shared", dedicated: false), now: now)
        r.apply(event("Stop", id: "terminal", dedicated: true), now: now)
        r.agentPidScan = AgentPidScan(pids: [101], at: now.addingTimeInterval(600))
        let result = r.reap(now: now.addingTimeInterval(600))
        #expect(result.removed == ["codex:shared"])
        #expect(r["terminal", source: .codex] != nil)
    }

    @Test("Rows distinguish agents and title lookup uses source-qualified keys")
    func labels() {
        let a = Session(id: "same", source: .claudeCode, cwd: "/p", updatedAt: now, createdAt: now)
        let b = Session(id: "same", source: .codex, cwd: "/p", updatedAt: now, createdAt: now)
        let rows = SessionRowTextBuilder.build(sessions: [a, b],
            taskTitle: { $0 == a.key ? "Claude title" : nil }, ownerName: { _ in nil })
        #expect(rows[0].title == "Claude title")
        #expect(rows[1].title.contains("Codex"))
        #expect(rows[1].title != "Claude title")
    }

    @Test("Router accepts Codex and malformed events remain fail-open")
    func router() {
        let router = EventRouter(deliver: { _ in }, sessionCount: { 0 })
        #expect(AgentRegistry.adapter(forPathComponent: "codex")?.source == .codex)
        for body in ["{", "{}", #"{"session_id":"s","hook_event_name":"Stop"}"#] {
            let response = router.respond(to: HTTPParse.Request(method: "POST", path: "/v1/event/codex", body: Data(body.utf8)))
            #expect(String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 204"))
        }
    }
}

@Suite("Codex hook installation")
struct CodexInstallTests {
    @Test("Custom Codex home and script paths are independent of Claude settings")
    func paths() {
        let home = URL(fileURLWithPath: "/Users/Test User")
        #expect(AgentHookConfiguration.codex.settingsURL(home: home, environment: [:]).path == "/Users/Test User/.codex/hooks.json")
        #expect(AgentHookConfiguration.codex.settingsURL(home: home, environment: ["CODEX_HOME": "/tmp/custom codex"]).path == "/tmp/custom codex/hooks.json")
        #expect(AgentHookConfiguration.codex.scriptURL(home: home).lastPathComponent == "peeksy-codex-hook.sh")
    }

    @Test("Codex install and uninstall preserve all foreign configuration")
    func roundTrip() throws {
        let config = AgentHookConfiguration.codex
        let original: [String: Any] = ["description": "Keep me", "hooks": ["Stop": [HookSpec.group(command: "/other/hook", matcher: nil)]]]
        let command = "'/Users/Test User/.peeksy/peeksy-codex-hook.sh'"
        let plan = try SettingsMerge.install(into: original, command: command, events: config.events, source: .codex)
        #expect(plan.events(.added).count == 8)
        #expect(SettingsAudit.preservation(before: original, after: plan.merged, command: command, source: .codex).isClean)
        #expect(try SettingsMerge.install(into: plan.merged, command: command, events: config.events, source: .codex).isNoOp)
        let removed = try SettingsMerge.uninstall(from: plan.merged, command: command, events: config.events, source: .codex)
        #expect(SettingsAudit.canonical(removed.merged) == SettingsAudit.canonical(original))
        let hooks = try #require(plan.merged["hooks"] as? [String: Any])
        #expect(hooks["Notification"] == nil)
        #expect(hooks["PostToolUseFailure"] == nil)
    }

    @Test("Migrates only Codex-owned registrations and repairs its timeout")
    func migration() throws {
        let config = AgentHookConfiguration.codex
        let claude = HookSpec.group(command: "/old/peeksy-hook.sh", matcher: nil)
        let codex = HookSpec.group(command: "/old/peeksy-codex-hook.sh", matcher: nil)
        let original: [String: Any] = ["hooks": ["Stop": [claude, codex]]]
        let command = "/new/peeksy-codex-hook.sh"
        let plan = try SettingsMerge.install(into: original, command: command, events: config.events, source: .codex)
        #expect(plan.events(.repaired).contains("Stop"))
        #expect(SettingsAudit.preservation(before: original, after: plan.merged, command: command, source: .codex).isClean)
        #expect(!HookSpec.isOurCommand("/old/peeksy-hook.sh", desired: command, source: .codex))
    }

    @Test("A custom Codex hook path cannot take ownership of a Claude registration")
    func customOwnership() throws {
        let original: [String: Any] = ["hooks": ["Stop": [
            HookSpec.group(command: "/old/peeksy-hook.sh", matcher: nil),
            HookSpec.group(command: "/old/peeksy-codex-hook.sh", matcher: nil)
        ]]]
        let config = AgentHookConfiguration.codex
        let plan = try SettingsMerge.install(into: original, command: "/custom/observer.sh",
                                              events: config.events, source: .codex)
        #expect(plan.events(.repaired).contains("Stop"))
        #expect(SettingsAudit.preservation(before: original, after: plan.merged,
                                           command: "/custom/observer.sh", source: .codex).isClean)
        let hooks = try #require(plan.merged["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(SettingsAudit.canonical(stop[0]) == SettingsAudit.canonical(
            HookSpec.group(command: "/old/peeksy-hook.sh", matcher: nil)))
    }

    @Test("Installer previews, backs up, and refuses a changed file")
    func fileInstall() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("hooks.json")
        try Data(#"{"description":"original"}"#.utf8).write(to: url)
        let installer = AgentHookConfiguration.codex.installer(settings: url, command: "/tmp/peeksy-codex-hook.sh")
        let preview = try installer.preview()
        #expect(!preview.isNoOp)
        let backup = try #require(try installer.apply(preview))
        #expect(try String(contentsOf: backup, encoding: .utf8).contains("original"))
        #expect(installer.isInstalled())
        let uninstall = try installer.preview(.uninstall)
        try Data("{}".utf8).write(to: url)
        #expect(throws: HookInstaller.Failure.self) { try installer.apply(uninstall) }
    }
}
