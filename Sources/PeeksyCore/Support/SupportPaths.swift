import Foundation

/// Fixed locations on disk.
///
/// The hook script does NOT run from the app bundle. `scripts/build_app.sh`
/// begins with `rm -rf dist/Peeksy.app`, so a command path pointing into
/// `Contents/Resources` disappears for the length of every rebuild — and a
/// registered hook whose file is missing makes Claude Code print an error on a
/// user's turn, which is precisely the fail-open contract this project is built
/// around. The script therefore lives in Application Support, beside the socket,
/// and the app refreshes it from the bundle at launch (see `HookScriptSync`).
public enum SupportPaths {
    /// `~/Library/Application Support/Peeksy`.
    public static func directory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Peeksy", isDirectory: true)
    }

    /// The installed hook script — the exact path written into
    /// `~/.claude/settings.json`.
    ///
    /// **`~/.peeksy/`, and NOT Application Support.** Claude Code executes
    /// a hook command through `/bin/sh -c`, which word-splits it, so a command
    /// containing `Application Support` dies as
    /// `/bin/sh: /Users/…/Library/Application: No such file or directory` — and
    /// because the failure is reported by Claude Code rather than by us, and the
    /// hook contract is fail-open silence, it looks exactly like an app that is
    /// simply never told anything.
    ///
    /// This is not a guess: every other hook-installing tool found on a real
    /// machine registers a space-free path under `$HOME` (`~/.<tool>/hooks/…`),
    /// which is the same conclusion reached the same way. This matches them.
    /// `shellQuoted` still guards the case where `$HOME` ITSELF has a space in
    /// it, which no amount of choosing our own path can avoid.
    public static func hookScript(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home
            .appendingPathComponent(".peeksy", isDirectory: true)
            .appendingPathComponent("peeksy-hook.sh", isDirectory: false)
    }

    /// Paths this app has registered in the past.
    ///
    /// Kept so an install can MIGRATE a stale registration rather than leaving a
    /// dead one behind next to a live one. Recognition is by script name (see
    /// `HookSpec.isOurCommand`); this list is for cleaning up the files.
    public static func legacyHookScripts(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            // Application Support, before the space-in-the-path problem below
            // moved it out.
            directory(home: home).appendingPathComponent(bundledHookName, isDirectory: false),
            // Everything the app shipped as AgentNotch, before the rename. The
            // directory was named after the app too, so both halves move.
            home
                .appendingPathComponent(".agent-notch", isDirectory: true)
                .appendingPathComponent("agent-notch-hook.sh", isDirectory: false),
            home
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("AgentNotch", isDirectory: true)
                .appendingPathComponent("agent-notch-hook.sh", isDirectory: false),
        ]
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
    public static let bundledHookName = "peeksy-hook.sh"
}
