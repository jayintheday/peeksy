import CoreGraphics
import Foundation

// The pure half of the hover machine: dwell, exit grace and the velocity gate as
// a function of pointer samples and rects. No AppKit, no timers, no monitors —
// `Sources/AgentNotch/Notch/HoverEngine.swift` supplies those and does nothing
// else, which is why the interesting rules are testable without a mouse.

// MARK: - Samples

/// One pointer observation in AppKit global coordinates (y-up).
///
/// `NSEvent.mouseLocation` is already in this space, so nothing converts.
public struct PointerSample: Sendable, Equatable {
    public let location: CGPoint
    /// Monotonic seconds. The shell passes `ProcessInfo.systemUptime`, never
    /// `Date` — a wall-clock step during an NTP sync must not fire a dwell.
    public let time: TimeInterval

    public init(location: CGPoint, time: TimeInterval) {
        self.location = location
        self.time = time
    }
}

/// Points per second between two samples.
///
/// With fewer than two samples the answer is 0, NOT "unknown". The velocity gate
/// may only ever RESTART a dwell, so treating missing data as slow is the safe
/// direction: we never suppress an open for lack of information.
public func pointerSpeed(_ a: PointerSample?, _ b: PointerSample) -> CGFloat {
    guard let a else { return 0 }
    let dt = b.time - a.time
    // Sub-4 ms deltas divide a rounding error by a rounding error and produce
    // five-figure speeds from a stationary cursor.
    guard dt >= 0.004 else { return 0 }
    let dx = b.location.x - a.location.x
    let dy = b.location.y - a.location.y
    return (dx * dx + dy * dy).squareRoot() / dt
}

// MARK: - Zones

/// The rects the FSM tests containment against, all global. Produced by
/// `NotchGeometry.hoverZones`.
public struct HoverZones: Sendable, Equatable {
    public let pillHot: CGRect
    public let panel: CGRect
    /// Only consulted while `.peeking`, and derived from the FINAL expanded
    /// frame rather than the current one, so a fast downward flick is already
    /// "inside" while the window is still growing.
    public let graceCorridor: CGRect
    public let menuBarStrip: CGRect

    public init(pillHot: CGRect, panel: CGRect, graceCorridor: CGRect, menuBarStrip: CGRect) {
        self.pillHot = pillHot
        self.panel = panel
        self.graceCorridor = graceCorridor
        self.menuBarStrip = menuBarStrip
    }

    public func isInside(_ point: CGPoint) -> Bool {
        pillHot.contains(point) || panel.contains(point) || graceCorridor.contains(point)
    }
}

// MARK: - Policy

/// Shipping values. Each one is a decision, not a default.
public struct HoverPolicy: Sendable, Equatable {
    /// 180 ms: below the ~200 ms threshold at which a hover reads as lag, and
    /// well above the ~30 ms a fly-by spends crossing a 44 pt pill. The dwell
    /// timer is therefore the PRIMARY velocity gate; `velocityGate` below is a
    /// refinement.
    public var dwell: TimeInterval
    public var exitGrace: TimeInterval
    /// Shorter grace when the cursor leaves us into the menu bar: a user heading
    /// for Control Center should not have a black panel sitting over the target.
    public var menuBarExitGrace: TimeInterval
    /// pt/s. Above this the dwell RESTARTS rather than accumulating, so a fast
    /// traverse cannot bank progress towards an open it never intended.
    public var velocityGate: CGFloat
    public var burstInterval: TimeInterval
    public var burstDuration: TimeInterval
    public var idlePoll: TimeInterval

    public init(
        dwell: TimeInterval = 0.180,
        exitGrace: TimeInterval = 0.250,
        menuBarExitGrace: TimeInterval = 0.100,
        velocityGate: CGFloat = 1400,
        burstInterval: TimeInterval = 0.060,
        burstDuration: TimeInterval = 3.0,
        idlePoll: TimeInterval = 0.500
    ) {
        self.dwell = dwell
        self.exitGrace = exitGrace
        self.menuBarExitGrace = menuBarExitGrace
        self.velocityGate = velocityGate
        self.burstInterval = burstInterval
        self.burstDuration = burstDuration
        self.idlePoll = idlePoll
    }

    public static let `default` = HoverPolicy()
}

// MARK: - Effects

/// What the shell must do. Never more than one per call.
public enum HoverEffect: Sendable, Equatable {
    case expand
    case collapse
}

// MARK: - FSM

