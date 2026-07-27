import CoreGraphics
import Foundation

// Whether to get out of the way of somebody else's status icon.
//
// A plain struct with an injected reading and no clock, for the same reason
// `SessionRegistry` is one: every test stays synchronous and every decision is
// reproducible from its inputs.

/// How much of the menu bar the collapsed window is claiming.
public enum NotchYieldLevel: Int, Sendable, Comparable, CaseIterable {
    /// The pill is drawn: notch, gap, capsule, two points of slop.
    case full = 0
    /// The pill is not drawn. The collapsed window is the notch and nothing
    /// else, so the only pixels it occupies are ones the camera housing already
    /// owns and occlusion is impossible by construction.
    case yielded = 1

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
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
    /// `fullFootprintMaxX` is where `collapsedFrame` would end at `.full` — it
    /// depends on the session count, so the caller supplies it rather than the
    /// policy assuming a constant.
    @discardableResult
    public mutating func apply(
        _ occupancy: MenuBarOccupancy,
        fullFootprintMaxX: CGFloat,
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

        let fits = fullFootprintMaxX + policy.clearance <= runMinX

        if !fits {
            releaseSamples = 0
            guard level != .yielded else { return false }
            level = .yielded
            return true
        }

        guard level != .full else {
            releaseSamples = 0
            return false
        }

        // Coming back needs more room than staying did, and needs to be true
        // more than once — otherwise a status item that flickers in and out
        // (a screenshot overlay, a sync indicator) makes the pill flap.
        guard fullFootprintMaxX + policy.clearance + policy.releaseMargin <= runMinX else {
            releaseSamples = 0
            return false
        }
        releaseSamples += 1
        guard releaseSamples >= policy.releaseConfirmations else { return false }
        releaseSamples = 0
        level = .full
        return true
    }

    /// The width to resolve the geometry with, given what the pill would like to
    /// be.
    public func pillContentWidth(wanting wanted: CGFloat) -> CGFloat {
        level == .yielded ? 0 : wanted
    }
}
