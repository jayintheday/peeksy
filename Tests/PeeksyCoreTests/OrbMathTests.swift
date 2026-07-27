import Foundation
import Testing

@testable import PeeksyCore

/// Expected values come from a transliteration of upstream's `core.ts` run under
/// node, not from this port — a port checked against itself proves nothing. The
/// generator lives in the commit message for this file's suite; regenerate it by
/// transliterating `src/engine/core.ts` verbatim if upstream ever moves.
///
/// Tolerance is 1e-9. Both sides are IEEE754 float64 running identical formulas;
/// the only slack is that JavaScriptCore and Darwin's libm need not agree on the
/// last ulp of `sin`/`acos`/`pow`.
private let tolerance = 1e-9

@Suite("OrbMath")
struct OrbMathTests {

    // MARK: - Hash

    @Test("orbHash matches upstream hashD for every salt the orbits mode uses")
    func hashMatchesUpstream() {
        // (orbit index, salt) → expected, for the three salts and three orbits
        // that `OrbitsProfile.row` actually evaluates.
        let expected: [(Double, Double, Double)] = [
            (0, 1.7, 0.934379186), (0, 5.2, 0.746898294), (0, 8.9, 0.317445183),
            (1, 1.7, 0.906186929), (1, 5.2, 0.964177068), (1, 8.9, 0.376906108),
            (2, 1.7, 0.029261369), (2, 5.2, 0.775924185), (2, 8.9, 0.690018712),
        ]
        for (a, b, want) in expected {
            #expect(abs(orbHash(a, b) - want) < tolerance, "orbHash(\(a), \(b))")
        }
    }

    @Test("orbHash is always in [0, 1) even though its input is routinely negative")
    func hashStaysInUnitInterval() {
        // The intermediate is sin(...) × 43758.5453, so it spends half its life
        // negative. `truncatingRemainder` would hand back a negative here and
        // flip half the orbits inside out; only a floor toward -∞ is correct.
        for i in 0..<400 {
            let h = orbHash(Double(i), 8.9)
            #expect(h >= 0 && h < 1, "orbHash(\(i), 8.9) = \(h)")
        }
    }

    @Test("orbHash is pure — same input, same answer, no hidden state")
    func hashIsDeterministic() {
        #expect(orbHash(7, 5.2) == orbHash(7, 5.2))
    }

    // MARK: - Radius falloff

    @Test("orbRadiusScale matches upstream at the row size")
    func radiusScaleMatchesUpstream() {
        #expect(abs(orbRadiusScale(side: 16, power: 0.6) - 0.172265868) < tolerance)
    }

    @Test("orbRadiusScale is 1 at the 300pt frame it was tuned against")
    func radiusScaleIsUnityAtReference() {
        #expect(abs(orbRadiusScale(side: 300, power: 0.6) - 1) < tolerance)
    }

    @Test("orbRadiusScale grows with size but sub-linearly")
    func radiusScaleIsMonotonicAndSublinear() {
        var previous = 0.0
        for side in stride(from: 8.0, through: 64.0, by: 4.0) {
            let scale = orbRadiusScale(side: side, power: 0.6)
            #expect(scale > previous, "not monotonic at \(side)")
            previous = scale
        }
        // Sub-linear is the entire point: doubling the orb must NOT double the
        // dot radii, or a 16pt orb becomes three invisible specks.
        let single = orbRadiusScale(side: 16, power: 0.6)
        let double = orbRadiusScale(side: 32, power: 0.6)
        #expect(double < single * 2)
    }

    // MARK: - Projection

    @Test("projection centres on (cx, cy) and flips y into canvas space")
    func projectionCentresAndFlips() {
        let projection = OrbProjection(yaw: 0, tilt: 0, cx: 8, cy: 8)
        let origin = projection.project(0, 0, 0)
        #expect(abs(origin.x - 8) < tolerance)
        #expect(abs(origin.y - 8) < tolerance)

        // +y in model space must come out ABOVE centre on a y-down canvas.
        let up = projection.project(0, 3, 0)
        #expect(up.y < 8)
    }

    @Test("a zero yaw and tilt is the identity apart from the centring")
    func projectionIdentity() {
        let projection = OrbProjection(yaw: 0, tilt: 0, cx: 0, cy: 0)
        let p = projection.project(2, 3, 5)
        #expect(abs(p.x - 2) < tolerance)
        #expect(abs(p.y + 3) < tolerance)
        #expect(abs(p.z - 5) < tolerance)
    }

    @Test("projection preserves length — it rotates, it never scales")
    func projectionIsRigid() {
        let x = 2.0
        let y = 3.0
        let z = 5.0
        let projection = OrbProjection(yaw: 1.1, tilt: 0.3, cx: 0, cy: 0)
        let p = projection.project(x, y, z)
        let before = (x * x + y * y + z * z).squareRoot()
        let after = (p.x * p.x + p.y * p.y + p.z * p.z).squareRoot()
        #expect(abs(before - after) < tolerance)
    }
}
