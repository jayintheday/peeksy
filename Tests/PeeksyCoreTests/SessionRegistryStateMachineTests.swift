import Foundation
import Testing

@testable import PeeksyCore

/// A fixed instant. Every test drives the clock explicitly — there is no
/// `Date()` anywhere in the registry, which is why none of these tests sleep.
let t0 = Date(timeIntervalSince1970: 1_700_000_000)

func env(
    _ event: String,
    id: String = "s1",
    cwd: String? = nil,
    tty: String? = nil,
    pid: Int32? = nil,
    notificationType: String? = nil,
    toolName: String? = nil,
    toolSummary: String? = nil,
    toolDetail: String? = nil,
    permissionRequestID: String? = nil,
    at: Date = t0
) -> HookEnvelope {
    HookEnvelope(
        source: .claudeCode,
        sessionID: id,
        hookEventName: event,
        cwd: cwd,
        notificationType: notificationType,
        toolName: toolName,
        toolSummary: toolSummary,
        toolDetail: toolDetail,
        permissionRequestID: permissionRequestID,
        pid: pid,
        tty: tty,
        receivedAt: at
    )
}

/// A registry whose pid liveness is a pure function of the injected set.
///
/// `agents` is the second half of the answer: which of those live pids are
/// agent processes rather than an IDE host that outlives its sessions. Left
/// `nil` it means "no sweep has landed", under which a live pid is simply
/// alive — the pre-sweep behaviour, and what most of these tests want.
func registry(
    alive: Set<Int32> = [],
    policy: ReapPolicy = .default,
    agents: AgentPidScan? = nil
) -> SessionRegistry {
    SessionRegistry(policy: policy, isPidAlive: { alive.contains($0) }, agentPidScan: agents)
}

@Suite("SessionRegistry: state machine")
struct SessionRegistryStateMachineTests {
    @Test("SessionStart registers an idle session")
    func sessionStart() {
        var r = registry()
        let result = r.apply(env("SessionStart", cwd: "/a/b", tty: "ttys003", pid: 42), now: t0)

        #expect(result == .updated("claude-code:s1"))
        #expect(r["s1"]?.state == .idle)
        #expect(r["s1"]?.origin == .hook)
        #expect(r["s1"]?.cwd == "/a/b")
        #expect(r["s1"]?.tty == "ttys003")
        #expect(r["s1"]?.pid == 42)
        #expect(r["s1"]?.createdAt == t0)
    }

    @Test(
        "every progress event means working",
        arguments: ["UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure"]
    )
    func progressEvents(event: String) {
        var r = registry()
        r.apply(env("SessionStart"), now: t0)
        r.apply(env(event), now: t0.addingTimeInterval(1))

        #expect(r["s1"]?.state == .working)
        #expect(r["s1"]?.updatedAt == t0.addingTimeInterval(1))
    }

    @Test("PermissionRequest raises attention and records the pending prompt")
    func permissionRequest() throws {
        var r = registry()
        r.apply(
            env(
                "PermissionRequest",
                toolName: "Bash",
                toolSummary: "Bash: rm -rf build",
                toolDetail: "Bash: rm -rf build && make clean",
                permissionRequestID: "req-7"
            ),
            now: t0
        )

        let pending = try #require(r["s1"]?.pendingPermission)
        #expect(r["s1"]?.state == .needsAttention)
        #expect(pending.requestID == "req-7")
        #expect(pending.toolName == "Bash")
        #expect(pending.summary == "Bash: rm -rf build")
        #expect(pending.detail == "Bash: rm -rf build && make clean")
        #expect(pending.receivedAt == t0)
    }

    @Test("a permission answered on the KEYBOARD is cleared by the next progress event")
    func keyboardAnsweredBackstop() {
        var r = registry()
        r.apply(env("PermissionRequest", permissionRequestID: "req-1"), now: t0)
        #expect(r["s1"]?.pendingPermission != nil)

        // The user hit "y" in the terminal. Claude Code never tells us the
        // prompt resolved; it just carries on. The next progress event is the
        // only signal we get.
        r.apply(env("PostToolUse"), now: t0.addingTimeInterval(2))

        #expect(r["s1"]?.pendingPermission == nil)
        #expect(r["s1"]?.state == .working)
    }

    @Test("Notification must NOT clear the pending permission it raised")
    func notificationDoesNotClearPending() {
        var r = registry()
        r.apply(env("PermissionRequest", permissionRequestID: "req-1"), now: t0)
        r.apply(env("Notification", notificationType: "permission_prompt"), now: t0.addingTimeInterval(1))

        #expect(r["s1"]?.pendingPermission?.requestID == "req-1")
        #expect(r["s1"]?.state == .needsAttention)
    }

    @Test(
        "attention notification types raise attention",
        arguments: ["permission_prompt", "idle_prompt", "agent_needs_input"]
    )
    func attentionNotifications(type: String) {
        var r = registry()
        r.apply(env("SessionStart"), now: t0)
        r.apply(env("Notification", notificationType: type), now: t0.addingTimeInterval(1))

        #expect(r["s1"]?.state == .needsAttention)
    }

