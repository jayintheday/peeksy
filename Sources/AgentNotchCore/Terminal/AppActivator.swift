import Foundation

#if canImport(Darwin)
import Darwin
#endif

// MARK: - Owner identity

/// The application that owns a pid.
///
/// `pid` is the pid that actually RESOLVED to an application, which is not
/// necessarily the pid we were asked about. Claude.app embeds its own Claude
/// Code: the session's pid is a child `node`/`claude` process that no
/// `NSRunningApplication` will ever match, and the thing a human wants brought
/// forward is the ancestor bundle.
public struct OwningApp: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String?
    /// What the row shows, e.g. `"Claude"`. Never empty — the resolver
    /// substitutes something usable when AppKit has no localized name.
    public let localizedName: String

    public init(pid: Int32, bundleID: String? = nil, localizedName: String) {
        self.pid = pid
        self.bundleID = bundleID
        self.localizedName = localizedName
    }
}

public enum ActivationOutcome: Sendable, Equatable {
    /// Carries the localized name of whatever came forward.
    case activated(String)
    /// Nothing in the ancestor chain is an application. Not an error — a
    /// backgrounded `claude` under `launchd` genuinely has no owner to raise.
    case noOwner
    case failed(String)
}

public protocol AppActivating: Sendable {
    /// Resolve the owning application for a pid and bring it forward.
    func activateOwner(ofPid pid: Int32) -> ActivationOutcome
    /// Resolve the owning application WITHOUT activating it.
    ///
    /// On the protocol rather than only on `SystemAppActivator` because click
    /// routing needs the answer before it decides what to do — see `focusRoute`.
    func owner(ofPid pid: Int32) -> OwningApp?
}

// MARK: - Activator

/// Walks a pid up to its owning application and activates it.
///
/// AppKit-free by construction: `resolve` and `activate` are injected from the
/// executable target exactly the way `TerminalFocuser` takes `isTerminalRunning`,
/// so `AgentNotchCore` never imports AppKit and the whole walk is testable with
/// literals.
public struct SystemAppActivator: AppActivating {
    /// `NSRunningApplication(processIdentifier:)`, injected.
    public typealias Resolve = @Sendable (Int32) -> OwningApp?
    /// Parent of a pid, or `nil` at the top of the tree.
    public typealias ParentOf = @Sendable (Int32) -> Int32?
    /// `NSRunningApplication.activate` / `NSWorkspace.openApplication`, injected.
    /// Returns whether the app actually came forward.
    public typealias Activate = @Sendable (OwningApp) -> Bool

    /// How far up the process tree to look.
    ///
    /// Bounded because the chain is attacker-free but not shape-free: a pid can
    /// be reparented to `launchd` mid-walk, and a sysctl race can hand back a
    /// parent that points back down. Five hops covers
    /// `claude` → `node` → helper → `Claude.app` with room to spare, and the
    /// `seen` set makes a cycle terminate rather than spin.
    public static let maxHops = 5

    private let resolve: Resolve
    private let parentOf: ParentOf
    private let activate: Activate

    public init(
        resolve: @escaping Resolve,
        parentOf: @escaping ParentOf = systemParentPid,
        activate: @escaping Activate
    ) {
        self.resolve = resolve
        self.parentOf = parentOf
        self.activate = activate
    }

    /// The application owning `pid`, or `nil`.
    ///
    /// Pure with respect to the injected seams, and side-effect free — the row
    /// label calls this without activating anything.
    public func owner(ofPid pid: Int32) -> OwningApp? {
        var current = pid
        var seen = Set<Int32>()

        // maxHops PARENT traversals, so maxHops + 1 resolution attempts.
        for _ in 0...Self.maxHops {
            // pid 1 is launchd; there is nothing above it and nothing to raise.
            guard current > 1, seen.insert(current).inserted else { return nil }
            if let app = resolve(current) { return app }
            guard let parent = parentOf(current) else { return nil }
            current = parent
        }
        return nil
    }

    public func activateOwner(ofPid pid: Int32) -> ActivationOutcome {
        guard let app = owner(ofPid: pid) else { return .noOwner }
        guard activate(app) else { return .failed("could not activate \(app.localizedName)") }
        return .activated(app.localizedName)
    }
}

