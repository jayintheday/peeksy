import Foundation

/// One hook registration: the event, and the matcher Claude Code expects for it.
public struct HookEventSpec: Sendable, Equatable {
    public let event: String
    /// `nil` where the event takes no matcher — and that is NOT the same as
    /// `"*"`. Registering `Notification` with a matcher is the single most
    /// expensive mistake available here: it silently loses every attention
    /// event, which is the app's highest-value signal, and the failure looks
    /// exactly like "the app just never shows red".
    public let matcher: String?

    public init(event: String, matcher: String?) {
        self.event = event
        self.matcher = matcher
    }
}

/// The nine events AgentNotch registers, and the shape of the group it writes.
///
/// This is the single source of truth. `hooks/settings-snippet.json` is the
/// human-readable copy of the same thing and a test asserts the two agree, so
/// neither can drift.
public enum HookSpec {
    public static let events: [HookEventSpec] = [
        // Lifecycle and turn boundaries — no matcher.
        HookEventSpec(event: "SessionStart", matcher: nil),
        HookEventSpec(event: "SessionEnd", matcher: nil),
        HookEventSpec(event: "UserPromptSubmit", matcher: nil),
        HookEventSpec(event: "Stop", matcher: nil),
        HookEventSpec(event: "Notification", matcher: nil),
        // Tool traffic — matched against every tool.
        HookEventSpec(event: "PreToolUse", matcher: "*"),
        HookEventSpec(event: "PostToolUse", matcher: "*"),
        HookEventSpec(event: "PostToolUseFailure", matcher: "*"),
        HookEventSpec(event: "PermissionRequest", matcher: "*"),
    ]

    // Wire keys, named once so a typo cannot be spelled two different ways in
    // the writer and the reader.
    public static let hooksKey = "hooks"
    public static let matcherKey = "matcher"
    public static let typeKey = "type"
    public static let commandKey = "command"
    public static let commandType = "command"

    /// The canonical group AgentNotch writes: one command hook, nothing else.
    ///
    /// `matcher` is OMITTED rather than written as `null` when the spec has
    /// none — a `null` matcher is not the same JSON as an absent one, and only
    /// the absent form matches what Claude Code's own docs show.
    public static func group(command: String, matcher: String?) -> [String: Any] {
        var group: [String: Any] = [
            hooksKey: [[typeKey: commandType, commandKey: command] as [String: Any]]
        ]
        if let matcher, !matcher.isEmpty { group[matcherKey] = matcher }
        return group
    }

    /// Matcher of an existing group, with `""` folded onto `nil`.
    ///
    /// Claude Code treats an absent matcher and an empty one the same way, so
    /// distinguishing them here would make the installer rewrite a group that
    /// already works.
    public static func matcher(of group: [String: Any]) -> String? {
        guard let raw = group[matcherKey] as? String, !raw.isEmpty else { return nil }
        return raw
    }
}
