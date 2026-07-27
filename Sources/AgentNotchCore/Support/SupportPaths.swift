import Foundation

/// Fixed locations on disk.
///
/// The hook script does NOT run from the app bundle. `scripts/build_app.sh`
/// begins with `rm -rf dist/AgentNotch.app`, so a command path pointing into
/// `Contents/Resources` disappears for the length of every rebuild — and a
/// registered hook whose file is missing makes Claude Code print an error on a
/// user's turn, which is precisely the fail-open contract this project is built
/// around. The script therefore lives in Application Support, beside the socket,
/// and the app refreshes it from the bundle at launch (see `HookScriptSync`).
public enum SupportPaths {
    /// `~/Library/Application Support/AgentNotch`.
    public static func directory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AgentNotch", isDirectory: true)
    }

    /// The installed hook script — the exact string written into
    /// `~/.claude/settings.json`.
    public static func hookScript(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        directory(home: home).appendingPathComponent("agent-notch-hook.sh", isDirectory: false)
    }

    /// Claude Code's user settings. Read constantly, written only by
    /// `HookInstaller`, and never by anything else in this app.
    public static func claudeSettings(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    /// The script's filename inside the app bundle's `Resources`.
    public static let bundledHookName = "agent-notch-hook.sh"
}
