import Foundation
import Testing

@testable import AgentNotchCore

private let tolerance = 1e-9
/// The size the session rows actually render at.
private let side = 16.0

private func dots(_ t: Double) -> [OrbDot] {
    OrbitsMode.dots(side: side, t: t, profile: .row)
}

@Suite("OrbitsMode")
struct OrbitsModeTests {

    // MARK: - Shape of a frame

    @Test("a frame is exactly orbits × (ghosts + particles) dots")
    func dotCount() {
        let p = OrbitsProfile.row
        #expect(dots(3.0).count == p.orbitCount * (p.ghostCount + p.particles))
        #expect(dots(3.0).count == 39)
    }

    @Test("dots come back sorted far → near, ready for a painter's algorithm")
    func sortedByDepth() {
        // The view draws them in order and does no thinking of its own, so if
        // this ever regresses the orb silently turns inside out.
        for t in [0.0, 0.6, 3.0, 41.7] {
            let zs = dots(t).map(\.z)
            #expect(zs == zs.sorted(), "unsorted at t = \(t)")
        }
    }

    @Test("every dot lands inside the canvas it will be drawn into")
    func dotsStayInsideTheFrame() {
        // Orbits fill 82% of the half-side and the largest radius is ~1.16pt, so
        // there is real headroom here. If this ever fails the orb is clipping
        // against the row and the radius tuning has gone wrong.
        for t in stride(from: 0.0, through: 50.0, by: 0.25) {
            for dot in dots(t) {
                #expect(dot.x - dot.r >= 0 && dot.x + dot.r <= side, "x out of frame at t = \(t)")
                #expect(dot.y - dot.r >= 0 && dot.y + dot.r <= side, "y out of frame at t = \(t)")
            }
        }
    }

    @Test("every dot is drawable — a positive radius and a visible alpha")
    func dotsAreDrawable() {
        for t in [0.0, 0.6, 3.0] {
            for dot in dots(t) {
                #expect(dot.r >= OrbitsProfile.row.minRadius)
                #expect(dot.alpha > 0.02, "upstream would have culled this dot")
                #expect(dot.ink >= 0 && dot.ink <= 1)
            }
        }
    }

    @Test("the orb's centroid is the centre of the canvas, at every t")
    func centroidIsTheCentre() {
        // Falls out of the geometry: evenly-spaced points on a circle sum to its
        // centre, and both the ghost ring and the particle triad are evenly
        // spaced. It is the cheapest possible check that the orbit basis is
        // orthonormal and the projection is not skewing anything.
        for t in [0.0, 0.6, 3.0, 17.25] {
            let frame = dots(t)
            let n = Double(frame.count)
            #expect(abs(frame.reduce(0) { $0 + $1.x } - n * side / 2) < 1e-9, "x centroid at \(t)")
            #expect(abs(frame.reduce(0) { $0 + $1.y } - n * side / 2) < 1e-9, "y centroid at \(t)")
            #expect(abs(frame.reduce(0) { $0 + $1.z }) < 1e-9, "z centroid at \(t)")
        }
    }

    @Test("an empty or negative side yields no dots rather than a NaN cloud")
    func degenerateSide() {
        #expect(OrbitsMode.dots(side: 0, t: 3, profile: .row).isEmpty)
        #expect(OrbitsMode.dots(side: -4, t: 3, profile: .row).isEmpty)
    }

    // MARK: - Against upstream

    @Test("the rest frame matches the reference implementation")
    func restFrameMatchesReference() {
        let frame = dots(OrbitsMode.restPhase)
        expectDot(frame.first!, [8.971585865, 7.951766370, -5.964375707, 0.372094275, 0.72, 0.201956149])
        expectDot(frame.last!, [7.254895711, 8.119485460, 5.995884086, 1.155037808, 0.080860984, 1.0])
        #expect(abs(frame.reduce(0) { $0 + $1.r } - 18.604713743) < tolerance)
        #expect(abs(frame.reduce(0) { $0 + $1.ink } - 23.31) < tolerance)
        #expect(abs(frame.reduce(0) { $0 + $1.alpha } - 19.5) < tolerance)
    }

