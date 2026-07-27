import Foundation

/// Sort weight for a state. Higher sorts first.
///
/// attention 4 > stale 3 > working 2 > done 1 > idle 0
///
/// `stale` outranks `working` on purpose: a session that has been "working" for
/// ten minutes with no events is far more likely to want a human than one that
/// is genuinely mid-turn.
public func statePriority(_ s: SessionState) -> Int {
    switch s {
    case .needsAttention: return 4
    case .stale: return 3
    case .working: return 2
    case .done: return 1
    case .idle: return 0
    }
}
