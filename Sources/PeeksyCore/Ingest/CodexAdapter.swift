import Foundation

/// Codex lifecycle hooks share field names with Claude, but have their own
/// event coverage, turn identity, process ownership and transcript format.
public enum CodexAdapter: AgentAdapter {
    public static let source = AgentSource.codex
    public static let processNames: Set<String> = ["codex"]

    public static func normalize(_ raw: RawPayload, now: Date) -> HookEnvelope? {
        guard let base = ClaudeCodeAdapter.normalize(raw, now: now) else { return nil }
        let event = base.hookEventName
        // Subagent lifecycle events identify their parent. They must not finish
        // or reset the parent's row. Unknown events are observational activity.
        guard !["SubagentStart", "SubagentStop"].contains(event) else { return nil }
        func nonEmpty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }
        return HookEnvelope(
            source: source, sessionID: base.sessionID, hookEventName: event,
            cwd: base.cwd, notificationType: base.notificationType,
            toolName: base.toolName, toolSummary: base.toolSummary, toolDetail: base.toolDetail,
            permissionRequestID: base.permissionRequestID,
            pid: base.pid, tty: base.tty, receivedAt: now,
            turnID: nonEmpty(raw.string("turn_id")),
            toolUseID: nonEmpty(raw.string("tool_use_id")),
            dedicatedProcess: raw.path("_meta", "dedicated_process") as? Bool
        )
    }
}
