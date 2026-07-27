import Foundation
import Testing

@testable import PeeksyCore

@Suite("ClaudeCodeAdapter")
struct ClaudeCodeAdapterTests {
    private func normalize(_ json: String) -> HookEnvelope? {
        guard let raw = RawPayload(Data(json.utf8)) else { return nil }
        return ClaudeCodeAdapter.normalize(raw, now: t0)
    }

    @Test("a realistic PreToolUse payload maps onto an envelope")
    func preToolUse() throws {
        // Shape as the shell hook emits it: _meta injected as the FIRST key.
        let e = try #require(
            normalize(
                """
                {"_meta":{"pid":4242,"tty":"ttys003"},
                 "session_id":"9f3c1a2e-0000-4000-8000-000000000001",
                 "transcript_path":"/Users/x/.claude/projects/foo/9f3c.jsonl",
                 "cwd":"/Users/x/Desktop/TestRepo/peeksy",
                 "hook_event_name":"PreToolUse",
                 "tool_name":"Bash",
                 "tool_input":{"command":"npm test","description":"Run the suite"}}
                """
            )
        )

        #expect(e.source == .claudeCode)
        #expect(e.sessionID == "9f3c1a2e-0000-4000-8000-000000000001")
        #expect(e.hookEventName == "PreToolUse")
        #expect(e.cwd == "/Users/x/Desktop/TestRepo/peeksy")
        #expect(e.transcriptPath == "/Users/x/.claude/projects/foo/9f3c.jsonl")
        #expect(e.toolName == "Bash")
        #expect(e.toolSummary == "Bash: npm test")
        #expect(e.pid == 4242)
        #expect(e.tty == "ttys003")
        #expect(e.receivedAt == t0)
    }

    @Test("a payload with no session_id is dropped — we cannot key anything on it")
    func missingSessionID() {
        #expect(normalize(#"{"hook_event_name":"PreToolUse","cwd":"/tmp"}"#) == nil)
        #expect(normalize(#"{"session_id":"","hook_event_name":"Stop"}"#) == nil)
        #expect(normalize(#"{"session_id":"   ","hook_event_name":"Stop"}"#) == nil)
        #expect(normalize(#"{"session_id":null,"hook_event_name":"Stop"}"#) == nil)
    }

    @Test("bytes that are not a JSON object produce no payload at all")
    func notAJSONObject() {
        #expect(RawPayload(Data("not json".utf8)) == nil)
        #expect(RawPayload(Data("[1,2,3]".utf8)) == nil)
        #expect(RawPayload(Data("".utf8)) == nil)
        #expect(RawPayload(Data(#"{"unterminated": "#.utf8)) == nil)
    }

    @Test("an unknown hook_event_name survives normalisation — it must reach `default:`")
    func unknownEventSurvives() throws {
        let e = try #require(normalize(#"{"session_id":"s","hook_event_name":"SomethingNew2027"}"#))
        #expect(e.hookEventName == "SomethingNew2027")
    }

    @Test("a missing hook_event_name normalises to empty rather than failing")
    func missingEventName() throws {
        let e = try #require(normalize(#"{"session_id":"s"}"#))
        #expect(e.hookEventName == "")
    }

    @Test("Notification payloads carry the notification_type through")
    func notification() throws {
        let e = try #require(
            normalize(
                #"{"session_id":"s","hook_event_name":"Notification","notification_type":"permission_prompt"}"#
            )
        )
        #expect(e.notificationType == "permission_prompt")
        #expect(HookEnvelope.attentionNotifications.contains(e.notificationType ?? ""))
    }

    @Test("permission_request_id and the legacy request_id are both accepted")
    func permissionRequestIDSpellings() throws {
        let modern = try #require(
            normalize(#"{"session_id":"s","hook_event_name":"PermissionRequest","permission_request_id":"a"}"#)
        )
        #expect(modern.permissionRequestID == "a")

        let legacy = try #require(
            normalize(#"{"session_id":"s","hook_event_name":"PermissionRequest","request_id":"b"}"#)
        )
        #expect(legacy.permissionRequestID == "b")
    }

    @Test("a /dev-prefixed tty is reduced to bare form")
    func stripsDevPrefix() throws {
        let e = try #require(normalize(#"{"session_id":"s","_meta":{"pid":1,"tty":"/dev/ttys009"}}"#))
        #expect(e.tty == "ttys009")
    }

    @Test(
        "every unknown-tty marker the hook can emit becomes nil",
        arguments: ["", "??", "?", "-", "   ", "/dev/"]
    )
    func unknownTTYMarkers(marker: String) throws {
        let e = try #require(normalize(#"{"session_id":"s","_meta":{"pid":1,"tty":"\#(marker)"}}"#))
        #expect(e.tty == nil)
    }

    @Test("a missing _meta is not an error — the hook may have failed to read ps")
    func missingMeta() throws {
        let e = try #require(normalize(#"{"session_id":"s","hook_event_name":"Stop"}"#))
        #expect(e.pid == nil)
        #expect(e.tty == nil)
    }

    @Test("a pid written as a string is still a pid")
    func pidAsString() throws {
        let e = try #require(normalize(#"{"session_id":"s","_meta":{"pid":"4242","tty":"ttys003"}}"#))
        #expect(e.pid == 4242)
    }

    @Test("a nonsense pid is dropped rather than trusted")
    func badPid() throws {
        #expect(try #require(normalize(#"{"session_id":"s","_meta":{"pid":0}}"#)).pid == nil)
        #expect(try #require(normalize(#"{"session_id":"s","_meta":{"pid":-9}}"#)).pid == nil)
        #expect(try #require(normalize(#"{"session_id":"s","_meta":{"pid":"nope"}}"#)).pid == nil)
        #expect(try #require(normalize(#"{"session_id":"s","_meta":{"pid":99999999999}}"#)).pid == nil)
    }

    @Test("arbitrary nested tool_input is read for what we know and ignored otherwise")
    func arbitraryToolInput() throws {
        let e = try #require(
            normalize(
                """
                {"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Edit",
                 "tool_input":{"file_path":"/a/b/c.swift",
                               "edits":[{"old_string":"x","new_string":"y"}],
                               "nested":{"deep":{"deeper":[1,2,3]}}}}
                """
            )
        )
        #expect(e.toolSummary == "Edit: /a/b/c.swift")
    }

    @Test("a tool with no recognised input key summarises as the bare tool name")
    func toolWithoutRecognisedKey() throws {
        let e = try #require(
            normalize(#"{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"TodoWrite","tool_input":{"todos":[]}}"#)
        )
        #expect(e.toolSummary == "TodoWrite")
        #expect(e.toolDetail == "TodoWrite")
    }

    @Test("an event with no tool at all carries no summary")
    func noTool() throws {
        let e = try #require(normalize(#"{"session_id":"s","hook_event_name":"Stop"}"#))
        #expect(e.toolName == nil)
        #expect(e.toolSummary == nil)
        #expect(e.toolDetail == nil)
    }

    @Test("adapters are discoverable by source, route component and process name")
    func registryLookup() {
        #expect(AgentRegistry.adapter(for: .claudeCode) != nil)
        #expect(AgentRegistry.adapter(forPathComponent: "claude-code") != nil)
        #expect(AgentRegistry.adapter(forPathComponent: "claude-code/") != nil)
        #expect(AgentRegistry.adapter(forPathComponent: "CLAUDE-CODE") != nil)
        #expect(AgentRegistry.adapter(forPathComponent: "cursor") == nil)
        #expect(AgentRegistry.adapter(forPathComponent: "") == nil)
        #expect(AgentRegistry.adapter(forProcessName: "claude") != nil)
        #expect(AgentRegistry.adapter(forProcessName: "node") == nil)
    }

    @Test("the source raw value is the route component and the display name is separate")
    func sourceSpelling() {
        #expect(AgentSource.claudeCode.rawValue == "claude-code")
        #expect(AgentSource.claudeCode.displayName == "Claude Code")
        #expect(ClaudeCodeAdapter.processNames == ["claude"])
    }
}
