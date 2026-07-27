import Foundation
import Testing

@testable import AgentNotchCore

/// Expected values come from `scripts/orbits-reference.mjs`, a transliteration
/// of upstream's `lattice.ts` run under node — not from this port. A port
/// checked against itself proves nothing.
private let tolerance = 1e-9
private let side = 16.0

private func dots(_ t: Double) -> [OrbDot] {
    GlobeMode.dots(side: side, t: t, profile: .row)
}

@Suite("GlobeMode")
struct GlobeModeTests {

    // MARK: - Shape of a frame

    @Test("a frame is 54 dots — the reason globe survives being shrunk to a row")
    func dotCount() {
        // Not orbitCount × something: the field is `0...latitudeRings`
        // INCLUSIVE, and each ring carries max(1, round(|cos lat| × 14)).
        // 1 + 7 + 12 + 14 + 12 + 7 + 1. Against orbits' 39 on three rings.
        #expect(dots(3.0).count == 54)
        #expect(OrbMode.globe.dotCount == 54)
        #expect(OrbMode.globe.dotCount > OrbMode.orbits.dotCount)
    }

    @Test("the poles get exactly one dot each, not a clot")
    func polesAreSingleDots() {
        // cos(±π/2) is 0, so the lon count would round to 0 without the max(1,).
        // Getting this wrong stacks 14 dots on one pixel at each pole.
        let profile = GlobeProfile.row
        let poleCount = max(1, Int((abs(cos(Double.pi / 2)) * Double(profile.longitudeDensity)).rounded()))
        #expect(poleCount == 1)
    }

    @Test("dots come back in a deterministic total order, ties and all")
    func sortedDeterministically() {
        // 54 dots, 37 distinct z values. Swift's sort is not stable, so without
        // the x/y tiebreak in `sortedFarToNear` the same t could produce a
        // different array between two calls.
        for t in [0.0, 0.6, 3.0, 41.7] {
            let frame = dots(t)
            #expect(frame == dots(t), "not reproducible at t = \(t)")
            let zs = frame.map(\.z)
            #expect(zs == zs.sorted(), "not depth-sorted at t = \(t)")
        }
    }

    @Test("a globe frame really does contain depth ties")
    func tiesExist() {
        // Documents WHY the tiebreak exists. If upstream ever changes the
        // lattice such that this stops being true, the periodicity test below
        // could go back to being index-wise.
        let zs = dots(0).map { ($0.z * 1e12).rounded() }
        #expect(Set(zs).count < zs.count)
    }

    @Test("every dot lands inside the canvas it will be drawn into")
    func dotsStayInsideTheFrame() {
        for t in stride(from: 0.0, through: 50.0, by: 0.25) {
            for dot in dots(t) {
                #expect(dot.x - dot.r >= 0 && dot.x + dot.r <= side, "x out of frame at t = \(t)")
                #expect(dot.y - dot.r >= 0 && dot.y + dot.r <= side, "y out of frame at t = \(t)")
            }
        }
    }

    @Test("every dot is drawable, and the scan never drives alpha out of range")
    func dotsAreDrawable() {
        for t in stride(from: 0.0, through: 20.0, by: 0.13) {
            for dot in dots(t) {
                #expect(dot.r >= GlobeProfile.row.minRadius)
                #expect(dot.alpha >= GlobeProfile.row.dimBase)
                // `min(1, boost)` is what holds the ceiling; without it a dot
                // under the meridian would go translucent-past-opaque.
                #expect(dot.alpha <= 1)
                #expect(dot.ink >= 0 && dot.ink <= 1)
            }
        }
    }

    @Test("an empty or negative side yields no dots rather than a NaN cloud")
    func degenerateSide() {
        #expect(GlobeMode.dots(side: 0, t: 3, profile: .row).isEmpty)
        #expect(GlobeMode.dots(side: -4, t: 3, profile: .row).isEmpty)
    }

    // MARK: - The scan

    @Test("the scan confines itself to the near face")
    func scanDoesNotGlowThroughTheBack() {
        // `max(0, z)` in the boost. Without it the meridian lights up dots on
        // the far side of the sphere and the orb stops reading as solid.
        for t in stride(from: 0.0, through: 12.0, by: 0.07) {
            for dot in dots(t) where dot.z <= 0 {
                #expect(abs(dot.alpha - GlobeProfile.row.dimBase) < 1e-12, "boosted a back dot")
            }
        }
    }

    @Test("the scan actually sweeps — alpha and radius vary with t, unlike orbits")
    func scanIsAlive() {
        // orbits' aggregates are all time-invariant; globe's are not, because
        // the meridian adds radius and alpha as it passes. This is what makes
        // the reference digests below a real check rather than a tautology.
        let a = dots(0.6).reduce(0) { $0 + $1.alpha }
        let b = dots(3.0).reduce(0) { $0 + $1.alpha }
        #expect(abs(a - b) > 0.01)
    }

    @Test("the tilt breathes rather than sitting still")
    func tiltWobbles() {
        // 0.4 ± 0.06. A frozen tilt is a subtly deader picture and is exactly
        // what you get by dropping the sin() term as "noise".
        let sample = stride(from: 0.0, through: 20.0, by: 0.1).map {
            GlobeMode.tiltBase + GlobeMode.tiltSwing * sin($0 * GlobeMode.tiltRate)
        }
        #expect(sample.max()! > 0.455)
        #expect(sample.min()! < 0.345)
    }

