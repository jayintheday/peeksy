import Foundation

/// The supported install targets. Mock adapters are never installation targets.
public enum AgentHookConfiguration: String, CaseIterable, Sendable, Identifiable {
    case claudeCode = "claude-code"
    case codex
    public var id: String { rawValue }
    public var source: AgentSource { self == .codex ? .codex : .claudeCode }
    public var name: String { source.displayName }
    public var scriptName: String { self == .codex ? "peeksy-codex-hook.sh" : HookSpec.scriptName }
    public var events: [HookEventSpec] {
        guard self == .codex else { return HookSpec.events }
        return ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                "PermissionRequest", "Stop", "Interrupt", "SessionEnd"].map {
            HookEventSpec(event: $0, matcher: nil, timeout: 3)
        }
    }
    public var instructions: String {
        self == .codex
            ? "Open /hooks in Codex and review and trust the Peeksy hooks. Restart existing sessions if needed. Registered hooks cannot report activity until trusted."
            : "New Claude Code sessions pick this up automatically. Restart existing sessions, or use /hooks to reload."
    }
    public func scriptURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".peeksy").appendingPathComponent(scriptName)
    }
    public func settingsURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        guard self == .codex else { return SupportPaths.claudeSettings(home: home) }
        let root: URL
        if let path = environment["CODEX_HOME"], !path.isEmpty {
            root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            root = home.appendingPathComponent(".codex")
        }
        return root.appendingPathComponent("hooks.json")
    }
    public func installer(settings: URL? = nil, command: String? = nil) -> HookInstaller {
        HookInstaller(settingsURL: settings ?? settingsURL(),
                      command: command ?? HookSpec.shellQuoted(scriptURL().path),
                      source: source, events: events)
    }
}
