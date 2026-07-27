import Foundation
import Testing

@testable import AgentNotchCore

/// Real `ps -Ao pid=,ppid=,tty=,comm=` output, captured on the machine this was
/// built for. Every awkward case in it is load-bearing:
///
///  * `Claude Helper (Renderer)` — spaces AND parentheses in `comm`, which is
///    why only the first three fields may be split;
///  * `.../claude-code/2.1.219/claude.app/Contents/MacOS/claude` — basename
///    `claude`, but tty `??`. This is Claude.app's embedded agent. It must NOT
///    be seeded: there is no terminal to jump to, and the hook-driven row that
///    arrives moments later already knows to raise the owning app instead;
///  * the two real sessions, `comm` == `claude`, on `ttys000` and `ttys002`.
private let realPS = """
 3953   728 ??       /Applications/Claude.app/Contents/Helpers/chrome-native-host
27523     1 ??       /Applications/Claude.app/Contents/MacOS/Claude
27553     1 ??       /Applications/Claude.app/Contents/Frameworks/Electron Framework.framework/Helpers/chrome_crashpad_handler
27554 27523 ??       /Applications/Claude.app/Contents/Frameworks/Claude Helper.app/Contents/MacOS/Claude Helper
27559 27523 ??       /Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)
27991 27523 ??       /Applications/Claude.app/Contents/Frameworks/Claude Helper (Plugin).app/Contents/MacOS/Claude Helper (Plugin)
27992 27523 ??       /Applications/Claude.app/Contents/Helpers/disclaimer
37254 27523 ??       /Applications/Claude.app/Contents/Helpers/disclaimer
37255 37254 ??       /Users/vijay/Library/Application Support/Claude/claude-code/2.1.219/claude.app/Contents/MacOS/claude
47624 47194 ttys000  claude
 5175  4781 ttys002  claude
  501     1 ??       /usr/libexec/opendirectoryd
"""

@Suite("ProcessScan: ps")
struct ProcessScanPSTests {

    @Test("only tty-backed processes named claude survive the filter")
    func filtersRealOutput() {
        let found = ProcessScan.parsePS(realPS, names: ["claude"])
        #expect(found.map(\.pid).sorted() == [5175, 47624])
        #expect(found.first { $0.pid == 47624 }?.tty == "ttys000")
        #expect(found.first { $0.pid == 5175 }?.tty == "ttys002")
    }

    @Test("Claude.app's embedded agent is skipped — it has no terminal to jump to")
    func skipsEmbeddedAgent() {
        // pid 37255: basename IS `claude`, so a name-only filter would seed it,
        // producing a permanently unclickable row that competes with the real
        // hook-driven one.
        let found = ProcessScan.parsePS(realPS, names: ["claude"])
        #expect(!found.contains { $0.pid == 37255 })
    }

    @Test("a comm with spaces and parentheses does not derail the parse")
    func handlesSpacesInComm() {
        // Not selected here, but if the split were wrong these lines would throw
        // the field indices off for every line after them.
        let found = ProcessScan.parsePS(realPS, names: ["Claude Helper (Renderer)"])
        #expect(found.isEmpty) // tty is ??, so still nothing — by the tty rule, not by accident

        let onATty = ProcessScan.parsePS(
            "27559 27523 ttys009  /Applications/Claude.app/Contents/MacOS/Claude Helper (Renderer)",
            names: ["Claude Helper (Renderer)"])
        #expect(onATty.map(\.pid) == [27559])
    }

    @Test("a full executable path matches on its basename")
    func matchesBasename() {
        let text = "1234 1 ttys003  /Users/vijay/.local/share/claude/versions/2.1.220/claude"
        #expect(ProcessScan.parsePS(text, names: ["claude"]).map(\.pid) == [1234])
    }

    @Test("an unknown agent name matches nothing")
    func unknownName() {
        #expect(ProcessScan.parsePS(realPS, names: ["gemini"]).isEmpty)
    }

    @Test("empty and malformed input yield nothing rather than crashing")
    func junkInput() {
        #expect(ProcessScan.parsePS("", names: ["claude"]).isEmpty)
        #expect(ProcessScan.parsePS("\n\n  \n", names: ["claude"]).isEmpty)
        #expect(ProcessScan.parsePS("not a ps line", names: ["claude"]).isEmpty)
        #expect(ProcessScan.parsePS("abc def ttys000 claude", names: ["claude"]).isEmpty) // bad pid
    }

