import Foundation
import Testing

@testable import PeeksyCore

@Suite("SessionRegistry: reaper")
struct SessionRegistryReapTests {
    private let policy = ReapPolicy(
        stale: 600, deadGrace: 45, orphanTTL: 600, permissionTTL: 300, scanFreshness: 60)

    /// A sweep taken at `t0` that saw these pids as agents.
    private func sweep(_ pids: Set<Int32>, at: Date = t0) -> AgentPidScan {
        AgentPidScan(pids: pids, at: at)
    }

    /// Reap at `now` with a sweep as fresh as the running app's would be — the
    /// store re-sweeps on the same 15 s tick, so the reaper never reads one
    /// more than a tick old. Passing a `t0` sweep into a reap ten minutes later
    /// would age it out and quietly test the stale path instead.
    private func reap(
        _ r: inout SessionRegistry, at now: Date, agents pids: Set<Int32>
    ) -> ReapResult {
        r.agentPidScan = AgentPidScan(pids: pids, at: now.addingTimeInterval(-15))
        return r.reap(now: now)
    }

    @Test("the default policy: 10 min stale, 45 s dead grace, 10 min orphan, 5 min permission")
    func defaultPolicy() {
        #expect(ReapPolicy.default.stale == 600)
        #expect(ReapPolicy.default.deadGrace == 45)
        #expect(ReapPolicy.default.orphanTTL == 600)
        #expect(ReapPolicy.default.permissionTTL == 300)
        #expect(ReapPolicy.default.scanFreshness == 60)
    }

    @Test("a working session goes stale exactly at the boundary, not before")
    func staleBoundary() {
        var r = registry(alive: [1], policy: policy)
        r.apply(env("PreToolUse", pid: 1), now: t0)

        #expect(r.reap(now: t0.addingTimeInterval(599)).staled.isEmpty)
        #expect(r["s1"]?.state == .working)

        let result = r.reap(now: t0.addingTimeInterval(600))
        #expect(result.staled == ["s1"])
        #expect(r["s1"]?.state == .stale)
    }

    @Test("only working sessions go stale")
    func onlyWorkingGoesStale() {
        var r = registry(alive: [1, 2, 3], policy: policy)
        r.apply(env("SessionStart", id: "idle", pid: 1), now: t0)
        r.apply(env("Stop", id: "done", pid: 2), now: t0)
        r.apply(env("PermissionRequest", id: "attention", pid: 3), now: t0)

        let result = r.reap(now: t0.addingTimeInterval(1000))

        #expect(result.staled.isEmpty)
        #expect(r["idle"]?.state == .idle)
        #expect(r["done"]?.state == .done)
        #expect(r["attention"]?.state == .needsAttention)
    }

    @Test("a dead session is removed at the dead-grace boundary, not before")
    func deadGraceBoundary() {
        var r = registry(alive: [], policy: policy) // pid 1 is gone
        r.apply(env("PreToolUse", pid: 1), now: t0)

        #expect(r.reap(now: t0.addingTimeInterval(44)).removed.isEmpty)
        #expect(r["s1"] != nil)

        let result = r.reap(now: t0.addingTimeInterval(45))
        #expect(result.removed == ["s1"])
        #expect(r["s1"] == nil)
    }

    @Test("a live AGENT pid is never reaped, however long it has been quiet")
    func livePidSurvives() {
        var r = registry(alive: [1], policy: policy)
        r.apply(env("PreToolUse", pid: 1), now: t0)

        // A full day quiet, with a fresh sweep still naming it an agent every
        // time. No time ceiling applies to `.alive` at all.
        let result = reap(&r, at: t0.addingTimeInterval(86_400), agents: [1])

        #expect(result.removed.isEmpty)
        #expect(r["s1"]?.state == .stale)
    }

    @Test("a session with no pid is unknown, and goes at the orphan TTL")
    func nilPidIsUnknown() {
        var r = registry(alive: [], policy: policy)
        r.apply(env("PreToolUse"), now: t0) // no _meta.pid ever arrived

        #expect(r.reap(now: t0.addingTimeInterval(599)).removed.isEmpty)
        #expect(r.reap(now: t0.addingTimeInterval(600)).removed == ["s1"])
    }

    // MARK: The IDE host

