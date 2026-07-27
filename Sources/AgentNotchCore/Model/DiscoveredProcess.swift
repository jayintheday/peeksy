import Foundation

/// One agent process found by a launch-time scan.
///
/// The scanner itself lives outside this module's core; the registry only ever
/// sees this flat value so `seed` stays testable with literals.
public struct DiscoveredProcess: Sendable, Equatable {
    public let pid: Int32
    /// Bare form, e.g. `"ttys003"`. `nil` when the process has no controlling tty.
    public let tty: String?
    public let cwd: String?

    public init(pid: Int32, tty: String? = nil, cwd: String? = nil) {
        self.pid = pid
        self.tty = tty
        self.cwd = cwd
    }
}
