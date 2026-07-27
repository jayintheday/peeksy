import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Where the hook socket lives.
///
/// `sockaddr_un.sun_path` is a fixed 104-byte buffer on Darwin. Overflow is not
/// an error you get told about — `bind` just fails with something unhelpful, or
/// worse, silently truncates. Since the natural home is under
/// `~/Library/Application Support`, a long user home (a network account, an
/// unusual `$HOME`) can blow the limit, so there is a `/tmp` fallback.
public enum SocketPath {
    /// `sun_path` capacity in bytes, NUL terminator included.
    public static let sunPathLimit = 104

    /// `PEEKSY_SOCK` wins (tests and side-by-side runs), else
    /// `~/Library/Application Support/Peeksy/hook.sock`, else
    /// `/tmp/peeksy-<uid>.sock` when that would overflow `sun_path`.
    public static func resolve(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let override = env["PEEKSY_SOCK"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let preferred = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Peeksy", isDirectory: true)
            .appendingPathComponent("hook.sock", isDirectory: false)

        if fits(preferred.path) { return preferred }
        return fallback()
    }

    /// The `/tmp` escape hatch. Per-uid so two accounts never collide.
    public static func fallback(uid: uid_t = getuid()) -> URL {
        URL(fileURLWithPath: "/tmp/peeksy-\(uid).sock")
    }

    /// Does this path fit in `sun_path`, NUL included?
    public static func fits(_ path: String) -> Bool {
        path.utf8.count < sunPathLimit
    }
}