    /// The bug this whole split exists for. Cursor's agent panel runs its agent
    /// inside an extension-host helper, so the pid on the wire is that helper —
    /// it hosts many chats and outlives every one of them. Believing its
    /// liveness made those rows unremovable: removal wanted a dead pid, and the
    /// pid never died.
    @Test("a live pid that is NOT an agent is unknown, not alive")
    func liveNonAgentPidIsUnknown() {
        // pid 1 is alive, and the sweep says the only agent on the box is 99.
        var r = registry(alive: [1], policy: policy, agents: sweep([99]))
        r.apply(env("PreToolUse", pid: 1), now: t0)

        #expect(r.liveness(of: r["s1"]!, now: t0) == .unknown)
        #expect(reap(&r, at: t0.addingTimeInterval(599), agents: [99]).removed.isEmpty)
        #expect(r["s1"] != nil)

        #expect(reap(&r, at: t0.addingTimeInterval(600), agents: [99]).removed == ["s1"])
    }

    @Test("a live pid the sweep DID see is alive, and outlives the orphan TTL")
    func liveAgentPidIsAlive() {
        var r = registry(alive: [1], policy: policy, agents: sweep([1]))
        r.apply(env("PreToolUse", pid: 1), now: t0)

        #expect(r.liveness(of: r["s1"]!, now: t0) == .alive)
        #expect(reap(&r, at: t0.addingTimeInterval(600), agents: [1]).removed.isEmpty)
    }

    /// A failed `ps` must never be read as "nothing on this machine is an
    /// agent". That would put every live session on the orphan clock at once.
    @Test("with no sweep at all, a live pid stays alive")
    func noSweepMeansAlive() {
        var r = registry(alive: [1], policy: policy) // agentPidScan == nil
        r.apply(env("PreToolUse", pid: 1), now: t0)

        #expect(r.liveness(of: r["s1"]!, now: t0) == .alive)
        #expect(r.reap(now: t0.addingTimeInterval(600)).removed.isEmpty)
    }

    /// The same protection, one tick later: a sweep that stops being refreshed
    /// (`ps` wedged, the queue backed up) ages out into "no information" rather
    /// than staying frozen and slowly reaping everything it last missed.
    @Test("a sweep that stops refreshing ages out rather than accusing")
    func abandonedSweepStopsAccusing() {
        var r = registry(alive: [1], policy: policy, agents: sweep([99]))
        r.apply(env("PreToolUse", pid: 1), now: t0)

        // The sweep is never refreshed. By the orphan TTL it is ten minutes old
        // and no longer believed, so the row survives on the fallback.
        #expect(r.reap(now: t0.addingTimeInterval(600)).removed.isEmpty)
        #expect(r["s1"] != nil)
    }

    @Test("a sweep older than scanFreshness is ignored, not believed")
    func staleSweepIsIgnored() {
        var r = registry(alive: [1], policy: policy, agents: sweep([99]))
        r.apply(env("PreToolUse", pid: 1), now: t0)

        // At 59 s the sweep still counts and pid 1 is an impostor…
        #expect(r.liveness(of: r["s1"]!, now: t0.addingTimeInterval(59)) == .unknown)
        // …at 60 s it has aged out and we are back to knowing nothing.
        #expect(r.liveness(of: r["s1"]!, now: t0.addingTimeInterval(60)) == .alive)
    }

    @Test("a sweep timestamped in the future ages to zero, never to a negative")
    func futureSweepAgesToZero() {
        var r = registry(
            alive: [1], policy: policy, agents: sweep([99], at: t0.addingTimeInterval(10_000)))
        r.apply(env("PreToolUse", pid: 1), now: t0)

        // A sweep stamped ahead of `now` means the clock stepped BACKWARDS
        // between the two — the sweep is genuinely recent, so `max(0, …)` calls
        // it fresh and it is believed. The point of the hardening is that the
        // age is never negative; a negative age would pass every `<` comparison
        // in the file for as long as the skew lasted.
        #expect(r.liveness(of: r["s1"]!, now: t0) == .unknown)
    }

    @Test("a dead pid is dead whatever the sweep says")
    func deadBeatsSweep() {
        var r = registry(alive: [], policy: policy, agents: sweep([1]))
        r.apply(env("PreToolUse", pid: 1), now: t0)

        #expect(r.liveness(of: r["s1"]!, now: t0) == .dead)
        #expect(r.reap(now: t0.addingTimeInterval(45)).removed == ["s1"])
    }

    @Test("EPERM means alive: a pid we cannot signal is still a running session")
    func epermMeansAlive() {
        // launchd. Exists, and not ours to signal.
        #expect(systemPidLiveness(1) == true)
        #expect(systemPidLiveness(getpid()) == true)
        #expect(systemPidLiveness(0) == false)
        #expect(systemPidLiveness(-1) == false)
    }

