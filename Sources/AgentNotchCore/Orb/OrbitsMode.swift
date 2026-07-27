import CoreGraphics
import Foundation

/// The `orbits` mode: particles running tilted orbits, with a faint ghost path
/// tracing each one. Upstream's "working" state, and the only mode we ship.
///
/// Ported from `thinking-orbs`' `src/engine/orbits.ts`. See `NOTICE`.
///
/// This is a pure function of `(side, t)` and nothing else — no clock, no
/// randomness, no state. Given the same arguments it returns the same dots
/// forever, which is the only reason any of this is testable on a machine where
/// taking a screenshot is banned.
public enum OrbitsMode {

    // MARK: - Periodicity

    /// The angular quantum, in radians per unit `t`.
    ///
    /// **This is the one place we deliberately diverge from upstream, and it is
    /// load-bearing.** Upstream drives the orb from `performance.now()` — a
    /// clock that only ever counts up, so it never needs the animation to close
    /// a loop. We drive it from a SwiftUI `Animatable` phase ramped by
    /// `repeatForever`, which necessarily snaps back to its start value.
    ///
    /// Upstream's rates are yaw `0.12` and per-orbit `0.25 + 0.55·h`, an
    /// irrational spread with no common period — so the snap would be a visible
    /// pop, roughly once a minute, forever. Rounding every rate to a multiple of
    /// 1/8 rad gives the whole system a common period and makes the loop
    /// seamless. `OrbitsModeTests` asserts it.
    public static let quantum: Double = 1.0 / 8.0

    /// The `t` after which the orb is exactly where it started: 2π / quantum,
    /// i.e. 16π ≈ 50.27. Ramp the phase over this and `repeatForever` is
    /// invisible.
    public static var period: Double { 2 * .pi / quantum }

    /// Upstream is 0.12. Quantised up to 1/8 — the smallest change that lands
    /// on the lattice.
    static let yawRate: Double = 0.125
    static let tilt: Double = 0.3
    /// Orbits fill 82% of the half-side, leaving the outermost particles room to
    /// not clip against the frame.
    static let radiusFraction: Double = 0.82

    /// Snap an angular rate onto the quantum lattice.
    ///
    /// Upstream's magnitudes span [0.25, 0.80], which maps to {2…6}/8 — five
    /// distinct speeds, and never zero. A zero here would freeze an orbit's
    /// particles in place, which reads as a rendering bug rather than a design.
    static func quantise(_ rate: Double) -> Double {
        (rate / quantum).rounded() * quantum
    }

    // MARK: - Frame

