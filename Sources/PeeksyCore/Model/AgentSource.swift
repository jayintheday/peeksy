import Foundation

/// The coding agent a session came from.
///
/// One case today. It is an enum rather than a bare `String` so that the URL
/// route `/v1/event/{source}`, the launch-time process scan and the row badge
/// all agree on exactly one spelling, and so that adding a second agent is a
/// compile-time checklist rather than a grep.
public enum AgentSource: String, Sendable, Codable, CaseIterable {
    case claudeCode = "claude-code"
    case codex

    /// A second agent that exists only so the seam can be exercised.
    ///
    /// Deliberately ABSENT from `AgentRegistry.all`, so `POST /v1/event/mock`
    /// in the shipped app is inert: the router answers 204 and logs an unknown
    /// source, exactly like any other unrecognised route. The test target
    /// supplies its own adapter and its own lookup — see `MockAdapter`.
    ///
    /// It lives here rather than in the tests because `HookEnvelope.source` is
    /// typed, and needing a case is item one of the compile-time checklist this
    /// enum's whole design is a bet on. If adding an agent had required a change
    /// to `Session`, `SessionRegistry` or a view, the bet would have been lost.
    case mock

    /// Human-facing name. The raw value is the wire/route spelling.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .mock: return "Mock Agent"
        }
    }
}