/// Real parent lookup via `sysctl(KERN_PROC_PID)`.
///
/// Not `ps`: this runs on a click and a process spawn is ~10 ms of latency for
/// one integer. A dead pid answers rc 0 with a zero-length record, hence the
/// size check.
public let systemParentPid: @Sendable (Int32) -> Int32? = { pid in
    guard pid > 1 else { return nil }

    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride

    let rc = mib.withUnsafeMutableBufferPointer { buffer in
        sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
    }
    guard rc == 0, size > 0 else { return nil }

    let ppid = info.kp_eproc.e_ppid
    return ppid > 0 ? ppid : nil
}

// MARK: - Click routing

/// What clicking a row should actually do.
///
/// A pure decision, separated from the doing, because the two branches have
/// wildly different testability: routing is three ifs, and both destinations
/// spawn processes or send Apple events.
public enum FocusRoute: Sendable, Equatable {
    /// The normal case: a real terminal tab is behind this session.
    case terminal(tty: String)
    /// No tty, but the process is alive — raise whatever app owns it.
    /// Claude.app's embedded Claude Code lands here.
    case activateApp(pid: Int32)
    /// Nothing we can honour. Carries a reason for the log; never a dialog.
    case unavailable(reason: String)
}

/// Terminal.app. The ONLY application `TerminalFocuser` can script.
public let terminalBundleIdentifier = "com.apple.Terminal"

/// Route a click.
///
/// A tty is the only thing that can put the cursor back in the exact tab the
/// agent is running in, so it wins — **but only when Terminal.app is the app
/// that owns it.**
///
/// That qualifier is the whole point of this function. A Claude Code session in
/// VS Code's, Cursor's or iTerm2's integrated terminal has a perfectly real
/// `ttysNNN`: the process scan finds it, the hook fires, the row shows full
/// state — and then `tell application "Terminal"` is asked about a pty
/// Terminal.app has never heard of, returns `notfound`, and the row is dead.
/// The user sees a session they cannot click. Routing on the OWNER instead of
/// on the mere presence of a tty is what makes those rows work: we raise the
/// IDE, which is the best thing available and infinitely better than nothing.
///
/// Decided up front rather than as a fallback after a failed AppleScript: the
/// round-trip costs an `osascript` spawn, and asking Terminal about a tty we
/// already know it does not own can raise an Automation prompt for a lookup
/// that was never going to succeed.
///
/// `ownerBundleID` defaults to "we do not know", which preserves the old
/// tty-always-wins behaviour — an unknown owner must never downgrade a session
/// that would have focused correctly.
public func focusRoute(
    tty: String?,
    pid: Int32?,
    isPidAlive: PidLiveness = systemPidLiveness,
    ownerBundleID: (Int32) -> String? = { _ in nil }
) -> FocusRoute {
    let normalized = normalizeTty(tty)

    if let normalized {
        // No pid means no way to ask who owns the tty. Terminal.app is the
        // overwhelmingly common case and the old behaviour, so keep it.
        guard let pid, pid > 0 else { return .terminal(tty: normalized) }

        switch ownerBundleID(pid) {
        case terminalBundleIdentifier, nil:
            // nil is "unknown", not "not Terminal": a tmux or ssh session has no
            // GUI ancestor at all, and its outer tab may still be Terminal's.
            return .terminal(tty: normalized)
        case .some:
            // Somebody else's terminal emulator. Fall through to raising it —
            // but only if the process is still alive, for the same reason as below.
            guard isPidAlive(pid) else {
                return .unavailable(reason: "pid \(pid) is gone")
            }
            return .activateApp(pid: pid)
        }
    }

    guard let pid, pid > 0 else {
        return .unavailable(reason: "session has no tty and no pid")
    }
    // A dead pid means the session is a corpse the reaper has not swept yet.
    // Activating "whatever owns pid 37255" after the kernel recycled that number
    // would raise an unrelated app.
    guard isPidAlive(pid) else {
        return .unavailable(reason: "session has no tty and pid \(pid) is gone")
    }
    return .activateApp(pid: pid)
}

public func focusRoute(
    for session: Session,
    isPidAlive: PidLiveness = systemPidLiveness,
    ownerBundleID: (Int32) -> String? = { _ in nil }
) -> FocusRoute {
    focusRoute(
        tty: session.tty,
        pid: session.pid,
        isPidAlive: isPidAlive,
        ownerBundleID: ownerBundleID)
}
