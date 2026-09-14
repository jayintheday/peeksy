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
            ? "Codex skips registered hooks until you trust them: open /hooks in Codex and trust the Peeksy hooks. A session trusted mid-run reports from its next prompt; sessions started before this install need restarting. `--doctor` shows what Codex has recorded."
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
        return codexHome(home: home, environment: environment).appendingPathComponent("hooks.json")
    }
    /// `$CODEX_HOME/config.toml` — where Codex keeps its hook trust records.
    /// Read by `--doctor` through `CodexHookTrust`; never written. `nil` for
    /// any agent but Codex.
    public func trustRecordURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        guard self == .codex else { return nil }
        return codexHome(home: home, environment: environment).appendingPathComponent("config.toml")
    }
    private func codexHome(home: URL, environment: [String: String]) -> URL {
        if let path = environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".codex")
    }
    public func installer(settings: URL? = nil, command: String? = nil) -> HookInstaller {
        HookInstaller(settingsURL: settings ?? settingsURL(),
                      command: command ?? HookSpec.shellQuoted(scriptURL().path),
                      source: source, events: events)
    }
}
