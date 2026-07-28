import Foundation

/// The IO shell around `ProcessScan`. Runs two short-lived tools and hands the
/// text to the pure parser.
///
/// Exists so the app can answer "what was already running when I launched?"
/// Without it, installing the hook still shows an empty panel for every session
/// that started first, and the app looks broken at exactly the moment somebody
/// is deciding whether to keep it.
///
/// `~/.claude/projects/<mangled-cwd>/<session_id>.jsonl` is NOT an alternative:
/// the directory mangling is lossy and the transcript carries no pid or tty at
/// all, so it cannot tell you which tab to focus — which is the whole point.
public struct ProcessScanner: Sendable {

    /// Hard ceiling per tool. A wedged `lsof` (a stale NFS mount is the classic)
    /// must not hold up a launch; a partial scan is strictly better than a hang,
    /// because every row it would have produced also arrives from the first hook
    /// event anyway.
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 2.0) {
        self.timeout = timeout
    }

    /// Every live agent process with a real terminal, with its cwd where we
    /// could get one. Blocking — call it off the main thread.
    ///
    /// `requireTerminal: false` widens it to tty-less agents for `--doctor`; see
    /// `ProcessScan.parsePS`. Nothing that seeds the registry may pass it.
    public func scan(
        names: Set<String> = ClaudeCodeAdapter.processNames,
        requireTerminal: Bool = true
    ) -> [DiscoveredProcess] {
        guard let listing = run("/bin/ps", ["-Ao", "pid=,ppid=,tty=,comm="]) else { return [] }
        let processes = ProcessScan.parsePS(listing, names: names, requireTerminal: requireTerminal)
        guard !processes.isEmpty else { return [] }

        // ONE lsof for all of them. Measured at ~26 ms for two pids; per-process
        // invocations would be a fork each and lsof is not cheap to start.
        let pids = processes.map { String($0.pid) }.joined(separator: ",")
        guard let open = run("/usr/sbin/lsof", ["-a", "-p", pids, "-d", "cwd", "-Fpn"]) else {
            // No cwd is a worse row, not a missing one: the label falls back to
            // the agent's name and the row still focuses its terminal.
            return processes
        }
        return ProcessScan.merge(processes, cwds: ProcessScan.parseLsofCwd(open))
    }

    /// Which live pids are agent processes. Blocking — call it off the main
    /// thread, same as `scan`.
    ///
    /// The `ps` half of `scan` and nothing else: `nil` when the sweep failed,
    /// which the reaper reads as "no information", never as "no agents". No
    /// `lsof` and no tty rule — a cwd is a label and a tty is a click target,
    /// and this answers neither question. It only asks whether a pid the reaper
    /// is about to trust belongs to an agent or to the IDE hosting one, and it
    /// runs every 15 s rather than once at launch, so the fork it does not do is
    /// the expensive one.
    public func liveAgentPids(names: Set<String> = ClaudeCodeAdapter.processNames) -> Set<Int32>? {
        guard let listing = run("/bin/ps", ["-Ao", "pid=,ppid=,tty=,comm="]) else { return nil }
        return Set(ProcessScan.parsePS(listing, names: names, requireTerminal: false).map(\.pid))
    }

    // MARK: - Private

    private func run(_ executable: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            Log.registry.error("scan: \(executable, privacy: .public) is not executable")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Log.registry.error("scan: could not run \(executable, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }

        // Read BEFORE waiting. `ps -A` on a busy machine can fill the 64 KB pipe
        // buffer, at which point the child blocks on write and `waitUntilExit`
        // never returns — a deadlock that only shows up under load.
        let deadline = Date().addingTimeInterval(timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        while process.isRunning && Date() < deadline {
            usleep(5_000)
        }
        if process.isRunning {
            process.terminate()
            Log.registry.error("scan: \(executable, privacy: .public) timed out")
            return nil
        }

        return String(decoding: data, as: UTF8.self)
    }
}
