import Foundation

/// tty formats differ across the two sides we bridge:
///   - the hook gives us "ttys003" (from `ps -o tty=`)
///   - Terminal.app AppleScript reports `tty of tab` as "/dev/ttys003"
/// so we normalise to the bare "ttysNNN" form and compare against "/dev/…".
///
/// Returns `nil` when the input carries no usable tty: `ps` emits `??` for a
/// process with no controlling terminal, and various shells/tools emit `?` or
/// `-` for the same idea. A `nil` here is the signal to short-circuit before we
/// ever spawn `osascript`.
public func normalizeTty(_ tty: String?) -> String? {
    guard let tty else { return nil }

    var s = tty.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty { return nil }

    // Sentinels meaning "no controlling terminal".
    if ttySentinels.contains(s) { return nil }

    if s.hasPrefix(devPrefix) {
        s = String(s.dropFirst(devPrefix.count))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    if s.isEmpty { return nil }
    // Re-check: "/dev/??" and friends normalise down to a sentinel.
    if ttySentinels.contains(s) { return nil }

    return s
}

private let devPrefix = "/dev/"
private let ttySentinels: Set<String> = ["", "??", "?", "-"]
