import AgentNotchCore
import AppKit
import SwiftUI

/// The collapsed indicator: `[dot] 3`, sitting immediately to the right of the
/// hardware notch and painted on the same continuous black shape, so it reads as
/// part of the bezel rather than as a floating widget.
///
/// The dot breathes while something is working — and ONLY then. See `breathing`.
struct PillView: View {
    let aggregate: Aggregate
    /// The pill's layout SLOT, from `NotchGeometry.pillRect` — all of which is
    /// the click target.
    let slotWidth: CGFloat
    /// The capsule's own width, from `NotchGeometry.pillContentRect`.
    ///
    /// Handed down from the geometry rather than decided here, so the menu bar
    /// pixels the window RESERVES and the pixels it PAINTS cannot drift apart.
    /// `NotchGeometryResolver.check` asserts they have not.
    let contentWidth: CGFloat
    let bandHeight: CGFloat
    /// False when the panel is ordered out — no menu bar, because another app is
    /// full screen, the bar is hidden, or the status item overflowed. An
    /// animation nobody can see is pure battery.
    let isVisible: Bool

    @State private var breathIn = false

    private var needsAttention: Bool { aggregate.attentionCount > 0 }
    private var tint: RowTint { RowTint.forAggregate(aggregate) }

    // MARK: - Motion

    /// THE THREE GATES. All of them, every time.
    ///
    ///  1. something is actually `.working` — a settled list must be still;
    ///  2. the pill is on screen;
    ///  3. Reduce Motion is off.
    ///
    /// Note what this is NOT: there is no `TimelineView` anywhere in this app.
    /// `TimelineView(.periodic)` installs a run-loop source that fires whether
    /// or not anything changed, and this window exists twenty-four hours a day.
    /// A `repeatForever` animation is handed to Core Animation, runs off the
    /// main thread, and stops dead the moment the gate below closes.
    private var breathing: Bool {
        isVisible && aggregate.top == .working && !reduceMotion
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private static let breath = Animation.easeInOut(duration: 1.1).repeatForever(autoreverses: true)

    var body: some View {
        capsule
            .frame(width: slotWidth, height: bandHeight)
            // The whole slot is the target, not just the drawn capsule.
            .contentShape(Rectangle())
            .onAppear { syncBreathing() }
            .onChange(of: breathing) { syncBreathing() }
    }

    /// Start and stop explicitly rather than letting a modifier decide.
    ///
    /// `.animation(_, value:)` would leave the `repeatForever` attached and
    /// merely stop retriggering it. Setting the value inside an explicit
    /// `withAnimation`, and setting it back inside a finite one, is what
    /// actually tears the repeat down.
    private func syncBreathing() {
        if breathing {
            withAnimation(Self.breath) { breathIn = true }
        } else {
            withAnimation(.easeOut(duration: 0.18)) { breathIn = false }
        }
    }

    private var capsule: some View {
        HStack(spacing: 4) {
            dot
            if aggregate.count > 0 {
                Text("\(aggregate.count)")
                    // SF Rounded reads as system chrome next to the menu bar.
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    // The width must not jitter as the count crosses 9 → 10;
                    // a pill that changes size on its own looks broken.
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: contentWidth, height: PillMetrics.capsuleHeight)
        .background(
            Capsule().fill(Color.white.opacity(needsAttention ? 0.10 : 0.06))
        )
        .overlay(
            // The stroke goes on the WHOLE pill, not just the dot. A 6 pt dot
            // beside a physical notch — itself a black shape with no edges — is
            // genuinely easy to miss.
            Capsule().strokeBorder(Color.red, lineWidth: needsAttention ? 1 : 0)
        )
        .animation(.default, value: aggregate.count)
    }

    /// The dot breathes in OPACITY and scale, never in position.
    ///
    /// A dot that moves next to a fixed hardware notch reads as the notch itself
    /// shifting, which is the one illusion this whole design exists to avoid.
    private var dot: some View {
        Circle()
            .fill(tint.notchColour)
            .frame(width: PillMetrics.dotSize, height: PillMetrics.dotSize)
            .scaleEffect(breathIn ? 1.30 : 1.0)
            .opacity(breathIn ? 0.55 : 1.0)
            // A halo, so "working" survives being a 6 pt dot on black. Part of
            // the same animation, not a second one.
            .background(
                Circle()
                    .fill(tint.notchColour.opacity(breathIn ? 0.20 : 0.0))
                    .frame(width: PillMetrics.dotSize * 2.6, height: PillMetrics.dotSize * 2.6)
            )
            .animation(.easeInOut(duration: 0.25), value: tint)
    }
}
