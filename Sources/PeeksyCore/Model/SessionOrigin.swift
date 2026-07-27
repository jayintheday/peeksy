import Foundation

/// Whether `Session.state` is hook-truth or a launch-time guess.
///
/// Deliberately NOT a 6th `SessionState`: provenance is orthogonal to activity.
/// A bootstrapped row can be `.idle` *and* unverified; once a hook fires for it
/// the origin flips to `.hook` and never flips back.
public enum SessionOrigin: Sendable, Equatable {
    /// The state came from a hook event. Trustworthy.
    case hook
    /// The row was synthesised from a launch-time process scan. A placeholder
    /// until a real hook event adopts it.
    case bootstrap
}
