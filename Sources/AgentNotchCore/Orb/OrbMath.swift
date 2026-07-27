import CoreGraphics
import Foundation

// The shared primitives from `thinking-orbs`' `src/engine/core.ts`, ported to
// Foundation. See `NOTICE`.
//
// Only what the `orbits` mode actually calls is here. Upstream `core.ts` also
// exports `fibDir` (Fibonacci sphere) and `angleDelta`, used by the lattice and
// ribbon modes — we ship neither mode, so porting them would have added public
// Core API with no caller and no reason to be trusted.
//
// Nothing here draws. Core stays Foundation-only and the whole engine is a pure
// function of (side, t), which is what makes it testable without a screen — the
// binding constraint on this feature, since `screencapture` is banned outright.

/// Deterministic hash in [0, 1).
///
/// The `sin`-times-a-large-constant trick from shader-land: `a` and `b` here are
/// an orbit index and a fixed salt, so every orbit gets a stable radius, tilt
/// and speed that survive a relaunch. Nothing about the orb is random.
///
/// `h` is routinely negative, so this needs `floor` (toward -∞) and NOT
/// `truncatingRemainder`, which would return a negative for negative input and
/// silently flip half the orbits.
public func orbHash(_ a: Double, _ b: Double) -> Double {
    let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
    return h - h.rounded(.down)
}

/// Shortest signed angular distance, wrapped to (-π, π].
///
/// The globe's scan meridian needs "how far is this dot from the sweep" to stay
/// sane as either angle wraps; plain subtraction would put a seam in the ripple.
public func orbAngleDelta(_ a: Double, _ b: Double) -> Double {
    atan2(sin(a - b), cos(a - b))
}

/// Spin + tilt + orthographic projection, as a value rather than a closure.
///
/// Built once per frame and applied 39–54 times; a struct keeps that
/// allocation-free.
public struct OrbProjection: Sendable {
    private let sinTilt: Double
    private let cosTilt: Double
    private let sinYaw: Double
    private let cosYaw: Double
    private let cx: Double
    private let cy: Double
    private let scale: Double

    /// The two modes split the work differently and both are upstream's doing:
    /// `orbits` passes `scale: 1` and sizes each orbit's own radius, while
    /// `globe` projects unit vectors and puts the radius here.
    public init(yaw: Double, tilt: Double, cx: Double, cy: Double, scale: Double = 1) {
        self.sinTilt = sin(tilt)
        self.cosTilt = cos(tilt)
        self.sinYaw = sin(yaw)
        self.cosYaw = cos(yaw)
        self.cx = cx
        self.cy = cy
        self.scale = scale
    }

    /// Returns screen x, screen y, and depth. y is flipped here, so the result
    /// is already in the canvas' y-down space. Depth is NOT scaled — upstream
    /// leaves it in model units and every caller divides by its own radius.
    public func project(_ x: Double, _ y: Double, _ z: Double) -> (x: Double, y: Double, z: Double) {
        let x1 = x * cosYaw + z * sinYaw
        let z1 = -x * sinYaw + z * cosYaw
        let y1 = y * cosTilt - z1 * sinTilt
        let z2 = y * sinTilt + z1 * cosTilt
        return (cx + x1 * scale, cy - y1 * scale, z2)
    }
}

extension Array where Element == OrbDot {
    /// Painter's order: far first, so near dots land on top.
    ///
    /// A TOTAL order, not just depth. Swift's `sort` is not stable, and a globe
    /// frame is 54 dots with only 37 distinct z values — without a tiebreak the
    /// same `t` could produce a different array between two calls. Ordering
    /// among equal-depth dots is visually irrelevant; being deterministic is
    /// not.
    public func sortedFarToNear() -> [OrbDot] {
        sorted {
            if $0.z != $1.z { return $0.z < $1.z }
            if $0.x != $1.x { return $0.x < $1.x }
            return $0.y < $1.y
        }
    }
}

/// Dot radii upstream were tuned against a 300pt frame; the sub-linear falloff
/// is what keeps a 16pt orb from becoming three invisible specks. A lower `power`
/// shrinks the radii less as the orb shrinks.
public func orbRadiusScale(side: Double, power: Double) -> Double {
    pow(side / 300, power)
}
