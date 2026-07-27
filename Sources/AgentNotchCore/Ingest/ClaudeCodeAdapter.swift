import Foundation

/// Maps a Claude Code hook payload onto a `HookEnvelope`.
///
/// The shell hook injects `_meta` as the first key of the object Claude Code
/// hands it on stdin; everything else is Claude Code's own schema.
public enum ClaudeCodeAdapter: AgentAdapter {
    public static var source: AgentSource { .claudeCode }

    public static var processNames: Set<String> { ["claude"] }

    public static func normalize(_ raw: RawPayload, now: Date) -> HookEnvelope? {
        // No session id, no session. Everything downstream is keyed on it.
        guard let sessionID = nonEmpty(raw.string("session_id")) else { return nil }

        let toolName = nonEmpty(raw.string("tool_name"))
        var toolSummary: String?
        var toolDetail: String?
        if let toolName {
            let described = ToolSummary.describe(toolName: toolName, input: raw.object("tool_input"))
            toolSummary = described.summary
            toolDetail = described.detail
        }

        // Claude Code has shipped both spellings; accept either.
        let permissionRequestID =
            nonEmpty(raw.string("permission_request_id")) ?? nonEmpty(raw.string("request_id"))

        return HookEnvelope(
            source: source,
            sessionID: sessionID,
            // Missing event name -> "" -> `default:` in the state machine, which
            // bumps updatedAt and changes nothing. Never a decode failure.
            hookEventName: nonEmpty(raw.string("hook_event_name")) ?? "",
            cwd: nonEmpty(raw.string("cwd")),
            transcriptPath: nonEmpty(raw.string("transcript_path")),
            notificationType: nonEmpty(raw.string("notification_type")),
            toolName: toolName,
            toolSummary: toolSummary,
            toolDetail: toolDetail,
            permissionRequestID: permissionRequestID,
            pid: pid(from: raw.path("_meta", "pid")),
            tty: bareTTY(RawPayload.asString(raw.path("_meta", "tty"))),
            receivedAt: now
        )
    }

    // MARK: - Local helpers

    private static func nonEmpty(_ s: String?) -> String? {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func pid(from any: Any?) -> Int32? {
        guard let value = RawPayload.asInt(any), value > 0, value <= Int(Int32.max) else { return nil }
        return Int32(value)
    }

    /// Normalise a tty to bare form.
    ///
    /// Local and private on purpose: the `Terminal` module owns the richer
    /// tty/terminal plumbing, and ingest must not depend on it — a hook event
    /// has to normalise identically whether or not anything else is loaded.
    /// `ps -o tty=` prints `??` for a process with no controlling terminal and
    /// the shell hook substitutes `?`, so both mean "unknown", not "a tty named
    /// question mark".
    private static func bareTTY(_ raw: String?) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.hasPrefix("/dev/") { t = String(t.dropFirst("/dev/".count)) }
        switch t {
        case "", "??", "?", "-": return nil
        default: return t
        }
    }
}
