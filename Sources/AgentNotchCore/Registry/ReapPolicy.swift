import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// The three timeouts that keep the list honest.
///
/// All of them are compared with `max(0, now.timeIntervalSince(x))` at the call
/// site — see `SessionRegistry.reap(now:)`.
public struct ReapPolicy: Sendable, Equatable {
    /// A `.working` session idle for this long is relabelled `.stale`.
    public var stale: TimeInterval
    /// A session idle for this long whose pid is dead is removed entirely.
    public var reap: TimeInterval
    /// A `pendingPermission` older than this is cleared. Backstop for the
    /// dialog that was answered somewhere we cannot observe.
    public var permissionTTL: TimeInterval

    public init(
        stale: TimeInterval = 10 * 60,
        reap: TimeInterval = 30 * 60,
        permissionTTL: TimeInterval = 5 * 60
    ) {
        self.stale = stale
        self.reap = reap
        self.permissionTTL = permissionTTL
    }

    public static let `default` = ReapPolicy()
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
