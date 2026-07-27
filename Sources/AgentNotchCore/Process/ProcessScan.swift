import Foundation

/// Parsing for the launch-time process scan. Pure — every rule below is decided
/// against fixture text, not against whatever happens to be running.
public enum ProcessScan {

    // MARK: - ps

    /// Parse `ps -Ao pid=,ppid=,tty=,comm=`.
    ///
    /// Two rules, and both matter:
    ///
    ///  * **`basename(comm)`, not a substring of `args`.** `--doctor` used to
    ///    match "claude" anywhere in the command line and listed seventeen
    ///    Claude.app helper processes. `comm` is the executable; its basename is
    ///    the name the agent actually presents.
    ///  * **The tty must be a real `ttysNNN`.** `??` means no controlling
    ///    terminal. Claude.app embeds its own Claude Code, whose executable IS
    ///    named `claude` — seeding it would put a row on screen that no terminal
    ///    can be jumped to, competing with the real hook-driven row that arrives
    ///    a moment later with an app-activation fallback.
    ///
    /// `comm` can contain spaces (`Claude Helper (Renderer)`), so only the first
    /// three fields are split; everything after them is the command.
    public static func parsePS(_ text: String, names: Set<String>) -> [DiscoveredProcess] {
        var found: [DiscoveredProcess] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.drop { $0 == " " }
            let fields = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4 else { continue }

            guard let pid = Int32(fields[0]) else { continue }
            let tty = String(fields[2])
            guard isTerminalTTY(tty) else { continue }

            let comm = String(fields[3]).trimmingCharacters(in: .whitespaces)
            guard names.contains(basename(comm)) else { continue }

            found.append(DiscoveredProcess(pid: pid, tty: tty, cwd: nil))
        }
        return found
    }

    /// `ttys003` yes; `??`, `-`, `console`, `ttyp0` no.
    ///
    /// Anchored deliberately: `TerminalFocuser` can only address a Terminal.app
    /// tab through a `ttysNNN`, so anything else is a row that cannot be clicked.
    public static func isTerminalTTY(_ raw: String) -> Bool {
        var name = raw.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("/dev/") { name = String(name.dropFirst("/dev/".count)) }
        guard name.hasPrefix("ttys") else { return false }
        let digits = name.dropFirst(4)
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// Last path component. `claude` and
    /// `~/Library/.../claude.app/Contents/MacOS/claude` both yield `claude`.
    static func basename(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    // MARK: - lsof

    /// Parse `lsof -a -p <csv> -d cwd -Fpn`.
    ///
    /// The `-F` field format is one field per line, tagged by its first
    /// character: `p` opens a new process record, `n` is the path. Chosen over
    /// the default columnar output because a cwd containing a space is
    /// unparseable there and extremely ordinary on a Mac.
    public static func parseLsofCwd(_ text: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var current: Int32?
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            switch line.first {
            case "p":
                current = Int32(line.dropFirst())
            case "n":
                // First `n` per process wins: we asked for `-d cwd`, so there is
                // exactly one, but a warning line must never overwrite a path.
                if let pid = current, result[pid] == nil {
                    let path = String(line.dropFirst())
                    if path.hasPrefix("/") { result[pid] = path }
                }
            default:
                break
            }
        }
        return result
    }

    /// Fold cwds into the processes they belong to.
    public static func merge(
        _ processes: [DiscoveredProcess],
        cwds: [Int32: String]
    ) -> [DiscoveredProcess] {
        processes.map { DiscoveredProcess(pid: $0.pid, tty: $0.tty, cwd: cwds[$0.pid] ?? $0.cwd) }
    }
}
