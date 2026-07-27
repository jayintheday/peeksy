import CoreGraphics
import Foundation

/// One dot of a rendered orb, in the orb's own point space: origin top-left,
/// y-down, side length `side`. That is exactly the space a SwiftUI `Canvas`
/// draws in, so the view shell converts nothing — it fills an ellipse per dot
/// and stops.
///
/// Ported from `thinking-orbs`' `Dot` (`src/engine/core.ts`). See `NOTICE`.
///
/// The one rename is `white` → `ink`. "White" reads as a colour and it is not
/// one: it is a 0…1 depth weight that the original folds into a grey level, and
/// that we fold into whatever tint the row is already wearing. Keeping the
/// original name would have invited someone to paint with it.
public struct OrbDot: Sendable, Equatable {
    public let x: CGFloat
    public let y: CGFloat
    /// Depth after projection, larger = nearer. Only ever used to sort; never
    /// drawn, and meaningless in isolation.
    public let z: CGFloat
    public let r: CGFloat
    /// 0 = nearest and strongest, 1 = furthest and faintest.
    ///
    /// The original mirrors this against the substrate (`dark ? 1 - w : w`). We
    /// only ever paint on literal #000, so the mirror is folded in at the view:
    /// `tint.opacity((1 - ink) * alpha)`.
    public let ink: CGFloat
    public let alpha: CGFloat

    public init(x: CGFloat, y: CGFloat, z: CGFloat, r: CGFloat, ink: CGFloat, alpha: CGFloat) {
        self.x = x
        self.y = y
        self.z = z
        self.r = r
        self.ink = ink
        self.alpha = alpha
    }
}