    /// The dots for one frame, sorted far → near so a painter's-algorithm
    /// renderer can draw them in order and stop thinking.
    ///
    /// `side` is the orb's width in points; the caller's canvas must be square
    /// and this size, because the projection centres on `side/2`.
    public static func dots(side: Double, t: Double, profile: OrbitsProfile = .row) -> [OrbDot] {
        guard side > 0 else { return [] }

        let centre = side / 2
        let outerRadius = centre * radiusFraction
        let projection = OrbProjection(yaw: t * yawRate, tilt: tilt, cx: centre, cy: centre)
        // Upstream passes `scale: 1` into the projection and lets the orbit
        // radius carry the size, so this is the only place `side` enters the
        // geometry. The radius falloff is separate and sub-linear.
        let radiusScale = orbRadiusScale(side: side, power: profile.radiusPower)

        var dots: [OrbDot] = []
        dots.reserveCapacity(profile.orbitCount * (profile.ghostCount + profile.particles))

        for orbit in 0..<profile.orbitCount {
            let index = Double(orbit)
            // Three fixed salts, three stable properties per orbit. Same orbit
            // index, same orbit, every launch.
            let hRadius = orbHash(index, 1.7)
            let hTilt = orbHash(index, 5.2)
            let hSpeed = orbHash(index, 8.9)

            let orbitRadius = outerRadius * (0.45 + 0.52 * hRadius)

            // The orbit plane, as a normal n and two perpendicular basis vectors
            // u and v spanning it.
            let theta = hRadius * 2 * .pi
            let phi = acos(2 * hTilt - 1)
            let nx = sin(phi) * cos(theta)
            let ny = cos(phi)
            let nz = sin(phi) * sin(theta)

            // u = normalise(-ny, nx, 0). The z component is deliberately left
            // out of the normalisation upstream — it is identically zero, so
            // dividing it would change nothing, and matching the original here
            // keeps the two readable side by side.
            var ux = -ny
            var uy = nx
            let uz = 0.0
            let uLength = max(1e-6, (ux * ux + uy * uy).squareRoot())
            ux /= uLength
            uy /= uLength

            // v = n × u
            let vx = ny * uz - nz * uy
            let vy = nz * ux - nx * uz
            let vz = nx * uy - ny * ux

            // Half the orbits run backwards, so the orb never reads as one solid
            // body turning.
            let magnitude = quantise(0.25 + 0.55 * hSpeed)
            let speed = hSpeed > 0.5 ? magnitude : -magnitude

            // The ghost path: the orbit itself, drawn faintly. It does not move
            // with `t` — only the projection's yaw carries it round.
            for step in 0..<profile.ghostCount {
                let angle = (Double(step) / Double(profile.ghostCount)) * 2 * .pi
                let cosA = cos(angle)
                let sinA = sin(angle)
                let p = projection.project(
                    (ux * cosA + vx * sinA) * orbitRadius,
                    (uy * cosA + vy * sinA) * orbitRadius,
                    (uz * cosA + vz * sinA) * orbitRadius
                )
                let depth = (p.z / orbitRadius + 1) / 2
                dots.append(
                    OrbDot(
                        x: p.x,
                        y: p.y,
                        z: p.z,
                        r: max(profile.minRadius, profile.ghostRadius * radiusScale),
                        ink: 0.72,
                        alpha: profile.ghostAlpha * (0.4 + 0.6 * depth)
                    ))
            }

            // The particles doing the work. Bigger and brighter as they come
            // toward you — the entire 3D read, with no shading and no filters.
            for particle in 0..<profile.particles {
                // The `hTilt * 6` offset is upstream's, and it is the TILT salt,
                // not the speed one — it staggers where each orbit's particles
                // start so they do not all cross the meridian together.
                let angle =
                    t * speed
                    + (Double(particle) / Double(profile.particles)) * 2 * .pi
                    + hTilt * 6
                let cosA = cos(angle)
                let sinA = sin(angle)
                let p = projection.project(
                    (ux * cosA + vx * sinA) * orbitRadius,
                    (uy * cosA + vy * sinA) * orbitRadius,
                    (uz * cosA + vz * sinA) * orbitRadius
                )
                let depth = (p.z / orbitRadius + 1) / 2
                dots.append(
                    OrbDot(
                        x: p.x,
                        y: p.y,
                        z: p.z,
                        r: max(
                            profile.minRadius,
                            (profile.particleRadius + profile.particleRadiusDepth * depth)
                                * radiusScale),
                        ink: 0.3 - 0.22 * depth,
                        alpha: 1
                    ))
            }
        }

        // Painter's algorithm: far first, so near dots land on top.
        //
        // Upstream also drops dots with alpha < 0.02 here. In `orbits` nothing
        // ever gets that faint — ghosts bottom out at 0.2 and particles are
        // opaque — so porting the filter would have been dead code that made the
        // dot count untestable.
        return dots.sortedFarToNear()
    }

    /// The frame to show when the orb is at rest.
    ///
    /// Upstream renders exactly this for `prefers-reduced-motion`
    /// (`ThinkingOrb.tsx`: `if (reduced) { frame(0.6) }`) — a representative
    /// still rather than the degenerate `t = 0`. We reuse it for every non-
    /// working state too, so a settled row is a static orb rather than no orb.
    public static let restPhase: Double = 0.6
}
