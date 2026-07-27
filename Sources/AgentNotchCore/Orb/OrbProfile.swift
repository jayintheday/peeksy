import CoreGraphics
import Foundation

/// The tuning for one orb, fully resolved.
///
/// Upstream reaches this shape through two layers — a stringly-keyed `ModeOpts`
/// bag of base profiles (`src/engine/profiles.ts`) and a multiplier table
/// (`src/presets.ts`) applied at mount — because it ships six modes at two sizes
/// and needs the generic machinery. We ship one mode at one size, so the
/// multipliers are baked below and the bag becomes a struct the compiler checks.
///
/// The derivation is written out so a future reader can diff it against upstream
/// without running any TypeScript. See `NOTICE`.
public struct OrbProfile: Sendable, Equatable {
    /// Number of tilted orbit rings.
    public let orbitCount: Int
    /// Dots tracing each orbit's ghost path.
    public let ghostCount: Int
    /// Particles running each orbit. NOT scaled by the count multiplier upstream
    /// — a preset that scaled these away would leave ghost paths with nothing
    /// travelling them.
    public let particles: Int

    public let ghostRadius: Double
    public let ghostAlpha: Double
    public let particleRadius: Double
    /// Added to `particleRadius` in proportion to depth, so near particles read
    /// bigger. This is half of how the orb reads as 3D; ink is the other half.
    public let particleRadiusDepth: Double

    /// Exponent on the 300pt reference falloff. See `orbRadiusScale`.
    public let radiusPower: Double
    /// Radii clamp up to this, so a dot never vanishes entirely at small sizes.
    public let minRadius: Double
    /// Multiplier on the shared clock.
    public let speed: Double

    public init(
        orbitCount: Int,
        ghostCount: Int,
        particles: Int,
        ghostRadius: Double,
        ghostAlpha: Double,
        particleRadius: Double,
        particleRadiusDepth: Double,
        radiusPower: Double,
        minRadius: Double,
        speed: Double
    ) {
        self.orbitCount = orbitCount
        self.ghostCount = ghostCount
        self.particles = particles
        self.ghostRadius = ghostRadius
        self.ghostAlpha = ghostAlpha
        self.particleRadius = particleRadius
        self.particleRadiusDepth = particleRadiusDepth
        self.radiusPower = radiusPower
        self.minRadius = minRadius
        self.speed = speed
    }
}

extension OrbProfile {
    /// The session-row orb: upstream's `orbits` base profile with the `size: 20`
    /// preset baked in.
    ///
    /// Upstream base (`BASE_PROFILES.orbits`):
    ///     orbitN 12, ghostN 40, particles 3, ghostR 0.9, ghostA 0.5,
    ///     partR 1.2, partRDepth 1.6, rsPow 0.6, rMin 0.3
    ///
    /// Upstream preset (`PRESETS.orbits[20]`): speed 3.9, count 0.238, size 2.4
    ///
    ///   `scaleCounts(0.238)` — `orbits` has no lattice pair, so only the flat
    ///   count keys scale, and `particles` is not one of them:
    ///     orbitN  = max(1, round(12 × 0.238)) = 3
    ///     ghostN  = max(1, round(40 × 0.238)) = 10
    ///
    ///   `scaleRadii(2.4)`:
    ///     ghostR      = 0.9 × 2.4 = 2.16
    ///     partR       = 1.2 × 2.4 = 2.88
    ///     partRDepth  = 1.6 × 2.4 = 3.84
    ///
    /// Note we render this at 16pt, not the 20pt it was tuned for. Upstream is
    /// explicit that its two sizes are "separate designs, not a scale factor",
    /// so 16pt is off the end of the tuned range and `orbRadiusScale` is doing
    /// the extrapolating. That is what `--orb-lab` exists to judge.
    public static let row = OrbProfile(
        orbitCount: 3,
        ghostCount: 10,
        particles: 3,
        ghostRadius: 2.16,
        ghostAlpha: 0.5,
        particleRadius: 2.88,
        particleRadiusDepth: 3.84,
        radiusPower: 0.6,
        minRadius: 0.3,
        speed: 3.9
    )
}
