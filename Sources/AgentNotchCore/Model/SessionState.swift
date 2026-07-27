import Foundation

/// What a session is doing right now.
///
/// Five cases, deliberately. "We are not sure this is real" is *not* a sixth
/// case here — see `SessionOrigin`. Mixing provenance into state is what makes
/// these enums metastasise.
public enum SessionState: String, Sendable, CaseIterable, Codable {
    case idle
    case working
    case needsAttention
    case done
    case stale
}
