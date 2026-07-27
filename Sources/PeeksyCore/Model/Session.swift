import Foundation

/// One tracked agent session.
public struct Session: Sendable, Equatable, Identifiable {
    /// The agent's session id (ACP calls this `sessionId`), or `"boot:<pid>"`
    /// pre-adoption.
    public let id: String
    public let source: AgentSource
    public var cwd: String?
    /// Bare form, `"ttys003"` — never `/dev/ttys003`.
    public var tty: String?
    public var pid: Int32?
    public var state: SessionState
    public var origin: SessionOrigin
    /// Last activity. Named to match the Agent Client Protocol's
    /// `SessionInfo.updatedAt` so a future ACP adapter is a mapping rather than
    /// a rename threaded through the core.
    public var updatedAt: Date
    public var createdAt: Date
    public var pendingPermission: PendingPermission?
    /// e.g. `"Bash: npm test"`.
    public var lastToolSummary: String?

    public init(
        id: String,
        source: AgentSource,
        cwd: String? = nil,
        tty: String? = nil,
        pid: Int32? = nil,
        state: SessionState = .idle,
        origin: SessionOrigin = .hook,
        updatedAt: Date,
        createdAt: Date,
        pendingPermission: PendingPermission? = nil,
        lastToolSummary: String? = nil
    ) {
        self.id = id
        self.source = source
        self.cwd = cwd
        self.tty = tty
        self.pid = pid
        self.state = state
        self.origin = origin
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.pendingPermission = pendingPermission
        self.lastToolSummary = lastToolSummary
    }

    /// Human label for the project this session is working in, e.g.
    /// `"TestRepo/peeksy"`.
    public var projectDisplay: String? { ProjectLabel.display(cwd) }

    /// Stable grouping key for the project. Full path — see `ProjectLabel`.
    public var projectKey: String? { ProjectLabel.projectKey(cwd) }
}
