import PeeksyCore
import SwiftUI

/// One frame of an orb, painted.
///
/// A deliberately stupid view: it asks Core for dots and fills an ellipse per
/// dot. All the maths, and every decision that can be wrong, lives in
/// `OrbitsMode` where tests can reach it — the same split as the geometry and
/// the hover FSM, and for the same reason.
///
/// `Animatable` is what makes this move. Conforming a View to it hands
/// `animatableData` to Core Animation, which interpolates it per frame and has
/// SwiftUI re-evaluate `body` as it goes. That is deliberately NOT a
/// `TimelineView`: a periodic timeline installs a run-loop source that fires
/// whether or not anything changed, in a window that exists twenty-four hours a
/// day. This ticks only while it is on screen, and it dies with its layer.
struct OrbCanvas: View, Animatable {
    var phase: Double
    let mode: OrbMode
    let tint: Color
    let side: CGFloat

    /// `nonisolated` on purpose, and it is the whole point.
    ///
    /// `View` is main-actor isolated under Swift 6, but SwiftUI drives
    /// `animatableData` from Core Animation's clock, off the main actor — which
    /// is exactly the property we want and the reason a `repeatForever` is
    /// cheaper than a timeline. Interpolating one `Double` in a value type is
    /// safe there; the conformance just has to say so out loud.
    nonisolated var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    /// Opacity buckets. See `body` — this is a performance number, not a
    /// visual one, and 8 is where banding stops being detectable on sub-point
    /// dots.
    private static let bucketCount = 8

    /// The eight tinted colours, built once per view rather than per dot per
    /// frame. Measured: constructing `Color` inside the draw loop was most of
    /// the cost of the whole feature.
    private let palette: [Color]

    init(phase: Double, mode: OrbMode, tint: Color, side: CGFloat) {
        self.phase = phase
        self.mode = mode
        self.tint = tint
        self.side = side
        self.palette = (0..<Self.bucketCount).map { bucket in
            tint.opacity((Double(bucket) + 0.5) / Double(Self.bucketCount))
        }
    }

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            // ONE path and ONE fill per opacity bucket, not per dot.
            //
            // The obvious loop — `context.fill(Path(ellipseIn:), with: .color(…))`
            // per dot — costs ~5% of a core per orb, while the maths behind it
            // costs 0.009%. Practically all of it is a `Path` allocation and a
            // `Color` resolution per dot per frame — 39 of each for orbits, 54
            // for globe. Bucketing collapses that to 8 paths and 8 pre-resolved
            // colours and is the difference between this shipping and not.
            var paths = [Path](repeating: Path(), count: Self.bucketCount)
            for dot in mode.dots(side: Double(side), t: phase) {
                // Upstream paints matte grey and mirrors the ink against the
                // substrate. We only ever paint on literal #000, so the mirror
                // folds into this one multiply — and the colour channel it frees
                // is what lets the orb carry state instead of only depth.
                let opacity = (1 - dot.ink) * dot.alpha
                let bucket = min(
                    Self.bucketCount - 1,
                    max(0, Int(opacity * Double(Self.bucketCount))))
                paths[bucket].addEllipse(
                    in: CGRect(
                        x: dot.x - dot.r,
                        y: dot.y - dot.r,
                        width: dot.r * 2,
                        height: dot.r * 2
                    ))
            }
            // Bucketing REPLACES Core's painter order with an opacity order,
            // and the two are not always the same.
            //
            // For `orbits` they coincide: opacity is monotonic in depth (ghosts
            // bottom out around 0.14, particles start around 0.7), so near dots
            // still land on top. For `globe` they do not — a far dot under the
            // scan meridian outranks a nearer unscanned one, because the sweep
            // multiplies alpha. That is acceptable and arguably right: the scan
            // is the thing the eye should catch, and at 16pt these are sub-point
            // dots with almost no overlap to occlude.
            for (bucket, path) in paths.enumerated() where !path.isEmpty {
                context.fill(path, with: .color(palette[bucket]))
            }
        }
        .frame(width: side, height: side)
    }
}

/// A session's orb: spinning, or a still.
///
/// This view does not decide whether to move. The caller owns the gates —
/// `PillView` documents them and this obeys the same three — because a view that
/// consults `NSWorkspace` in its own `body` is a view that cannot be reasoned
/// about from the outside.
struct SessionOrb: View {
    let tint: RowTint
    let spinning: Bool
    /// No default. Which orb this is, is a product decision, and the one place
    /// it ships is worth reading at the call site.
    let mode: OrbMode
    var side: CGFloat = 16

    var body: some View {
        Group {
            if spinning {
                SpinningOrb(mode: mode, tint: tint.notchColour, side: side)
            } else {
                OrbCanvas(
                    phase: OrbitsMode.restPhase, mode: mode, tint: tint.notchColour, side: side)
            }
        }
        .frame(width: side, height: side)
        .animation(.easeInOut(duration: 0.25), value: tint)
    }
}

/// The moving half, split out so that stopping DESTROYS it.
///
/// Tearing a `repeatForever` down by animating the phase back would rewind the
/// orb — up to a whole revolution backwards in a fraction of a second, which
/// reads as a glitch rather than as settling. Swapping the view out instead
/// takes the animation with it, which is also the stronger guarantee: there is
/// no repeat left attached to a layer to leak.
///
/// The cost is a phase discontinuity at the swap. It is hard to see: the orb is
/// a cloud of sub-point dots with no landmark to jump against, and the swap
/// always coincides with the row's tint crossfading to a new state anyway.
private struct SpinningOrb: View {
    let mode: OrbMode
    let tint: Color
    let side: CGFloat

    @State private var phase = OrbitsMode.restPhase

    var body: some View {
        // Wall-clock seconds for one revolution. `t` already carries the mode's
        // speed — upstream multiplies its clock by it before calling the mode —
        // so the period in `t` divided by that speed is the duration in
        // seconds: ≈12.9 s for orbits, ≈18.9 s for globe.
        OrbCanvas(phase: phase, mode: mode, tint: tint, side: side)
            .onAppear {
                // Ramping by exactly one period is what makes `repeatForever`
                // seamless: `restPhase` and `restPhase + period` are the same
                // picture, so the wrap is invisible. `OrbitsMode.quantum` is
                // what buys that, and `OrbitsModeTests` is what keeps it.
                withAnimation(
                    .linear(duration: mode.loopDuration).repeatForever(autoreverses: false)
                ) {
                    phase = OrbitsMode.restPhase + OrbitsMode.period
                }
            }
    }
}