    @Test("a pending permission expires at the TTL boundary")
    func permissionTTLBoundary() {
        var r = registry(alive: [1], policy: policy)
        r.apply(env("PermissionRequest", pid: 1, permissionRequestID: "req-1"), now: t0)

        #expect(r.reap(now: t0.addingTimeInterval(299)).permissionsExpired.isEmpty)
        #expect(r["s1"]?.pendingPermission != nil)

        let result = r.reap(now: t0.addingTimeInterval(300))
        #expect(result.permissionsExpired == ["s1"])
        #expect(r["s1"]?.pendingPermission == nil)
        // The state is left alone: the human still has not answered, so far as
        // we know. Only the prompt detail goes.
        #expect(r["s1"]?.state == .needsAttention)
    }

    @Test("a removed session is not also reported as staled or expired")
    func removalShortCircuits() {
        var r = registry(alive: [], policy: policy)
        r.apply(env("PermissionRequest", pid: 1, permissionRequestID: "req-1"), now: t0)
        r.apply(env("PreToolUse", id: "w", pid: 2), now: t0)

        let result = r.reap(now: t0.addingTimeInterval(1800))

        #expect(result.removed == ["s1", "w"])
        #expect(result.staled.isEmpty)
        #expect(result.permissionsExpired.isEmpty)
    }

    @Test("reap is idempotent")
    func reapIsIdempotent() {
        var r = registry(alive: [1], policy: policy)
        r.apply(env("PreToolUse", pid: 1), now: t0)
        r.apply(env("PermissionRequest", id: "p", pid: 1), now: t0)

        let now = t0.addingTimeInterval(700)
        let first = r.reap(now: now)
        let second = r.reap(now: now)

        #expect(first.staled == ["s1"])
        #expect(first.permissionsExpired == ["p"])
        #expect(second.isEmpty)
    }

    @Test("an empty registry reaps to nothing")
    func emptyReap() {
        var r = registry(policy: policy)
        #expect(r.reap(now: t0).isEmpty)
    }

    @Test("a wall clock that jumped BACKWARDS must not break the reaper")
    func negativeClockHardening() {
        var r = registry(alive: [], policy: policy)
        r.apply(env("PermissionRequest", pid: 1, permissionRequestID: "req-1"), now: t0)

        // Sleep/wake or an NTP step. Elapsed time is now negative; without
        // max(0, ...) every duration comparison would be nonsense.
        let result = r.reap(now: t0.addingTimeInterval(-100_000))

        #expect(result.isEmpty)
        #expect(r["s1"]?.pendingPermission != nil)
        #expect(r["s1"]?.state == .needsAttention)

        // And the clock coming back does the right thing rather than staying wedged.
        #expect(r.reap(now: t0.addingTimeInterval(1800)).removed == ["s1"])
    }

    @Test("a future updatedAt (clock stepped forward then back) never ages a session")
    func futureUpdatedAtIsNotAged() {
        var r = registry(alive: [], policy: policy)
        r.apply(env("PreToolUse", pid: 1), now: t0.addingTimeInterval(10_000))

        #expect(r.reap(now: t0).isEmpty)
        #expect(r["s1"]?.state == .working)
    }

    // MARK: Manual dismiss

    @Test("remove forgets a session and says whether there was one")
    func removeForgets() {
        var r = registry(alive: [1], policy: policy, agents: sweep([1]))
        r.apply(env("PreToolUse", pid: 1), now: t0)
        r.apply(env("PreToolUse", id: "other", pid: 1), now: t0)

        #expect(r.remove(id: "s1") == true)
        #expect(r["s1"] == nil)
        #expect(r["other"] != nil) // only the one asked for

        #expect(r.remove(id: "s1") == false) // idempotent
        #expect(r.remove(id: "never-existed") == false)
        #expect(r.sessions.count == 1)
    }

    @Test("a dismissed session comes back on its next hook event")
    func dismissIsNotDestructive() {
        var r = registry(alive: [1], policy: policy, agents: sweep([1]))
        r.apply(env("PreToolUse", pid: 1, toolName: "Bash"), now: t0)
        r.remove(id: "s1")

        r.apply(env("PreToolUse", pid: 1), now: t0.addingTimeInterval(5))

        #expect(r["s1"]?.state == .working)
        #expect(r["s1"]?.origin == .hook)
    }

    @Test("reap results are ordered by id, so a caller can diff two passes")
    func resultsAreDeterministic() {
        var r = registry(alive: [], policy: policy)
        for id in ["c", "a", "b"] { r.apply(env("PreToolUse", id: id), now: t0) }

        #expect(r.reap(now: t0.addingTimeInterval(1800)).removed == ["a", "b", "c"])
    }
}
