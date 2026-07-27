import CoreGraphics
import Foundation

/// The tuning for a globe orb, fully resolved. See `OrbitsProfile` for why the
/// multipliers are baked rather than ported.
public struct GlobeProfile: Sendable, Equatable {
    /// Latitude rings. The field is built `0...latitudeRings` INCLUSIVE, so this
    /// is one fewer than the number of rings drawn — upstream's loop bound, kept
    /// verbatim rather than "tidied", because tidying it changes the picture.
    public let latitudeRings: Int
    /// Dots around the equator. Every other ring gets `|cos(lat)|` of this, so
    /// the field stays even instead of bunching at the poles.
    public let longitudeDensity: Int

    public let baseRadius: Double
    /// Added in proportion to depth: near dots read bigger.
    public let depthRadius: Double
    /// Added where the scan meridian is passing. Deliberately NOT one of
    /// upstream's radius keys, so it does not scale with the size preset.
    public let scanRadius: Double

    /// Ink at the back of the sphere, and how much of that the front wins back.
    public let inkFar: Double
    public let inkSpan: Double
    /// Alpha of an unscanned dot. Below 1 so the meridian reads as a sweep
    /// rather than as a uniformly bright ball.
    public let dimBase: Double

    public let radiusPower: Double
    public let minRadius: Double
    public let speed: Double

    public init(
        latitudeRings: Int,
        longitudeDensity: Int,
        baseRadius: Double,
        depthRadius: Double,
        scanRadius: Double,
        inkFar: Double,
        inkSpan: Double,
        dimBase: Double,
        radiusPower: Double,
        minRadius: Double,
        speed: Double
    ) {
        self.latitudeRings = latitudeRings
        self.longitudeDensity = longitudeDensity
        self.baseRadius = baseRadius
        self.depthRadius = depthRadius
        self.scanRadius = scanRadius
        self.inkFar = inkFar
        self.inkSpan = inkSpan
        self.dimBase = dimBase
        self.radiusPower = radiusPower
        self.minRadius = minRadius
        self.speed = speed
    }
}

extension GlobeProfile {
    /// The session-row globe: upstream's `globe` base profile with the
    /// `size: 20` preset baked in.
    ///
    /// Upstream base (`BASE_PROFILES.globe`):
    ///     latRings 17, lonDensity 44, rBase 0.6, rDepth 1.7, rBoost 1.0,
    ///     inkFar 0.62, inkSpan 0.54, rsPow 0.6, rMin 0.3
    ///
    /// Upstream preset (`PRESETS.globe[20]`):
    ///     speed 2.665, count 0.105, size 1.75, scanMul 4.335, dimBase 0.45
    ///
    ///   `scaleCounts(0.105)` — latRings/lonDensity are a lattice PAIR, so each
    ///   side takes √scale and the total dot count scales by the full factor:
    ///     latRings   = max(2, round(17 × √0.105)) = 6
    ///     lonDensity = max(2, round(44 × √0.105)) = 14
    ///
    ///   `scaleRadii(1.75)` — `rBoost` is not a radius key and does not scale:
    ///     rBase  = 0.6 × 1.75 = 1.05
    ///     rDepth = 1.7 × 1.75 = 2.975
    ///
    /// That yields **54 dots** — the ring at latitude `li` carries
    /// `max(1, round(|cos lat| × 14))` of them, so 1 + 7 + 12 + 14 + 12 + 7 + 1.
    /// Against `orbits`' 39 sparse dots on three rings, this is why the globe
    /// survives being shrunk to a row.
    public static let row = GlobeProfile(
        latitudeRings: 6,
        longitudeDensity: 14,
        baseRadius: 1.05,
        depthRadius: 2.975,
        scanRadius: 1.0,
        inkFar: 0.62,
        inkSpan: 0.54,
        dimBase: 0.45,
        radiusPower: 0.6,
        minRadius: 0.3,
        speed: 2.665
    )
}

