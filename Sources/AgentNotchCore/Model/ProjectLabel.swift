import Foundation

/// Turning a working directory into (a) a stable identity and (b) something a
/// human can read in ~20 columns.
///
/// The identity half is the interesting one. Basenames collide constantly on a
/// real machine — this one has `test-app/test-app-1` and
/// `snacksnap-master/project-snacksnap`, plus `TestRepo` and
/// `Testrepo-Friendsofclaude` which differ only by case and suffix. Keying on
/// the basename silently merges unrelated sessions, so `projectKey` is the FULL
/// path and only the *display* form is shortened.
public enum ProjectLabel {
    /// Stable identity for a working directory: the full path, normalised for
    /// trailing slashes. Never the basename.
    public static func projectKey(_ cwd: String?) -> String? {
        guard let cwd else { return nil }
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var s = trimmed
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// The last two path segments joined by `/`, e.g. `"TestRepo/agent-notch"`.
    /// A single-segment path returns that segment; `nil` in, `nil` out.
    public static func display(_ cwd: String?) -> String? {
        guard let key = projectKey(cwd) else { return nil }
        let segments = key.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = segments.last else { return key } // "/" and friends
        if segments.count == 1 { return String(last) }
        return "\(segments[segments.count - 2])/\(last)"
    }
}
