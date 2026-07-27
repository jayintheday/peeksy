import Foundation

/// A normalised hook event: everything the registry needs, nothing it does not.
///
/// This is the seam. Adapters map their agent's wire format onto this; the
/// registry never sees agent-specific JSON.
public struct HookEnvelope: Sendable, Equatable {
    public let source: AgentSource
    /// REQUIRED. `AgentAdapter.normalize` returns `nil` without it — a session
    /// we cannot identify is a session we cannot show.
    public let sessionID: String
    /// A `String`, NOT an enum, deliberately: an unrecognised event from a
    /// future Claude Code version must hit `default:` in the state machine and
    /// still bump `updatedAt`. It must never fail to decode.
    public let hookEventName: String
    public let cwd: String?
    public let transcriptPath: String?
    public let notificationType: String?
    public let toolName: String?
    /// `ToolSummary.describe()`, ≤ 60 cols.
    public let toolSummary: String?
    /// Untruncated.
    public let toolDetail: String?
    public let permissionRequestID: String?
    public let pid: Int32?
    /// Normalised to bare `"ttys003"`.
    public let tty: String?
    public let receivedAt: Date

    /// Notification subtypes that mean "a human is needed".
    ///
    /// Anything else — a compaction notice, a plain info toast — is activity,
    /// not attention, and must leave the state alone.
    public static let attentionNotifications: Set<String> =
        ["permission_prompt", "idle_prompt", "agent_needs_input"]

    public init(
        source: AgentSource,
        sessionID: String,
        hookEventName: String,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        notificationType: String? = nil,
        toolName: String? = nil,
        toolSummary: String? = nil,
        toolDetail: String? = nil,
        permissionRequestID: String? = nil,
        pid: Int32? = nil,
        tty: String? = nil,
        receivedAt: Date
    ) {
        self.source = source
        self.sessionID = sessionID
        self.hookEventName = hookEventName
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.notificationType = notificationType
        self.toolName = toolName
        self.toolSummary = toolSummary
        self.toolDetail = toolDetail
        self.permissionRequestID = permissionRequestID
        self.pid = pid
        self.tty = tty
        self.receivedAt = receivedAt
    }
}
