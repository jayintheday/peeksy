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

/// The nine events Peeksy registers, and the shape of the group it writes.
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

    /// The canonical group Peeksy writes: one command hook, nothing else.
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

    /// JUST our block, ready to paste — the same shape as
    /// `hooks/settings-snippet.json` but carrying a real resolved command.
    ///
    /// This exists so `--print-hook-json` can answer "what do I add?" without
    /// answering "what else is in your settings file?". The obvious
    /// implementation of that flag — print the merged result — is a privacy
    /// problem the moment the project has users: the flag is documented as the
    /// paste-it-in-yourself escape hatch, the universal support request is
    /// "run this and paste the output", and a real `settings.json` carries
    /// every other tool the user has hooked up. Nine lines are ours; the rest
    /// is nobody's business.
    ///
    /// "What will change in MY file" is a different question with its own
    /// answer already: the unified diff from `HookInstaller.preview`.
    public static func snippet(command: String) -> [String: Any] {
        var groups: [String: Any] = [:]
        for spec in events {
            groups[spec.event] = [group(command: command, matcher: spec.matcher)]
        }
        return [hooksKey: groups]
    }

    /// The script's filename. The identity we recognise our own groups by.
    public static let scriptName = "peeksy-hook.sh"

    /// Filenames this project has shipped under before.
    ///
    /// The app was called AgentNotch until it was renamed, and a rename is not
    /// a fresh install: anybody already running it has nine groups in their
    /// `settings.json` pointing at `agent-notch-hook.sh`. Recognition is by
    /// FILENAME (see `isOurCommand`), so without this list those nine groups
    /// stop being ours the moment the binary is replaced — an install would
    /// append nine live groups beside nine dead ones, and an uninstall would
    /// leave the dead ones behind for the user to find by hand.
    ///
    /// Entries here are permanent. The cost of keeping one is a string; the
    /// cost of dropping one is somebody's settings file.
    public static let legacyScriptNames = ["agent-notch-hook.sh"]

    /// Every filename that identifies a group as ours, current and historical.
    public static var ownedScriptNames: [String] { [scriptName] + legacyScriptNames }

    /// A command string safe to hand to `/bin/sh -c`.
    ///
    /// Claude Code does not `exec` the command — it runs it through a shell,
    /// which word-splits. A path with a space in it therefore has to be quoted
    /// or it dies before the script is ever reached. Quoting is applied ONLY
    /// when it is needed, so the common case stays a plain readable path that
    /// works whether the consumer uses a shell or `exec`.
    public static func shellQuoted(_ path: String) -> String {
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-+=:,@%")
        guard path.unicodeScalars.contains(where: { !safe.contains($0) }) else { return path }
        // POSIX single-quoting: everything is literal, and an embedded quote is
        // spelled by closing, escaping, and reopening.
        return "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Undo `shellQuoted`, so a stored command can be compared to a path.
    public static func unquoted(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") else { return trimmed }
        return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: #"'\''"#, with: "'")
    }

    /// Is this command string one of ours?
    ///
    /// Exact match on the command we are installing, OR any command whose file
    /// is named `peeksy-hook.sh` — or any name this project has shipped under
    /// before. The second clause is what lets an install MIGRATE a registration
    /// written by an older version; without it, moving OR RENAMING the script
    /// would leave nine dead groups behind and add nine live ones beside them.
    /// No other tool ships a file by any of these names.
    public static func isOurCommand(_ command: String, desired: String) -> Bool {
        if command == desired { return true }
        let path = unquoted(command)
        if path == unquoted(desired) { return true }
        return ownedScriptNames.contains { path.hasSuffix("/" + $0) || path == $0 }
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
