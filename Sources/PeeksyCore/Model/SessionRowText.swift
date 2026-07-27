import Foundation

/// The two lines of text on a session row.
///
/// Pure, and in Core rather than beside the views, because the rules need to see
/// ALL visible sessions at once (to spot a duplicate project) and because they
/// are the part of a row that can actually be wrong. Symbol, tint and state text
/// stay on the AppKit side — they are a switch over an enum.
public struct SessionRowText: Sendable, Equatable {
    /// Line one. Never empty.
    public let title: String
    /// Line two. `nil` when there is nothing worth saying.
    public let subtitle: String?

    public init(title: String, subtitle: String?) {
        self.title = title
        self.subtitle = subtitle
    }
}

/// Builds `SessionRowText` for a whole snapshot.
///
/// The ranking rule: **a session's task title is its identity when we know it.**
/// Three agents in one repo produce three rows reading `TestRepo/peeksy`
/// that differ only by a tty number nobody memorises, which defeats the entire
/// point of the list. Claude Code's own title — the one already on the user's
/// Terminal tab — is what tells them apart, so it takes line one and the project
/// label moves down to line two.
///
/// Nothing is dropped in the process. Project, tty disambiguation, owning IDE
/// and the live tool summary all still appear; they are re-ranked, not removed.
/// With no title known the output is byte-identical to what the row showed
/// before titles existed.
public enum SessionRowTextBuilder {
    private static let separator = " · "

    /// - Parameters:
    ///   - sessions: already ordered by the registry; this never re-sorts.
    ///   - taskTitle: by session id. `nil` until the transcript yields one.
    ///   - ownerName: by pid. `nil` for Terminal.app and for "no answer yet".
    public static func build(
        sessions: [Session],
        taskTitle: (String) -> String?,
        ownerName: (Int32) -> String?
    ) -> [SessionRowText] {
        // A project can legitimately have two agents in it (two tabs, same
        // repo). Showing "peeksy" twice is indistinguishable from a
        // duplicate-row bug, so BOTH get disambiguated — never just the second.
        var projectCounts: [String: Int] = [:]
        for session in sessions {
            guard let key = ProjectLabel.projectKey(session.cwd) else { continue }
            projectCounts[key, default: 0] += 1
        }

        return sessions.map { session in
            let hasTerminal = normalizeTty(session.tty) != nil
            let owner = session.pid.flatMap(ownerName)

            var parts: [String?] = [identity(for: session, hasTerminal: hasTerminal, owner: owner)]

            if let key = ProjectLabel.projectKey(session.cwd),
               projectCounts[key, default: 0] > 1,
               let tty = normalizeTty(session.tty) {
                parts.append(tty)
            }

            // A real tty owned by something other than Terminal.app is running
            // inside an IDE's integrated terminal (Zed, VS Code, Cursor…) — a
            // plain cwd, or even no cwd yet for a not-yet-adopted bootstrap row,
            // otherwise reads exactly like an ordinary Terminal session.
            if hasTerminal, let owner {
                parts.append(owner)
            }

            // A pending permission outranks tool activity: "what is being asked
            // of me" beats "what it was doing".
            let activity = session.pendingPermission?.summary ?? session.lastToolSummary

            guard let title = title(from: taskTitle(session.id)) else {
                // No title yet — the pre-titles layout, unchanged.
                return SessionRowText(title: join(parts) ?? session.source.displayName,
                                      subtitle: activity)
            }
            return SessionRowText(title: title, subtitle: join(parts + [activity]))
        }
    }

    /// Whatever identifies the session when its task title is unknown.
    private static func identity(
        for session: Session,
        hasTerminal: Bool,
        owner: String?
    ) -> String {
        if let project = ProjectLabel.display(session.cwd) { return project }
        // No cwd. For a tty-less session the owning application IS the most
        // useful identity we have ("Claude" for the desktop app's embedded
        // agent).
        if !hasTerminal, let owner { return owner }
        return session.source.displayName
    }

    /// A title we would actually put on a row, or `nil`.
    private static func title(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func join(_ parts: [String?]) -> String? {
        let kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: separator)
    }
}