/// Dwell/grace/velocity as a pure struct, in the same spirit as `SessionRegistry`:
/// the owner serialises mutation (here, the main actor) and every test is a
/// synchronous three-liner with an explicit clock.
///
/// Deliberately knows nothing about pinning beyond "a pinned panel ignores the
/// pointer" — `pinned → peeking` never happens, because a pin the pointer could
/// undo would not be a pin.
public struct HoverEngineCore: Sendable {
    public private(set) var phase: NotchPhase = .collapsed
    /// Absolute deadlines on the same monotonic clock as `PointerSample.time`.
    public private(set) var dwellDeadline: TimeInterval?
    public private(set) var graceDeadline: TimeInterval?
    public private(set) var lastSpeed: CGFloat = 0

    /// True after an explicit dismissal while the pointer is still on the pill.
    ///
    /// Without it, clicking the pill to close the panel re-opens it 180 ms later
    /// — the pointer never moved, so the dwell simply starts again — and the
    /// panel becomes impossible to close by clicking. An explicit dismissal has
    /// to outrank a hover until the user demonstrates a new intent by moving
    /// away.
    public private(set) var reopenSuppressed = false

    public var policy: HoverPolicy
    private var lastSample: PointerSample?

    public init(policy: HoverPolicy = .default) {
        self.policy = policy
    }

    /// True while something is pending. The shell uses this to decide whether it
    /// still needs to be polling — a collapsed engine with no armed dwell costs
    /// zero wakeups, which for a 24/7 app is the whole point.
    public var wantsPolling: Bool {
        dwellDeadline != nil || graceDeadline != nil || phase == .peeking
    }

    /// Forced transition from outside the hover world: a pill click, an Escape,
    /// a space change. Clears both timers, because every one of those makes the
    /// pending decision moot.
    /// - Parameter suppressReopenUntilExit: pass `true` for anything the user
    ///   did ON PURPOSE to close the panel. Harmless for a grace-driven collapse,
    ///   where the pointer is outside the pill by definition and the very next
    ///   sample clears it.
    public mutating func setPhase(_ newPhase: NotchPhase, suppressReopenUntilExit: Bool = false) {
        phase = newPhase
        dwellDeadline = nil
        graceDeadline = nil
        reopenSuppressed = suppressReopenUntilExit && newPhase == .collapsed
    }

    /// The cursor moved (or was polled — the engine cannot tell, and must not
    /// care). Returns at most one effect.
    @discardableResult
    public mutating func pointer(_ point: CGPoint, at time: TimeInterval, zones: HoverZones) -> [HoverEffect] {
        let sample = PointerSample(location: point, time: time)
        lastSpeed = pointerSpeed(lastSample, sample)
        lastSample = sample

        switch phase {
        case .collapsed:
            if zones.pillHot.contains(point) {
                // Still on the pill after an explicit dismissal: the user has
                // not expressed a new intent, so neither do we.
                if reopenSuppressed { break }
                if lastSpeed > policy.velocityGate {
                    // Restart, never accumulate: a traverse that happens to pass
                    // through must not bank 150 ms of someone else's dwell.
                    dwellDeadline = time + policy.dwell
                } else if dwellDeadline == nil {
                    dwellDeadline = time + policy.dwell
                }
            } else {
                // Left the pill: intent expired, and so does the suppression.
                reopenSuppressed = false
                dwellDeadline = nil
            }

        case .peeking:
            if zones.isInside(point) {
                graceDeadline = nil
            } else if graceDeadline == nil {
                let grace = zones.menuBarStrip.contains(point)
                    ? policy.menuBarExitGrace
                    : policy.exitGrace
                graceDeadline = time + grace
            }

        case .pinned:
            // Hover is not a dismissal for a pinned panel, in either direction.
            break
        }

        return tick(time)
    }

    /// Fire whatever is due. Idempotent, so the burst poll can call it freely.
    @discardableResult
    public mutating func tick(_ now: TimeInterval) -> [HoverEffect] {
        if phase == .collapsed, let deadline = dwellDeadline, now >= deadline {
            dwellDeadline = nil
            phase = .peeking
            graceDeadline = nil
            return [.expand]
        }
        if phase == .peeking, let deadline = graceDeadline, now >= deadline {
            graceDeadline = nil
            phase = .collapsed
            dwellDeadline = nil
            return [.collapse]
        }
        return []
    }

    /// The soonest moment `tick` could do something, for scheduling a timer
    /// instead of spinning.
    public var nextDeadline: TimeInterval? {
        switch (dwellDeadline, graceDeadline) {
        case let (d?, g?): return min(d, g)
        case let (d?, nil): return d
        case let (nil, g?): return g
        case (nil, nil): return nil
        }
    }

    /// Drop the velocity history. Called after a `setFrame`, because the cursor
    /// did not move — the ZONES did, and a stale sample would compute a speed
    /// for a motion that never happened.
    public mutating func forgetMotion() {
        lastSample = nil
        lastSpeed = 0
    }
}
