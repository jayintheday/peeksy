import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// The timeouts that keep the list honest.
///
/// All of them are compared with `max(0, now.timeIntervalSince(x))` at the call
/// site — see `SessionRegistry.reap(now:)`.
///
/// Removal is split in two because our confidence is. A pid we watched die is a
/// fact and earns a short grace; a pid we cannot interpret — absent, or alive
/// but belonging to an IDE host rather than to the agent — is a guess and earns
/// a ceiling instead. Neither is destructive: a session that is really alive
/// puts its row back on its very next hook event.
public struct ReapPolicy: Sendable, Equatable {
    /// A `.working` session idle for this long is relabelled `.stale`.
    public var stale: TimeInterval
    /// A session whose pid is CONFIRMED dead is removed once idle this long.
    /// Short: there is nothing left to be wrong about.
    public var deadGrace: TimeInterval
    /// A session whose liveness we cannot establish is removed once idle this
    /// long. See `PidStatus.unknown`.
    public var orphanTTL: TimeInterval
    /// A `pendingPermission` older than this is cleared. Backstop for the
    /// dialog that was answered somewhere we cannot observe.
    public var permissionTTL: TimeInterval
    /// A `.needsAttention` session silent for this long falls back to `.idle`.
    ///
    /// Red is a claim about NOW — "stop what you are doing". Nothing used to
    /// retract it, so a session that asked for you yesterday afternoon was still
    /// asking the next morning, and a pill that is permanently red is a pill
    /// nobody looks at. Longer than `stale` on purpose: a permission prompt you
    /// are still thinking about should keep shouting.
    public var attentionTTL: TimeInterval
    /// An `AgentPidScan` older than this is ignored. A scan that failed or
    /// never ran must never be read as "none of these pids are agents".
    public var scanFreshness: TimeInterval

    public init(
        stale: TimeInterval = 10 * 60,
        deadGrace: TimeInterval = 45,
        orphanTTL: TimeInterval = 10 * 60,
        permissionTTL: TimeInterval = 5 * 60,
        attentionTTL: TimeInterval = 30 * 60,
        scanFreshness: TimeInterval = 60
    ) {
        self.stale = stale
        self.deadGrace = deadGrace
        self.orphanTTL = orphanTTL
        self.permissionTTL = permissionTTL
        self.attentionTTL = attentionTTL
        self.scanFreshness = scanFreshness
    }

    public static let `default` = ReapPolicy()
}

/// What the reaper knows about the process behind a session.
///
/// The third case is the one that matters. `kill(pid, 0)` answers a question
/// about a PROCESS, and for an IDE agent panel the process is not the agent —
/// it is the extension host that hosts many chats and outlives all of them. So
/// "alive" from a pid that is not itself an agent proves nothing about the
/// session, and saying so out loud is the whole point of this enum.
public enum PidStatus: Sendable, Equatable {
    /// The pid is alive AND is one of our agent processes.
    case alive
    /// The pid is gone.
    case dead
    /// No pid, or a live pid that is not an agent — a shared host.
    case unknown
}

/// The live agent pids as of one `ps` sweep, with the time it was taken.
///
/// Timestamped because the absence of a pid from this set is only meaningful
/// while the set is fresh; see `ReapPolicy.scanFreshness`.
public struct AgentPidScan: Sendable, Equatable {
    public let pids: Set<Int32>
    public let at: Date

    public init(pids: Set<Int32>, at: Date) {
        self.pids = pids
        self.at = at
    }
}

/// "Is this pid still around?" Injected so the reaper is testable without
/// spawning processes.
public typealias PidLiveness = @Sendable (Int32) -> Bool

/// The real thing.
///
/// `kill(pid, 0)` sends no signal and only performs the permission and
/// existence checks. `EPERM` means the process EXISTS but belongs to somebody
/// we may not signal — that is still alive, and treating it as dead would reap
/// live sessions.
public let systemPidLiveness: PidLiveness = { pid in
    guard pid > 0 else { return false }
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}
