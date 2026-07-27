import Foundation

/// Escapes a Swift string for interpolation into an AppleScript double-quoted
/// literal. Backslash first, then quote — reversing the order would double-escape
/// the backslashes introduced by the quote pass.
public func escapeAppleScript(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

/// Builds the Terminal.app focus script for an already-normalised tty
/// (bare `ttysNNN` — see `normalizeTty`). Pure string construction, no execution.
///
/// The script walks every window and every tab within it, matching against
/// `/dev/<tty>` because that is the form `tty of tab` reports.
///
/// All three mutations are required and none is redundant:
///   - `set frontmost of w to true` raises the right window
///   - `set selected of t to true`  selects the right tab inside that window
///   - `activate`                   brings Terminal.app itself to the front
///
/// Returns `"ok"` when a tab matched and was focused, `"notfound"` otherwise, so
/// the caller can tell a stale/closed session apart from a permission failure —
/// the latter surfaces as a non-zero exit with TCC markers on stderr.
public func buildFocusScript(normalizedTty tty: String) -> String {
    let target = escapeAppleScript("/dev/" + tty)
    return """
    tell application "Terminal"
      set targetTty to "\(target)"
      repeat with w in windows
        repeat with t in tabs of w
          if (tty of t) is targetTty then
            set frontmost of w to true
            set selected of t to true
            activate
            return "ok"
          end if
        end repeat
      end repeat
    end tell
    return "notfound"
    """
}
