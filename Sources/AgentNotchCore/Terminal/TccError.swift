import Foundation

/// Recognises TCC (Transparency, Consent and Control) denials in `osascript`
/// stderr so a blocked Apple event degrades into a one-off log line instead of
/// an opaque failure.
public enum Tcc {
    /// Matched case-insensitively against lowercased stderr.
    ///
    /// `-1743` is `errAEEventNotPermitted` — Automation denied. That is the one
    /// we actually expect to see. `-25211` and `-1719` are Accessibility-flavoured
    /// (`errAXAPIDisabled` / `errAXErrorCannotComplete` territory); this app never
    /// needs the Accessibility grant, but the check is a substring scan over a
    /// short string so keeping them costs nothing and makes the diagnosis honest
    /// if a future macOS re-routes the denial.
    static let markers = ["not authorized to send apple events",
                          "assistive access", "not allowed assistive",
                          "-1743", "-25211", "-1719"]

    public static func isTccError(_ stderr: String) -> Bool {
        let haystack = stderr.lowercased()
        return markers.contains { haystack.contains($0) }
    }

    public static let remedy = "macOS blocked AgentNotch from controlling Terminal. Enable it in System Settings → Privacy & Security → Automation → AgentNotch → Terminal."
}