    @Test("only /dev/ttysNNN counts as a terminal")
    func ttyRule() {
        #expect(ProcessScan.isTerminalTTY("ttys000"))
        #expect(ProcessScan.isTerminalTTY("ttys123"))
        #expect(ProcessScan.isTerminalTTY("/dev/ttys004"))
        // ?? is "no controlling terminal"; the rest are real device names that
        // Terminal.app cannot be asked about.
        #expect(!ProcessScan.isTerminalTTY("??"))
        #expect(!ProcessScan.isTerminalTTY("?"))
        #expect(!ProcessScan.isTerminalTTY("-"))
        #expect(!ProcessScan.isTerminalTTY("console"))
        #expect(!ProcessScan.isTerminalTTY("ttyp0"))
        #expect(!ProcessScan.isTerminalTTY("ttys"))
        #expect(!ProcessScan.isTerminalTTY("ttysX"))
        #expect(!ProcessScan.isTerminalTTY(""))
    }
}

@Suite("ProcessScan: lsof")
struct ProcessScanLsofTests {

    /// Real `lsof -a -p 47624,5175 -d cwd -Fpn` output.
    private let realLsof = """
    p5175
    fcwd
    n/Users/vijay/Desktop/TestRepo/agent-notch
    p47624
    fcwd
    n/Users/vijay/Desktop/TestRepo/agent-notch
    """

    @Test("the -F field format maps pids to cwds")
    func parsesFieldFormat() {
        let cwds = ProcessScan.parseLsofCwd(realLsof)
        #expect(cwds == [5175: "/Users/vijay/Desktop/TestRepo/agent-notch",
                         47624: "/Users/vijay/Desktop/TestRepo/agent-notch"])
    }

    @Test("a cwd containing a space survives — the whole reason for -F")
    func handlesSpaces() {
        let cwds = ProcessScan.parseLsofCwd("p42\nfcwd\nn/Users/x/My Projects/thing\n")
        #expect(cwds[42] == "/Users/x/My Projects/thing")
    }

    @Test("a process with no cwd line is simply absent")
    func missingPath() {
        let cwds = ProcessScan.parseLsofCwd("p1\nfcwd\np2\nfcwd\nn/tmp\n")
        #expect(cwds[1] == nil)
        #expect(cwds[2] == "/tmp")
    }

    @Test("a warning line before the path does not become the path")
    func ignoresNonPaths() {
        let cwds = ProcessScan.parseLsofCwd("p7\nfcwd\nnno such file\nn/real/path\n")
        // Only entries that look like paths are taken, so a first-wins rule
        // cannot be poisoned by lsof's error text.
        #expect(cwds[7] == "/real/path")
    }

    @Test("junk yields an empty map")
    func junk() {
        #expect(ProcessScan.parseLsofCwd("").isEmpty)
        #expect(ProcessScan.parseLsofCwd("garbage\nmore garbage").isEmpty)
    }

    @Test("merge folds cwds in without inventing processes")
    func merges() {
        let processes = [
            DiscoveredProcess(pid: 1, tty: "ttys000"),
            DiscoveredProcess(pid: 2, tty: "ttys001"),
        ]
        let merged = ProcessScan.merge(processes, cwds: [1: "/a", 3: "/nope"])
        #expect(merged.count == 2)
        #expect(merged[0].cwd == "/a")
        #expect(merged[1].cwd == nil)
    }
}

@Suite("ProcessScan → SessionRegistry.seed")
struct ProcessScanSeedTests {

    @Test("a scan of the real ps output seeds exactly the two live sessions")
    func seedsFromRealOutput() throws {
        let found = ProcessScan.merge(
            ProcessScan.parsePS(realPS, names: ClaudeCodeAdapter.processNames),
            cwds: ProcessScan.parseLsofCwd("p5175\nfcwd\nn/Users/vijay/proj-a\np47624\nfcwd\nn/Users/vijay/proj-b"))

        var r = registry()
        let created = r.seed(found, source: .claudeCode, now: t0)

        #expect(created.sorted() == ["boot:47624", "boot:5175"])
        let s = try #require(r["boot:5175"])
        #expect(s.tty == "ttys002")
        #expect(s.cwd == "/Users/vijay/proj-a")
        // A guess must never manufacture urgency, and the list renders
        // `.bootstrap` as "waiting…" rather than as a state.
        #expect(s.state == .idle)
        #expect(s.origin == .bootstrap)
    }

    @Test("a hook event that beat the scan wins: no duplicate row")
    func hookBeatsScan() {
        var r = registry()
        // The socket is listening before the scan runs, so this ordering is the
        // one that actually happens on a busy machine.
        r.apply(env("PreToolUse", id: "real-1", tty: "ttys000", pid: 47624, at: t0), now: t0)

        let found = ProcessScan.parsePS(realPS, names: ClaudeCodeAdapter.processNames)
        let created = r.seed(found, source: .claudeCode, now: t0)

        #expect(created == ["boot:5175"])
        #expect(r.sessions.count == 2)
        #expect(r["boot:47624"] == nil)
    }
}