    @Test("a moving frame matches the reference implementation, dot for dot")
    func movingFrameMatchesReference() {
        // Element-wise, because the aggregates above happen to be time-invariant
        // — they would not notice a wrong yaw rate or a mis-sorted array.
        let expectedX: [Double] = [
            7.906373325, 7.240109155, 5.316217904, 10.827874863, 8.201334701,
            3.942595921, 3.456214649, 10.130472838, 7.780924208, 7.715175907,
            8.844584535, 11.009548486, 13.335488490, 6.800943387, 3.164158054,
            9.585642276, 2.194873140, 3.331782960, 6.278961438, 9.721038562,
            12.668217040, 9.639657242, 13.805126860, 6.414357724, 6.645166851,
            9.199056613, 2.664511510, 4.990451514, 7.155415465, 13.160966012,
            8.219075792, 2.932660663, 12.543785351, 12.057404079, 7.798665299,
            5.172125137, 10.705369107, 10.683782096, 8.759890845,
        ]
        let frame = dots(3.0)
        #expect(frame.count == expectedX.count)
        for (i, want) in expectedX.enumerated() {
            #expect(abs(frame[i].x - want) < tolerance, "dot \(i)")
        }
        expectDot(frame.first!, [7.906373325, 8.087576274, -6.041824856, 0.496200134, 0.299975245, 1.0])
        expectDot(frame.last!, [8.759890845, 8.057688673, 5.994941290, 0.372094275, 0.72, 0.498802530])
    }

    // MARK: - Periodicity

    // This is the guard on the one deliberate deviation from upstream. Upstream
    // is driven by a monotonic clock and never closes its loop; we drive it with
    // a `repeatForever` phase ramp that necessarily snaps back to its start. If
    // the rates ever drift off the 1/8 lattice, that snap becomes a visible pop
    // in the menu bar roughly once a minute, forever — and nothing else in the
    // suite would catch it.

    @Test("the frame at t is the frame at t + period, so repeatForever cannot pop")
    func loopIsSeamless() {
        for t in [0.0, 0.6, 3.0, 12.5] {
            let a = dots(t)
            let b = dots(t + OrbitsMode.period)
            #expect(a.count == b.count)
            for (i, dot) in a.enumerated() {
                #expect(abs(dot.x - b[i].x) < 1e-6, "x drift at t = \(t), dot \(i)")
                #expect(abs(dot.y - b[i].y) < 1e-6, "y drift at t = \(t), dot \(i)")
                #expect(abs(dot.r - b[i].r) < 1e-6, "r drift at t = \(t), dot \(i)")
                #expect(abs(dot.ink - b[i].ink) < 1e-6, "ink drift at t = \(t), dot \(i)")
            }
        }
    }

    @Test("the period really is 16π")
    func periodValue() {
        #expect(abs(OrbitsMode.period - 16 * .pi) < tolerance)
    }

    @Test("every angular rate sits on the quantum lattice")
    func ratesAreQuantised() {
        // The yaw included — it is the rate most easily "tidied" back to
        // upstream's 0.12 by someone diffing the two files.
        #expect(abs(OrbitsMode.yawRate.remainder(dividingBy: OrbitsMode.quantum)) < tolerance)

        for orbit in 0..<OrbitsProfile.row.orbitCount {
            let rate = OrbitsMode.quantise(0.25 + 0.55 * orbHash(Double(orbit), 8.9))
            #expect(abs(rate.remainder(dividingBy: OrbitsMode.quantum)) < tolerance)
            // Never zero: a stationary orbit reads as a rendering bug.
            #expect(rate >= OrbitsMode.quantum)
        }
    }

    @Test("quantisation matches the reference implementation's buckets")
    func quantisedRates() {
        let expected = [0.375, 0.5, 0.625]
        for (orbit, want) in expected.enumerated() {
            let rate = OrbitsMode.quantise(0.25 + 0.55 * orbHash(Double(orbit), 8.9))
            #expect(abs(rate - want) < tolerance, "orbit \(orbit)")
        }
    }

    // MARK: - Rest

    @Test("the rest frame is a representative still, not the degenerate t = 0")
    func restPhaseIsRepresentative() {
        // Upstream uses 0.6 for `prefers-reduced-motion`; we reuse it for every
        // settled row. If it were 0 the particles would sit at their seeded
        // start angles, which is a noticeably flatter picture.
        #expect(OrbitsMode.restPhase == 0.6)
        #expect(dots(OrbitsMode.restPhase) != dots(0))
    }

    @Test("the rest frame is stable across calls")
    func restIsDeterministic() {
        #expect(dots(OrbitsMode.restPhase) == dots(OrbitsMode.restPhase))
    }
}

/// `[x, y, z, r, ink, alpha]`, in the order the reference implementation prints.
private func expectDot(_ dot: OrbDot, _ want: [Double], sourceLocation: SourceLocation = #_sourceLocation) {
    let got = [dot.x, dot.y, dot.z, dot.r, dot.ink, dot.alpha].map(Double.init)
    for (i, expected) in want.enumerated() {
        #expect(abs(got[i] - expected) < tolerance, "component \(i)", sourceLocation: sourceLocation)
    }
}
