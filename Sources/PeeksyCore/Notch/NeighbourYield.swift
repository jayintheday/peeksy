import CoreGraphics
import Foundation

// Whether to get out of the way of somebody else's status icon.
//
// A plain struct with an injected reading and no clock, for the same reason
// `SessionRegistry` is one: every test stays synchronous and every decision is
// reproducible from its inputs.

/// How much of the menu bar the collapsed window is claiming. Ordered by how
/// much that is, so `>` reads as "standing further aside".
public enum NotchYieldLevel: Int, Sendable, Comparable, CaseIterable {
    /// The pill is drawn: notch, gap, capsule, two points of slop.
    case full = 0
    /// The capsule drops its count and shows the bare dot — the same width the
    /// pill already has with nothing to count, 22 pt narrower than the counted
    /// form.
    ///
    /// Exists because the alternative to a slightly worse pill was NO pill, and
    /// the two are not close. `interactiveRects` is empty while yielded, so a
    /// yielded app is not merely invisible: it cannot be hovered, opened or
    /// clicked at all. Trading the digit for staying reachable is the whole
    /// point. Observed case: a webcam indicator takes 48 pt of menu bar and the
    /// counted pill misses by SIX POINTS, while the dot clears by eighteen.
    case compact = 1
    /// The pill is not drawn. The collapsed window is the notch and nothing
    /// else, so the only pixels it occupies are ones the camera housing already
    /// owns and occlusion is impossible by construction.
    case yielded = 2

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Where `collapsedFrame` would end at each level that draws something.
///
/// Supplied by the caller rather than derived here: both come out of
/// `NotchGeometryResolver.resolve`, which owns padding, clamping and the
/// no-notch fallback. Recomputing either from a width would be this file
/// guessing at another file's arithmetic.
public struct YieldFootprints: Sendable, Equatable {
    /// Ends here with the counted capsule.
    public let full: CGFloat
    /// Ends here with the bare dot.
    public let compact: CGFloat

    public init(full: CGFloat, compact: CGFloat) {
        self.full = full
        self.compact = compact
    }
}

public struct NeighbourPolicy: Sendable, Equatable {
    /// Clear air insisted on between our right edge and the leftmost status
    /// item. Not zero: touching is not a collision, but it is one screen
    /// redraw away from being one.
    public var clearance: CGFloat
    /// EXTRA clearance required to go back to `.full`.
    ///
    /// Yield fast, release slow. An unnecessary yield is invisible — the pill is
    /// missing for a few seconds on a bar that was nearly full anyway. An
    /// unnecessary occlusion is the bug this whole change exists to fix. The two
    /// errors are not symmetric and the policy should not pretend they are.
    public var releaseMargin: CGFloat
    /// Consecutive agreeing samples before a RELEASE is applied. Escalation is
    /// applied on the first sample.
    public var releaseConfirmations: Int

    public init(clearance: CGFloat = 8, releaseMargin: CGFloat = 24, releaseConfirmations: Int = 2) {
        self.clearance = clearance
        self.releaseMargin = releaseMargin
        self.releaseConfirmations = releaseConfirmations
    }

    public static let `default` = NeighbourPolicy()
}

public struct NeighbourYield: Sendable, Equatable {

    public private(set) var level: NotchYieldLevel = .full
    private var releaseSamples = 0

    public init() {}

    /// Fold one reading in. Returns true only if `level` actually moved, so the
    /// caller can skip re-resolving geometry on the overwhelming majority of
    /// samples that change nothing.
    ///
    /// The footprints depend on the session count, so the caller supplies them
    /// rather than the policy assuming a constant.
    @discardableResult
    public mutating func apply(
        _ occupancy: MenuBarOccupancy,
        footprints: YieldFootprints,
        policy: NeighbourPolicy = .default
    ) -> Bool {
        // A sample that failed its own checks is not evidence of anything. HOLD
        // — in both directions, which is the part that is easy to get wrong.
        // Treating "I could not see" as "nothing is there" would release into an
        // occlusion; treating it as "everything is there" would hide the pill on
        // any transient. Neither is a decision worth making blind, and holding
        // means a broken window list degrades to exactly the previous
        // behaviour rather than to a new failure.
        guard occupancy.trust.isTrusted, let runMinX = occupancy.statusRunMinX else {
            releaseSamples = 0
            return false
        }

        // Claiming more menu bar than the neighbour leaves us is the error that
        // matters, so it is applied on ONE sample and with no extra margin
        // asked for. Standing further aside is always safe.
        let crowded = Self.widest(fitting: runMinX, footprints, policy, extra: 0)
        if crowded > level {
            releaseSamples = 0
            level = crowded
            return true
        }

        // Coming back needs more room than staying did, and needs to be true
        // more than once — otherwise a status item that flickers in and out
        // (a screenshot overlay, a sync indicator) makes the pill flap. The
        // margin applies to every step back, not just the last one: shrinking
        // to the dot and growing to the capsule flap exactly as badly.
        let roomy = Self.widest(fitting: runMinX, footprints, policy, extra: policy.releaseMargin)
        guard roomy < level else {
            releaseSamples = 0
            return false
        }
        releaseSamples += 1
        guard releaseSamples >= policy.releaseConfirmations else { return false }
        releaseSamples = 0
        level = roomy
        return true
    }

    /// The most generous level that clears `runMinX`, with `extra` on top of the
    /// clearance. `.yielded` draws nothing, so it always qualifies and this is
    /// total.
    private static func widest(
        fitting runMinX: CGFloat,
        _ footprints: YieldFootprints,
        _ policy: NeighbourPolicy,
        extra: CGFloat
    ) -> NotchYieldLevel {
        if footprints.full + policy.clearance + extra <= runMinX { return .full }
        if footprints.compact + policy.clearance + extra <= runMinX { return .compact }
        return .yielded
    }

    /// The width to resolve the geometry with, given what the pill would like to
    /// be.
    public func pillContentWidth(wanting wanted: CGFloat) -> CGFloat {
        switch level {
        case .full: return wanted
        // `min`, never a plain assignment: with nothing to count the pill is
        // ALREADY this width, and compact must only ever take space away.
        case .compact: return min(wanted, PillMetrics.capsuleHeight)
        case .yielded: return 0
        }
    }
}
