import CoreGraphics
import Foundation

/// Which orb to draw.
///
/// Upstream ships six modes as six *verbs* an agent can be doing — working,
/// searching, solving, listening, composing, shaping. This app has five
/// *statuses*, not verbs, and only one of them is an activity, so the choice
/// here is purely about which picture survives being 16pt on black. It is an
/// enum rather than a constant so `--orb-lab` can put the two side by side.
public enum OrbMode: String, Sendable, CaseIterable {
    /// Particles on tilted orbits. Upstream's "working".
    case orbits
    /// A lat/long field with a scan meridian sweeping it. Upstream's
    /// "searching", and 54 dots against `orbits`' 39.
    case globe

    /// The dots for one frame, in painter's order.
    public func dots(side: Double, t: Double) -> [OrbDot] {
        switch self {
        case .orbits: return OrbitsMode.dots(side: side, t: t)
        case .globe: return GlobeMode.dots(side: side, t: t)
        }
    }

    /// Multiplier from wall-clock seconds to `t`. Upstream folds this into the
    /// clock before calling a mode, so `t` already carries it.
    public var speed: Double {
        switch self {
        case .orbits: return OrbitsProfile.row.speed
        case .globe: return GlobeProfile.row.speed
        }
    }

    /// Wall-clock seconds for one full, seamless loop.
    ///
    /// Every rate in every mode sits on `OrbitsMode.quantum`, so they share the
    /// period in `t`; only the speed differs. ≈12.9 s for orbits, ≈18.9 s for
    /// globe.
    public var loopDuration: Double { OrbitsMode.period / speed }

    /// How many dots a frame costs. Not used to draw — used to keep the cost of
    /// this feature honest in tests and in the lab.
    public var dotCount: Int { dots(side: 16, t: 0).count }
}