    @Test("a non-attention Notification leaves state alone but still counts as activity")
    func nonAttentionNotification() {
        var r = registry()
        r.apply(env("PreToolUse"), now: t0)
        r.apply(env("Notification", notificationType: "compaction_started"), now: t0.addingTimeInterval(5))

        #expect(r["s1"]?.state == .working)
        #expect(r["s1"]?.updatedAt == t0.addingTimeInterval(5))
    }

    @Test("a Notification with no type at all is inert")
    func notificationWithNoType() {
        var r = registry()
        r.apply(env("SessionStart"), now: t0)
        r.apply(env("Notification"), now: t0.addingTimeInterval(1))

        #expect(r["s1"]?.state == .idle)
    }

    @Test("Stop means done and drops any pending permission")
    func stop() {
        var r = registry()
        r.apply(env("PermissionRequest", permissionRequestID: "req-1"), now: t0)
        r.apply(env("Stop"), now: t0.addingTimeInterval(1))

        #expect(r["s1"]?.state == .done)
        #expect(r["s1"]?.pendingPermission == nil)
    }

    @Test("SessionEnd removes the session")
    func sessionEnd() {
        var r = registry()
        r.apply(env("SessionStart"), now: t0)
        let result = r.apply(env("SessionEnd"), now: t0.addingTimeInterval(1))

        #expect(result == .removed("claude-code:s1"))
        #expect(r["s1"] == nil)
        #expect(r.sessions.isEmpty)
    }

    @Test("an unrecognised event from a future Claude Code bumps updatedAt and nothing else")
    func unknownEventIsInert() {
        var r = registry()
        r.apply(env("PreToolUse"), now: t0)
        let result = r.apply(env("SomeEventInventedNextYear"), now: t0.addingTimeInterval(30))

        #expect(result == .updated("claude-code:s1"))
        #expect(r["s1"]?.state == .working)
        #expect(r["s1"]?.updatedAt == t0.addingTimeInterval(30))
    }

    @Test("an empty event name is treated as an unknown event, never a failure")
    func emptyEventName() {
        var r = registry()
        r.apply(env("SessionStart"), now: t0)
        let result = r.apply(env(""), now: t0.addingTimeInterval(1))

        #expect(result == .updated("claude-code:s1"))
        #expect(r["s1"]?.state == .idle)
    }

    @Test("an event for an unknown id auto-registers it — the app can start mid-flight")
    func autoRegistersUnknownSession() {
        var r = registry()
        // No SessionStart: the session began before we launched.
        r.apply(env("PostToolUse", id: "late", cwd: "/x/y", pid: 99), now: t0)

        #expect(r["late"]?.state == .working)
        #expect(r["late"]?.origin == .hook)
        #expect(r["late"]?.createdAt == t0)
    }

    @Test("apply drops an empty session id")
    func emptySessionIDIsDropped() {
        var r = registry()
        let result = r.apply(env("SessionStart", id: ""), now: t0)

        #expect(result == .dropped(reason: "empty session id"))
        #expect(r.sessions.isEmpty)
    }

    @Test("metadata is non-nil-only: a late tty sticks and an early one is never nulled")
    func metadataIsNonNilOnly() {
        var r = registry()
        // SessionStart carries cwd but ps failed, so no tty.
        r.apply(env("SessionStart", cwd: "/a/b", tty: nil, pid: 7), now: t0)
        #expect(r["s1"]?.tty == nil)

        // A later event finally learns the tty.
        r.apply(env("PreToolUse", cwd: nil, tty: "ttys004", pid: nil), now: t0.addingTimeInterval(1))
        #expect(r["s1"]?.tty == "ttys004")
        #expect(r["s1"]?.cwd == "/a/b") // NOT nulled by the nil cwd
        #expect(r["s1"]?.pid == 7) // NOT nulled by the nil pid

        // And a still-later event with no tty must not lose it again.
        r.apply(env("PostToolUse"), now: t0.addingTimeInterval(2))
        #expect(r["s1"]?.tty == "ttys004")
    }

    @Test("lastToolSummary updates only when the event carries one")
    func lastToolSummarySticks() {
        var r = registry()
        r.apply(env("PreToolUse", toolName: "Bash", toolSummary: "Bash: npm test"), now: t0)
        #expect(r["s1"]?.lastToolSummary == "Bash: npm test")

        r.apply(env("Stop"), now: t0.addingTimeInterval(1))
        #expect(r["s1"]?.lastToolSummary == "Bash: npm test")
    }

    @Test("createdAt survives every subsequent event")
    func createdAtIsStable() {
        var r = registry()
        r.apply(env("SessionStart"), now: t0)
        r.apply(env("PreToolUse"), now: t0.addingTimeInterval(60))
        r.apply(env("Stop"), now: t0.addingTimeInterval(120))

        #expect(r["s1"]?.createdAt == t0)
        #expect(r["s1"]?.updatedAt == t0.addingTimeInterval(120))
    }
}