/// The `globe` mode: a lat/long dot field with a scan meridian sweeping it.
/// Upstream's "searching" state.
///
/// Ported from the `drawGlobe` half of `thinking-orbs`' `src/engine/lattice.ts`
/// (the `rubik` and `wave` modes in that file are not ported). See `NOTICE`.
///
/// Pure: a function of `(side, t)` and nothing else.
public enum GlobeMode {

    // MARK: - Rates
    //
    // All three are quantised onto `OrbitsMode.quantum`, for the reason
    // documented there: the phase is ramped by `repeatForever` and must close
    // its loop. Upstream never had to, because it runs off a monotonic clock.

    /// Yaw. Upstream's 0.5, which already sits on the lattice at 4/8.
    static let spin: Double = 0.5

    /// The tilt breathes between 0.34 and 0.46 rather than sitting still.
    /// Upstream rate 0.35, quantised to 3/8.
    static let tiltRate: Double = 0.375
    static let tiltBase: Double = 0.4
    static let tiltSwing: Double = 0.06

    /// The scan meridian's absolute rate.
    ///
    /// Upstream derives it as `spin + (1.7 - spin) × scanMul` with
    /// `scanMul = 4.335` at this size, i.e. 5.702. Quantised to 46/8 = 5.75.
    /// Quantising the RESULT rather than `scanMul` is what puts it on the
    /// lattice; scaling the multiplier would not.
    static let scanRate: Double = 5.75

    /// How tight the meridian is. Upstream's magic 0.18, a gaussian falloff on
    /// the angular distance to the sweep.
    static let scanTightness: Double = 0.18

    static let radiusFraction: Double = 0.82

    // MARK: - Frame

    /// The dots for one frame, in painter's order.
    public static func dots(side: Double, t: Double, profile: GlobeProfile = .row) -> [OrbDot] {
        guard side > 0 else { return [] }

        let centre = side / 2
        let radius = centre * radiusFraction
        let tilt = tiltBase + tiltSwing * sin(t * tiltRate)
        // Unlike `orbits`, the projection carries the size here and the field is
        // built from unit vectors — so `z` comes back in [-1, 1] already.
        let projection = OrbProjection(
            yaw: t * spin, tilt: tilt, cx: centre, cy: centre, scale: radius)
        let scan = t * scanRate
        let radiusScale = orbRadiusScale(side: side, power: profile.radiusPower)

        var dots: [OrbDot] = []
        dots.reserveCapacity(profile.longitudeDensity * profile.latitudeRings)

        // INCLUSIVE, per upstream: `latitudeRings` is the number of gaps, so
        // this draws one more ring than the name suggests, including a single
        // dot at each pole.
        for ring in 0...profile.latitudeRings {
            let latitude = -Double.pi / 2 + (Double(ring) / Double(profile.latitudeRings)) * .pi
            let cosLat = cos(latitude)
            let sinLat = sin(latitude)
            // Rings shrink toward the poles, so their dot count shrinks with
            // them. Without this the poles would be a solid clot.
            let count = max(1, Int((abs(cosLat) * Double(profile.longitudeDensity)).rounded()))

            for step in 0..<count {
                let longitude = (Double(step) / Double(count)) * 2 * .pi
                let p = projection.project(
                    cosLat * cos(longitude), sinLat, cosLat * sin(longitude))
                let depth = (p.z + 1) / 2

                // The scan, read as a SIZE ripple rather than a shine — the
                // whole library refuses gradients and glows, which is exactly
                // what let it port to a Canvas at all. `max(0, z)` confines the
                // sweep to the near face, so it does not glow through the back.
                let delta = orbAngleDelta(longitude + t * spin, scan)
                let boost = exp(-(delta * delta) / scanTightness) * max(0, p.z)

                dots.append(
                    OrbDot(
                        x: p.x,
                        y: p.y,
                        z: p.z,
                        r: max(
                            profile.minRadius,
                            (profile.baseRadius + profile.depthRadius * depth
                                + profile.scanRadius * boost) * radiusScale),
                        ink: profile.inkFar - profile.inkSpan * depth,
                        alpha: profile.dimBase + (1 - profile.dimBase) * min(1, boost)
                    ))
            }
        }
        return dots.sortedFarToNear()
    }
}