    // MARK: - Against the reference implementation

    @Test("the rest frame matches the reference implementation")
    func restFrameMatchesReference() {
        let frame = dots(OrbitsMode.restPhase)
        expectDot(frame.first!, [9.259734377, 8.778343655, -0.974189735, 0.3, 0.613031228, 0.45])
        expectDot(frame.last!, [6.740265623, 7.221656345, 0.974189735, 0.687100162, 0.086968772, 0.451097686])
        #expect(abs(frame.reduce(0) { $0 + $1.r } - 24.596082562) < tolerance)
        #expect(abs(frame.reduce(0) { $0 + $1.ink } - 18.9) < tolerance)
        #expect(abs(frame.reduce(0) { $0 + $1.alpha } - 25.122507296) < tolerance)
    }

    @Test("a moving frame matches the reference implementation, dot for dot")
    func movingFrameMatchesReference() {
        // Compared as a sorted multiset, NOT index-wise. Depth ties mean the
        // two implementations can order tied dots differently on a last-ulp
        // difference while drawing an identical picture. Sorting the component
        // asks the question that matters: is the same set of dots in the same
        // set of places?
        let expectedX: [Double] = [
            8.401867001, 5.514579357, 8.464036043, 11.181474707, 5.578934662,
            8.232018021, 11.257229394, 5.586677482, 3.293258167, 10.702644258,
            3.173354965, 13.108608835, 8.401867001, 13.405288516, 5.514579357,
            8.000000000, 11.181474707, 4.758618022, 2.333104650, 1.723751511,
            11.138124245, 3.293258167, 13.666895350, 14.482763957, 13.108608835,
            8.232018021, 6.371385303, 9.210532669, 5.586677482, 2.891391165,
            10.702644258, 1.517236043, 2.333104650, 12.706741833, 14.276248489,
            13.666895350, 4.818525293, 8.000000000, 4.758618022, 10.485420643,
            2.594711484, 11.138124245, 7.598132999, 2.891391165, 12.826645035,
            12.706741833, 6.371385303, 4.742770606, 9.210532669, 10.421065338,
            4.818525293, 7.535963957, 10.485420643, 7.598132999,
        ]
        let frame = dots(3.0)
        #expect(frame.count == expectedX.count)
        for (i, want) in zip(frame.map(\.x).sorted(), expectedX.sorted()).enumerated() {
            #expect(abs(want.0 - want.1) < tolerance, "sorted x at \(i)")
        }
        #expect(abs(frame.reduce(0) { $0 + $1.r } - 25.043243459) < tolerance)
        #expect(abs(frame.reduce(0) { $0 + $1.ink } - 18.9) < tolerance)
        #expect(abs(frame.reduce(0) { $0 + $1.alpha } - 26.55198281) < tolerance)
    }

    // MARK: - Periodicity

    @Test("the frame at t is the frame at t + period, so repeatForever cannot pop")
    func loopIsSeamless() {
        // Multiset again, and here it is not a nicety: at t = 0 the globe is a
        // symmetric configuration whose tied dots differ between the two frames
        // only by float noise, so ANY total order permutes them and an
        // index-wise diff reports ~13pt of drift on a 16pt canvas while the
        // picture is identical.
        for t in [0.0, 0.6, 3.0, 12.5] {
            let a = dots(t)
            let b = dots(t + OrbitsMode.period)
            #expect(a.count == b.count)
            for key in [\OrbDot.x, \OrbDot.y, \OrbDot.r, \OrbDot.ink] {
                let lhs = a.map { $0[keyPath: key] }.sorted()
                let rhs = b.map { $0[keyPath: key] }.sorted()
                for (i, pair) in zip(lhs, rhs).enumerated() {
                    #expect(abs(pair.0 - pair.1) < 1e-6, "drift at t = \(t), index \(i)")
                }
            }
        }
    }

    @Test("every angular rate sits on the quantum lattice")
    func ratesAreQuantised() {
        // All three. The scan rate is the one that matters most and the easiest
        // to get wrong: upstream derives it as spin + (1.7 - spin) × scanMul =
        // 5.702, and quantising `scanMul` instead of the RESULT would leave it
        // off the lattice.
        for rate in [GlobeMode.spin, GlobeMode.tiltRate, GlobeMode.scanRate] {
            #expect(abs(rate.remainder(dividingBy: OrbitsMode.quantum)) < tolerance, "\(rate)")
        }
        #expect(GlobeMode.scanRate == 5.75)
    }

    @Test("globe and orbits share a period, so the loop maths is one rule")
    func sharedPeriod() {
        #expect(OrbMode.globe.loopDuration == OrbitsMode.period / GlobeProfile.row.speed)
        #expect(OrbMode.globe.loopDuration > OrbMode.orbits.loopDuration)
    }
}

/// `[x, y, z, r, ink, alpha]`, in the order the reference implementation prints.
private func expectDot(_ dot: OrbDot, _ want: [Double], sourceLocation: SourceLocation = #_sourceLocation) {
    let got = [dot.x, dot.y, dot.z, dot.r, dot.ink, dot.alpha].map(Double.init)
    for (i, expected) in want.enumerated() {
        #expect(abs(got[i] - expected) < tolerance, "component \(i)", sourceLocation: sourceLocation)
    }
}
