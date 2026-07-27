import Foundation
import Testing

@testable import AgentNotchCore

/// Ordering is built entirely through the public API — `apply`, `seed`, `reap`.
/// There is no back door that pokes rows in directly, so what is asserted here
/// is reachable in production.
@Suite("SessionRegistry: ordering and aggregate")
struct SessionRegistryOrderingTests {
    @Test("state tiers sort attention > stale > working > done > idle")
    func stateTiers() {
        var r = registry(alive: [1])

        // Only this one is old enough for the reaper to relabel.
        r.apply(env("PreToolUse", id: "stale", pid: 1), now: t0)
        let now = t0.addingTimeInterval(700) // > policy.stale (600), < policy.reap (1800)
        r.reap(now: now)
        #expect(r["stale"]?.state == .stale)

        r.apply(env("PermissionRequest", id: "attention"), now: now)
        r.apply(env("PreToolUse", id: "working"), now: now)
        r.apply(env("Stop", id: "done"), now: now)
        r.apply(env("SessionStart", id: "idle"), now: now)

        #expect(r.ordered().map(\.id) == ["attention", "stale", "working", "done", "idle"])
    }

    @Test("within a tier, hook-truth sorts before a bootstrap guess — even a newer one")
    func originBreaksTiesAndOutranksRecency() {
        var r = registry()
        r.apply(env("SessionStart", id: "real", tty: "ttys011", pid: 11), now: t0)
        r.seed(
            [DiscoveredProcess(pid: 10, tty: "ttys010")],
            source: .claudeCode,
            now: t0.addingTimeInterval(600) // strictly newer than the real row
        )

        #expect(r.ordered().map(\.id) == ["real", "boot:10"])
    }

    @Test("within a tier and origin, the most recent updatedAt is first")
    func recencyBreaksTies() {
        var r = registry()
        r.apply(env("PreToolUse", id: "old"), now: t0)
        r.apply(env("PreToolUse", id: "mid"), now: t0.addingTimeInterval(30))
        r.apply(env("PreToolUse", id: "new"), now: t0.addingTimeInterval(60))

        #expect(r.ordered().map(\.id) == ["new", "mid", "old"])
    }

    @Test("a fully tied pair still has a total order, so the list never shuffles")
    func idIsTheFinalTieBreak() {
        var r = registry()
        r.apply(env("PreToolUse", id: "bbb"), now: t0)
        r.apply(env("PreToolUse", id: "aaa"), now: t0)

        #expect(r.ordered().map(\.id) == ["aaa", "bbb"])
        #expect(r.ordered().map(\.id) == ["aaa", "bbb"]) // stable across calls
    }

    @Test("ordered() returns every session exactly once")
    func orderedIsComplete() {
        var r = registry()
        for i in 0..<25 { r.apply(env("PreToolUse", id: "s\(i)"), now: t0) }

        #expect(r.ordered().count == 25)
        #expect(Set(r.ordered().map(\.id)).count == 25)
    }

    @Test("aggregate of an empty registry has no top state")
    func emptyAggregate() {
        let a = registry().aggregate()

        #expect(a.count == 0)
        #expect(a.top == nil)
        #expect(a.attentionCount == 0)
        #expect(a.hasUnknown == false)
    }

    @Test("aggregate reports the top state, the attention count and any guesswork")
    func aggregate() {
        var r = registry()
        r.apply(env("PermissionRequest", id: "a"), now: t0)
        r.apply(env("PermissionRequest", id: "b"), now: t0)
        r.apply(env("PreToolUse", id: "c"), now: t0)
        r.seed([DiscoveredProcess(pid: 10, tty: "ttys010")], source: .claudeCode, now: t0)

        let a = r.aggregate()
        #expect(a.count == 4)
        #expect(a.top == .needsAttention)
        #expect(a.attentionCount == 2)
        #expect(a.hasUnknown == true)
    }

    @Test("hasUnknown clears once the guess is adopted by a real hook event")
    func aggregateAfterAdoption() {
        var r = registry()
        r.seed([DiscoveredProcess(pid: 10, tty: "ttys010")], source: .claudeCode, now: t0)
        #expect(r.aggregate().hasUnknown == true)

        r.apply(env("PreToolUse", id: "real", pid: 10), now: t0.addingTimeInterval(1))

        let a = r.aggregate()
        #expect(a.count == 1)
        #expect(a.top == .working)
        #expect(a.hasUnknown == false)
    }

    @Test("statePriority is the documented total order")
    func priorities() {
        #expect(statePriority(.needsAttention) == 4)
        #expect(statePriority(.stale) == 3)
        #expect(statePriority(.working) == 2)
        #expect(statePriority(.done) == 1)
        #expect(statePriority(.idle) == 0)
    }
}
