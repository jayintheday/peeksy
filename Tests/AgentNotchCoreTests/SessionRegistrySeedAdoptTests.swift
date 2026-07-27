import Foundation
import Testing

@testable import AgentNotchCore

@Suite("SessionRegistry: seed and adopt")
struct SessionRegistrySeedAdoptTests {
    @Test("seed creates boot:<pid> placeholders that are idle and flagged as guesses")
    func seedCreatesPlaceholders() throws {
        var r = registry()
        let created = r.seed(
            [
                DiscoveredProcess(pid: 101, tty: "ttys001", cwd: "/Users/x/proj-a"),
                DiscoveredProcess(pid: 102, tty: "ttys002", cwd: "/Users/x/proj-b"),
            ],
            source: .claudeCode,
            now: t0
        )

        #expect(created.sorted() == ["boot:101", "boot:102"])
        let s = try #require(r["boot:101"])
        #expect(s.state == .idle) // a guess must never manufacture urgency
        #expect(s.origin == .bootstrap)
        #expect(s.pid == 101)
        #expect(s.tty == "ttys001")
        #expect(s.cwd == "/Users/x/proj-a")
        #expect(s.createdAt == t0)
    }

    @Test("seeding twice is a no-op")
    func seedIsIdempotent() {
        var r = registry()
        let found = [DiscoveredProcess(pid: 101, tty: "ttys001")]
        r.seed(found, source: .claudeCode, now: t0)
        let second = r.seed(found, source: .claudeCode, now: t0.addingTimeInterval(60))

        #expect(second.isEmpty)
        #expect(r.sessions.count == 1)
    }

    @Test("seed → hook: the placeholder is folded in, not duplicated")
    func seedThenHook() throws {
        var r = registry()
        r.seed([DiscoveredProcess(pid: 101, tty: "ttys001", cwd: "/Users/x/proj-a")], source: .claudeCode, now: t0)

        let later = t0.addingTimeInterval(2400) // the session was already 40 minutes old
        r.apply(env("PreToolUse", id: "real-abc", pid: 101, at: later), now: later)

        #expect(r.sessions.count == 1)
        #expect(r["boot:101"] == nil)

        let s = try #require(r["real-abc"])
        #expect(s.origin == .hook)
        #expect(s.state == .working)
        // The whole point of bootstrapping: "started 40 minutes ago" survives.
        #expect(s.createdAt == t0)
        #expect(s.updatedAt == later)
        #expect(s.cwd == "/Users/x/proj-a") // carried forward though the hook had none
        #expect(s.tty == "ttys001")
        #expect(s.pid == 101)
    }

    @Test("hook → seed: a process already tracked by pid is not seeded again")
    func hookThenSeedByPID() {
        var r = registry()
        r.apply(env("SessionStart", id: "real-abc", tty: "ttys001", pid: 101), now: t0)

        let created = r.seed(
            [DiscoveredProcess(pid: 101, tty: "ttys001")],
            source: .claudeCode,
            now: t0.addingTimeInterval(1)
        )

        #expect(created.isEmpty)
        #expect(r.sessions.count == 1)
        #expect(r["real-abc"]?.origin == .hook)
    }

    @Test("hook → seed: a tty already tracked is not seeded again even when the pid differs")
    func hookThenSeedByTTY() {
        var r = registry()
        // The hook knows the tty but `ps` failed, so we never learned a pid.
        r.apply(env("SessionStart", id: "real-abc", tty: "ttys001"), now: t0)

        let created = r.seed(
            [DiscoveredProcess(pid: 101, tty: "ttys001")],
            source: .claudeCode,
            now: t0.addingTimeInterval(1)
        )

        #expect(created.isEmpty)
        #expect(r.sessions.count == 1)
    }

    @Test("adoption falls back to the tty when the hook carries no pid")
    func adoptByTTY() throws {
        var r = registry()
        r.seed([DiscoveredProcess(pid: 101, tty: "ttys001", cwd: "/p")], source: .claudeCode, now: t0)

        r.apply(env("UserPromptSubmit", id: "real-abc", tty: "ttys001"), now: t0.addingTimeInterval(5))

        #expect(r.sessions.count == 1)
        let s = try #require(r["real-abc"])
        #expect(s.createdAt == t0)
        #expect(s.pid == 101) // carried from the placeholder
    }

