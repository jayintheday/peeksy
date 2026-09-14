import Foundation

/// Everything agent-specific lives behind this protocol.
///
/// Static-only on purpose: an adapter has no state, so there is nothing to own,
/// nothing to inject and nothing to isolate.
public protocol AgentAdapter: Sendable {
    static var source: AgentSource { get }
    /// `nil` means "drop this event" — the router then answers 204 anyway.
    static func normalize(_ raw: RawPayload, now: Date) -> HookEnvelope?
    /// argv[0] basenames this agent presents in `ps`. Claude Code: `["claude"]`.
    static var processNames: Set<String> { get }
}

/// Lookup by wire identity.
public enum AgentRegistry {
    /// Computed, not a stored global: a stored `let` of existential metatypes
    /// buys nothing and costs a global-initialiser.
    public static var all: [any AgentAdapter.Type] {
        [ClaudeCodeAdapter.self, CodexAdapter.self]
    }

    public static var processNames: Set<String> {
        all.reduce(into: Set<String>()) { $0.formUnion($1.processNames) }
    }

    public static func adapter(for source: AgentSource) -> (any AgentAdapter.Type)? {
        all.first { $0.source == source }
    }

    /// Resolve the `{source}` component of `POST /v1/event/{source}`.
    public static func adapter(forPathComponent component: String) -> (any AgentAdapter.Type)? {
        let cleaned = component
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard let source = AgentSource(rawValue: cleaned) else { return nil }
        return adapter(for: source)
    }

    /// Which adapter owns a process named `name` in `ps` output.
    public static func adapter(forProcessName name: String) -> (any AgentAdapter.Type)? {
        all.first { $0.processNames.contains(name) }
    }
}
