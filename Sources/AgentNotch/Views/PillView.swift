import AgentNotchCore
import SwiftUI

/// The collapsed indicator: `[dot] 3`, sitting immediately to the right of the
/// hardware notch and painted on the same continuous black shape, so it reads as
/// part of the bezel rather than as a floating widget.
///
/// No `TimelineView`, no pulsing, no breathing. That is M4, and when it arrives
/// it must be gated on `status == .working` AND on visibility — an unconditional
/// `TimelineView` in a menu-bar app burns CPU twenty-four hours a day to animate
/// something nobody is looking at.
struct PillView: View {
    let aggregate: Aggregate
    /// The pill's layout SLOT, from `NotchGeometry.pillRect`. The capsule is
    /// drawn smaller and centred inside it: the hover target is forgiving
    /// without the black shape growing to match.
    let slotWidth: CGFloat
    let bandHeight: CGFloat

    private static let capsuleWidth: CGFloat = 44
    private static let capsuleHeight: CGFloat = 22
    private static let dotSize: CGFloat = 6

    private var needsAttention: Bool { aggregate.attentionCount > 0 }

    var body: some View {
        capsule
            .frame(width: slotWidth, height: bandHeight)
            // The whole slot is the target, not just the drawn capsule.
            .contentShape(Rectangle())
    }

    private var capsule: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColour)
                .frame(width: Self.dotSize, height: Self.dotSize)
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
        .frame(
            width: aggregate.count > 0 ? Self.capsuleWidth : Self.capsuleHeight,
            height: Self.capsuleHeight
        )
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

    /// Static colours. M2's treatment, held deliberately: state is carried by
    /// hue, never by motion, until M4 says otherwise.
    private var dotColour: Color {
        if needsAttention { return .red }
        switch aggregate.top {
        case .needsAttention: return .red
        case .working: return .green
        case .stale: return .yellow
        case .done: return .cyan
        case .idle: return Color.white.opacity(0.55)
        case nil: return Color.white.opacity(0.28)
        }
    }
}
