import AgentNotchCore
import SwiftUI

/// The palette, in one place.
///
/// Five states plus "we are guessing", and both lists plus the pill read from
/// here. Colour is the ONLY channel state gets: nothing in this app moves except
/// the pill's dot, and that only while something is genuinely working. A
/// menu-bar app that animates all day to tell you nothing has changed is a
/// menu-bar app people quit.
enum RowTint: Equatable {
    case attention
    case stale
    case working
    case done
    case idle
    /// A launch-time guess, not hook-truth.
    case unknown

    var colour: Color {
        switch self {
        case .attention: return .red
        case .stale: return .orange
        case .working: return .green
        case .done: return .cyan
        case .idle: return .secondary
        case .unknown: return .secondary
        }
    }

    /// The notch panel paints on literal black with no vibrancy, so `.secondary`
    /// is invisible there and the greys have to be explicit.
    var notchColour: Color {
        switch self {
        case .attention: return Color(red: 1.00, green: 0.31, blue: 0.27)
        case .stale: return Color(red: 1.00, green: 0.72, blue: 0.20)
        case .working: return Color(red: 0.30, green: 0.85, blue: 0.42)
        case .done: return Color(red: 0.35, green: 0.78, blue: 0.98)
        case .idle: return Color.white.opacity(0.55)
        case .unknown: return Color.white.opacity(0.35)
        }
    }

    /// The pill's dot, from the aggregate rather than from one row.
    static func forAggregate(_ aggregate: Aggregate) -> RowTint {
        if aggregate.attentionCount > 0 { return .attention }
        switch aggregate.top {
        case .needsAttention: return .attention
        case .stale: return .stale
        case .working: return .working
        case .done: return .done
        case .idle: return .idle
        case nil: return .unknown
        }
    }
}