    @Test("adoption normalises a /dev-prefixed tty rather than failing to match")
    func adoptNormalisesTTY() {
        var r = registry()
        r.seed([DiscoveredProcess(pid: 101, tty: "/dev/ttys001")], source: .claudeCode, now: t0)

        let id = r.adopt(realID: "real-abc", pid: nil, tty: "ttys001", now: t0.addingTimeInterval(1))

        #expect(id == "boot:101")
        #expect(r["real-abc"]?.tty == "ttys001")
    }

    @Test("pid wins over tty when both could match")
    func pidBeatsTTY() {
        var r = registry()
        r.seed(
            [
                DiscoveredProcess(pid: 101, tty: "ttys001"),
                DiscoveredProcess(pid: 102, tty: nil),
            ],
            source: .claudeCode,
            now: t0
        )

        let adopted = r.adopt(realID: "real-abc", pid: 102, tty: "ttys001", now: t0.addingTimeInterval(1))

        #expect(adopted == "boot:102")
        #expect(r["boot:101"] != nil) // untouched
    }

    @Test("adopt is idempotent — a second hook event cannot consume a second placeholder")
    func adoptIsIdempotent() {
        var r = registry()
        r.seed(
            [
                DiscoveredProcess(pid: 101, tty: "ttys001"),
                DiscoveredProcess(pid: 102, tty: "ttys002"),
            ],
            source: .claudeCode,
            now: t0
        )

        r.apply(env("SessionStart", id: "real-abc", tty: "ttys001", pid: 101), now: t0.addingTimeInterval(1))
        r.apply(env("PreToolUse", id: "real-abc", tty: "ttys001", pid: 101), now: t0.addingTimeInterval(2))

        #expect(r.sessions.count == 2) // real-abc + the untouched boot:102
        #expect(r["boot:102"]?.origin == .bootstrap)
        #expect(r["real-abc"] != nil)
    }

    @Test("adopt refuses when the real id already exists")
    func adoptRefusesExistingID() {
        var r = registry()
        r.seed([DiscoveredProcess(pid: 101, tty: "ttys001")], source: .claudeCode, now: t0)
        r.apply(env("SessionStart", id: "real-abc"), now: t0)

        #expect(r.adopt(realID: "real-abc", pid: 101, tty: nil, now: t0) == nil)
        #expect(r["boot:101"] != nil)
    }

    @Test("adopt returns nil when there is nothing to adopt")
    func adoptWithNoPlaceholder() {
        var r = registry()

        #expect(r.adopt(realID: "real-abc", pid: 101, tty: "ttys001", now: t0) == nil)
        #expect(r.sessions.isEmpty)
    }

    @Test("adopt never consumes a session that is already hook-truth")
    func adoptSkipsRealSessions() {
        var r = registry()
        r.apply(env("SessionStart", id: "other", tty: "ttys001", pid: 101), now: t0)

        #expect(r.adopt(realID: "real-abc", pid: 101, tty: "ttys001", now: t0) == nil)
        #expect(r["other"] != nil)
    }

    @Test("a placeholder with no tty is still seeded")
    func seedWithoutTTY() {
        var r = registry()
        let created = r.seed([DiscoveredProcess(pid: 101, tty: nil, cwd: "/p")], source: .claudeCode, now: t0)

        #expect(created == ["boot:101"])
        #expect(r["boot:101"]?.tty == nil)
    }

    @Test("an unknown tty marker never matches another unknown tty")
    func unknownTTYIsNotAnIdentity() {
        var r = registry()
        // `ps -o tty=` prints "??" for a process with no controlling terminal;
        // two such processes are not the same session.
        r.seed([DiscoveredProcess(pid: 101, tty: "??")], source: .claudeCode, now: t0)
        let created = r.seed([DiscoveredProcess(pid: 102, tty: "??")], source: .claudeCode, now: t0)

        #expect(created == ["boot:102"])
        #expect(r.sessions.count == 2)
        #expect(r["boot:101"]?.tty == nil)
    }
}
