import Foundation

/// The coding agent a session came from.
///
/// One case today. It is an enum rather than a bare `String` so that the URL
/// route `/v1/event/{source}`, the launch-time process scan and the row badge
/// all agree on exactly one spelling, and so that adding a second agent is a
/// compile-time checklist rather than a grep.
public enum AgentSource: String, Sendable, Codable, CaseIterable {
    case claudeCode = "claude-code"

    /// Human-facing name. The raw value is the wire/route spelling.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        }
    }
}
