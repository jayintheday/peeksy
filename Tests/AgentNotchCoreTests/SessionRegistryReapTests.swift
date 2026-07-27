import Foundation
import Testing

@testable import AgentNotchCore

@Suite("SessionRegistry: reaper")
struct SessionRegistryReapTests {
    private let policy = ReapPolicy(stale: 600, reap: 1800, permissionTTL: 300)

    @Test("the default policy is 10 / 30 / 5 minutes")
    func defaultPolicy() {
        #expect(ReapPolicy.default.stale == 600)
        #expect(ReapPolicy.default.reap == 1800)
        #expect(ReapPolicy.default.permissionTTL == 300)
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

    @Test("a dead session is removed at the reap boundary")
    func reapBoundary() {
        var r = registry(alive: [], policy: policy) // pid 1 is gone
        r.apply(env("PreToolUse", pid: 1), now: t0)

        #expect(r.reap(now: t0.addingTimeInterval(1799)).removed.isEmpty)
        #expect(r["s1"] != nil)

        let result = r.reap(now: t0.addingTimeInterval(1800))
        #expect(result.removed == ["s1"])
        #expect(r["s1"] == nil)
    }

    @Test("a live pid is never reaped, however long it has been quiet")
    func livePidSurvives() {
        var r = registry(alive: [1], policy: policy)
        r.apply(env("PreToolUse", pid: 1), now: t0)

        let result = r.reap(now: t0.addingTimeInterval(86_400))

        #expect(result.removed.isEmpty)
        #expect(r["s1"]?.state == .stale)
    }

    @Test("a session with no pid counts as dead")
    func nilPidCountsAsDead() {
        var r = registry(alive: [], policy: policy)
        r.apply(env("PreToolUse"), now: t0) // no _meta.pid ever arrived

        #expect(r.reap(now: t0.addingTimeInterval(1800)).removed == ["s1"])
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

    @Test("reap results are ordered by id, so a caller can diff two passes")
    func resultsAreDeterministic() {
        var r = registry(alive: [], policy: policy)
        for id in ["c", "a", "b"] { r.apply(env("PreToolUse", id: id), now: t0) }

        #expect(r.reap(now: t0.addingTimeInterval(1800)).removed == ["a", "b", "c"])
    }
}
