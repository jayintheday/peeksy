import Foundation
import Testing
@testable import PeeksyCore

// MARK: - Fakes

/// A fake process tree: `parents[child] = parent`, `apps[pid] = the app that pid is`.
///
/// `helpers` marks pids that resolve to an application AppKit will happily hand
/// you and a human has never heard of — an Electron helper bundle. They are the
/// difference between the real chain and the one this used to model.
private struct FakeTree: Sendable {
    var parents: [Int32: Int32] = [:]
    var apps: [Int32: String] = [:]
    var helpers: Set<Int32> = []

    var resolve: SystemAppActivator.Resolve {
        let apps = self.apps
        let helpers = self.helpers
        return { pid in
            guard let name = apps[pid] else { return nil }
            return OwningApp(
                pid: pid,
                bundleID: "com.example.\(name.lowercased())",
                localizedName: name,
                isUserFacing: !helpers.contains(pid))
        }
    }

    var parentOf: SystemAppActivator.ParentOf {
        let parents = self.parents
        return { pid in parents[pid] }
    }
}

private final class Spy: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [OwningApp] = []
    private let succeed: Bool

    init(succeed: Bool = true) { self.succeed = succeed }

    var calls: [OwningApp] {
        lock.lock(); defer { lock.unlock() }
        return seen
    }

    var activate: SystemAppActivator.Activate {
        { [self] app in
            lock.lock(); seen.append(app); lock.unlock()
            return succeed
        }
    }
}

/// Counts resolution attempts so the hop bound is asserted on behaviour, not on
/// a constant.
private final class CountingResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [Int32] = []

    var seen: [Int32] {
        lock.lock(); defer { lock.unlock() }
        return attempts
    }

    var resolve: SystemAppActivator.Resolve {
        { [self] pid in
            lock.lock(); attempts.append(pid); lock.unlock()
            return nil
        }
    }
}

private func activator(
    _ tree: FakeTree,
    activate: @escaping SystemAppActivator.Activate = { _ in true }
) -> SystemAppActivator {
    SystemAppActivator(resolve: tree.resolve, parentOf: tree.parentOf, activate: activate)
}

// MARK: - Owner resolution

@Suite("SystemAppActivator.owner")
struct SystemAppActivatorOwnerTests {

    @Test("a pid that is itself an application resolves with no walking")
    func directHit() {
        let tree = FakeTree(parents: [:], apps: [500: "Terminal"])
        let owner = activator(tree).owner(ofPid: 500)
        #expect(owner?.localizedName == "Terminal")
        #expect(owner?.pid == 500)
    }

    @Test("the embedded-claude shape: child pid walks up to the desktop app")
    func walksUpToClaudeApp() {
        // The observed real case: Claude.app spawns its own Claude Code, so the
        // hook reports a pid that NSRunningApplication has never heard of.
        let tree = FakeTree(
            parents: [37255: 37100, 37100: 900],
            apps: [900: "Claude"]
        )
        let owner = activator(tree).owner(ofPid: 37255)
        #expect(owner?.localizedName == "Claude")
        // The OwningApp carries the ANCESTOR pid, not the pid we asked about —
        // that is what gets activated.
        #expect(owner?.pid == 900)
    }

    @Test("the nearest USER-FACING application wins, not the outermost")
    func nearestAncestorWins() {
        let tree = FakeTree(
            parents: [10: 20, 20: 30],
            apps: [20: "Inner", 30: "Outer"]
        )
        #expect(activator(tree).owner(ofPid: 10)?.localizedName == "Inner")
    }

    @Test("the Cursor shape: an Electron helper is skipped for the app above it")
    func skipsElectronHelper() {
        // The observed real chain. `Cursor Helper (Plugin): extension-host …` is
        // a genuine NSRunningApplication — .accessory, bundle ID
        // com.github.Electron.helper, bundle inside Cursor.app/Contents/
        // Frameworks. Stopping there labelled the row with that whole string and
        // asked LaunchServices to open a bundle it will not open, which is what
        // put "The application "Cursor Helper (Plugin)" is not open anymore." on
        // the user's screen.
        let tree = FakeTree(
            parents: [90210: 74989, 74989: 74532],
            apps: [74989: "Cursor Helper (Plugin): extension-host (retrieval)", 74532: "Cursor"],
            helpers: [74989]
        )
        let owner = activator(tree).owner(ofPid: 90210)
        #expect(owner?.localizedName == "Cursor")
        #expect(owner?.pid == 74532)
    }

    @Test("nested helpers are skipped all the way up, not just one deep")
    func skipsSeveralHelpers() {
        // Cursor's extension hosts fork further helpers of their own.
        let tree = FakeTree(
            parents: [10: 20, 20: 30, 30: 40],
            apps: [20: "Helper (Renderer)", 30: "Helper (Plugin)", 40: "Cursor"],
            helpers: [20, 30]
        )
        #expect(activator(tree).owner(ofPid: 10)?.localizedName == "Cursor")
    }

    @Test("a chain of nothing but helpers has no owner — better than a bad one")
    func helpersOnlyIsNoOwner() {
        // Returning the helper would activate a bundle LaunchServices refuses to
        // open, and the failure is a system alert the user cannot act on. No
        // owner means the click does nothing, silently, which is the honest
        // outcome; a tty-backed row keeps its tty (see focusRoute's nil case).
        let tree = FakeTree(
            parents: [10: 20, 20: 30],
            apps: [20: "Helper (GPU)", 30: "Helper (Renderer)"],
            helpers: [20, 30]
        )
        #expect(activator(tree).owner(ofPid: 10) == nil)
    }

    @Test("a skipped helper still spends a hop")
    func helpersConsumeTheBound() {
        // The bound is on the WALK. If skipping were free, a pathological chain
        // of helpers would climb forever and the `seen` set would be the only
        // thing stopping it.
        var parents: [Int32: Int32] = [:]
        var apps: [Int32: String] = [:]
        var helpers: Set<Int32> = []
        for pid in Int32(10)...Int32(109) {
            parents[pid] = pid + 1
            apps[pid] = "Helper \(pid)"
            helpers.insert(pid)
        }
        apps[110] = "Faraway"
        let tree = FakeTree(parents: parents, apps: apps, helpers: helpers)
        #expect(activator(tree).owner(ofPid: 10) == nil)
    }

    @Test("a chain with no application anywhere is noOwner, not a crash")
    func noApplicationInChain() {
        let tree = FakeTree(parents: [10: 20, 20: 1], apps: [:])
        #expect(activator(tree).owner(ofPid: 10) == nil)
    }

    @Test("the walk stops at launchd rather than trying to raise pid 1")
    func stopsAtLaunchd() {
        let tree = FakeTree(parents: [10: 1], apps: [1: "launchd"])
        #expect(activator(tree).owner(ofPid: 10) == nil)
    }

    @Test("a pid with no parent record stops instead of looping")
    func unknownParentStops() {
        let tree = FakeTree(parents: [:], apps: [:])
        #expect(activator(tree).owner(ofPid: 42) == nil)
    }

    @Test("a non-positive pid never resolves")
    func nonPositivePid() {
        let tree = FakeTree(parents: [:], apps: [0: "Nope", -1: "Nope"])
        #expect(activator(tree).owner(ofPid: 0) == nil)
        #expect(activator(tree).owner(ofPid: -1) == nil)
    }

    @Test("the walk is bounded: a long chain gives up instead of climbing forever")
    func boundedHops() {
        // 100 links, application only at the very top.
        var parents: [Int32: Int32] = [:]
        for pid in Int32(10)...Int32(109) { parents[pid] = pid + 1 }
        let tree = FakeTree(parents: parents, apps: [110: "Faraway"])

        let counter = CountingResolver()
        let bounded = SystemAppActivator(
            resolve: counter.resolve,
            parentOf: tree.parentOf,
            activate: { _ in true }
        )
        #expect(bounded.owner(ofPid: 10) == nil)
        // maxHops parent traversals => maxHops + 1 resolution attempts.
        #expect(counter.seen.count == SystemAppActivator.maxHops + 1)
        #expect(counter.seen == [10, 11, 12, 13, 14, 15])
    }

    @Test("a cycle in the reported parents terminates")
    func cycleTerminates() {
        // sysctl racing a reparent can hand back a parent that points back down.
        let tree = FakeTree(parents: [10: 20, 20: 10], apps: [:])
        #expect(activator(tree).owner(ofPid: 10) == nil)
    }
}

// MARK: - Activation

@Suite("SystemAppActivator.activateOwner")
struct SystemAppActivatorActivateTests {

    @Test("activating the owner reports the localized name")
    func activatedCarriesName() {
        let tree = FakeTree(parents: [37255: 900], apps: [900: "Claude"])
        let spy = Spy()
        let outcome = activator(tree, activate: spy.activate).activateOwner(ofPid: 37255)
        #expect(outcome == .activated("Claude"))
        #expect(spy.calls.map(\.pid) == [900])
    }

    @Test("no owner means nothing is activated at all")
    func noOwnerActivatesNothing() {
        let tree = FakeTree(parents: [:], apps: [:])
        let spy = Spy()
        #expect(activator(tree, activate: spy.activate).activateOwner(ofPid: 10) == .noOwner)
        #expect(spy.calls.isEmpty)
    }

    @Test("a helper is never handed to activate, even as a last resort")
    func helperIsNeverActivated() {
        // The Finder alert came from asking LaunchServices to open a helper
        // bundle. Nothing below `owner` gets the chance to try.
        let tree = FakeTree(parents: [10: 20], apps: [20: "Helper (Plugin)"], helpers: [20])
        let spy = Spy()
        #expect(activator(tree, activate: spy.activate).activateOwner(ofPid: 10) == .noOwner)
        #expect(spy.calls.isEmpty)
    }

    @Test("an activation that does not take is .failed, not a false success")
    func refusedActivation() {
        let tree = FakeTree(parents: [:], apps: [900: "Claude"])
        let spy = Spy(succeed: false)
        guard case let .failed(message) = activator(tree, activate: spy.activate).activateOwner(ofPid: 900)
        else {
            Issue.record("expected .failed")
            return
        }
        #expect(message.contains("Claude"))
    }
}

// MARK: - systemParentPid

@Suite("systemParentPid")
struct SystemParentPidTests {

    @Test("our own parent is a real, live pid")
    func ownParent() throws {
        let me = ProcessInfo.processInfo.processIdentifier
        let parent = try #require(systemParentPid(me))
        #expect(parent > 0)
        #expect(parent != me)
        #expect(systemPidLiveness(parent))
    }

    @Test("pid 1 and below have no parent to report")
    func topOfTree() {
        #expect(systemParentPid(1) == nil)
        #expect(systemParentPid(0) == nil)
        #expect(systemParentPid(-5) == nil)
    }

    @Test("a pid that does not exist reports no parent rather than garbage")
    func deadPid() {
        // pid_max is 99999 on Darwin, so this can never be a live process.
        #expect(systemParentPid(999_999) == nil)
    }

    @Test("walking up from ourselves with the real seams terminates")
    func realWalkTerminates() {
        // Nothing resolves, so this exercises systemParentPid for every hop and
        // must still come back — the bound is what stops it.
        let activator = SystemAppActivator(resolve: { _ in nil }, activate: { _ in true })
        #expect(activator.owner(ofPid: ProcessInfo.processInfo.processIdentifier) == nil)
    }
}

// MARK: - Click routing

@Suite("focusRoute")
struct FocusRouteTests {
    private let alive: PidLiveness = { _ in true }
    private let dead: PidLiveness = { _ in false }

    @Test("a usable tty routes to Terminal")
    func ttyWins() {
        #expect(focusRoute(tty: "ttys003", pid: nil, isPidAlive: dead) == .terminal(tty: "ttys003"))
    }

    @Test("the tty is normalized before it is handed on")
    func normalizesTty() {
        #expect(focusRoute(tty: " /dev/ttys003 ", pid: nil, isPidAlive: dead) == .terminal(tty: "ttys003"))
    }

    @Test("a tty beats an activatable pid — only a tty restores the exact tab")
    func ttyBeatsPid() {
        #expect(focusRoute(tty: "ttys003", pid: 900, isPidAlive: alive) == .terminal(tty: "ttys003"))
    }

    @Test("tty sentinels mean no tty, not a tty named '??'", arguments: [
        nil, "", "  ", "??", "?", "-", "/dev/", "/dev/??",
    ] as [String?])
    func sentinelsFallThrough(_ tty: String?) {
        // This is the Claude.app case: `ps -o tty=` prints `??` for the embedded
        // agent, and the hook substitutes `?`.
        #expect(focusRoute(tty: tty, pid: 37255, isPidAlive: alive) == .activateApp(pid: 37255))
    }

    @Test("no tty and a live pid routes to app activation")
    func ttylessLivePid() {
        #expect(focusRoute(tty: nil, pid: 37255, isPidAlive: alive) == .activateApp(pid: 37255))
    }

    @Test("no tty and a dead pid is unavailable — never raise a recycled pid")
    func ttylessDeadPid() {
        guard case let .unavailable(reason) = focusRoute(tty: nil, pid: 37255, isPidAlive: dead) else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(reason.contains("37255"))
    }

    @Test("no tty and no pid is unavailable")
    func nothingToAimAt() {
        guard case .unavailable = focusRoute(tty: nil, pid: nil, isPidAlive: alive) else {
            Issue.record("expected .unavailable")
            return
        }
    }

    @Test("a non-positive pid is not a pid")
    func nonPositivePid() {
        guard case .unavailable = focusRoute(tty: "??", pid: 0, isPidAlive: alive) else {
            Issue.record("expected .unavailable")
            return
        }
    }

    @Test("liveness is not consulted when a tty is present")
    func noLivenessProbeOnTtyPath() {
        // The probe is a syscall on every click; the tty path must not pay for it.
        let probes = Probe()
        _ = focusRoute(tty: "ttys003", pid: 900, isPidAlive: probes.check)
        #expect(probes.count == 0)
    }

    @Test("the Session overload reads tty and pid off the session")
    func sessionOverload() {
        let now = Date()
        let terminal = Session(id: "a", source: .claudeCode, tty: "ttys001", pid: 100,
                               updatedAt: now, createdAt: now)
        let desktop = Session(id: "b", source: .claudeCode, tty: nil, pid: 37255,
                              updatedAt: now, createdAt: now)
        #expect(focusRoute(for: terminal, isPidAlive: alive) == .terminal(tty: "ttys001"))
        #expect(focusRoute(for: desktop, isPidAlive: alive) == .activateApp(pid: 37255))
    }
}

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    var check: PidLiveness {
        { [self] _ in
            lock.lock(); calls += 1; lock.unlock()
            return true
        }
    }
}

@Suite("focusRoute: the owner decides whether the tty is usable")
struct FocusRouteOwnerTests {
    private let alive: PidLiveness = { _ in true }
    private let dead: PidLiveness = { _ in false }

    private func owner(_ bundleID: String?) -> (Int32) -> String? {
        { _ in bundleID }
    }

    @Test("Terminal.app owns the tty, so the exact tab is restored")
    func terminalOwnedTty() {
        #expect(focusRoute(tty: "ttys003", pid: 900, isPidAlive: alive,
                           ownerBundleID: owner(terminalBundleIdentifier))
                == .terminal(tty: "ttys003"))
    }

    @Test("an IDE's integrated terminal raises the IDE instead", arguments: [
        "dev.zed.Zed",
        "com.microsoft.VSCode",
        "com.todesktop.230313mzl4w4u92",   // Cursor
        "com.googlecode.iterm2",
    ])
    func ideOwnedTty(_ bundleID: String) {
        // The bug this exists for: these ttys are REAL. The scan finds them, the
        // hook fires, the row shows live state — and then Terminal.app is asked
        // about a pty it has never heard of, answers notfound, and the row is
        // dead on click. Raising the owning app is the honest answer.
        #expect(focusRoute(tty: "ttys003", pid: 900, isPidAlive: alive,
                           ownerBundleID: owner(bundleID))
                == .activateApp(pid: 900))
    }

    @Test("an UNKNOWN owner keeps the tty — nil is not evidence of anything")
    func unknownOwnerKeepsTty() {
        // tmux, ssh, or a process whose GUI ancestor is beyond maxHops. The
        // outer tab may well still be Terminal's, and downgrading a session that
        // would have focused correctly is strictly worse than trying.
        #expect(focusRoute(tty: "ttys003", pid: 900, isPidAlive: alive, ownerBundleID: owner(nil))
                == .terminal(tty: "ttys003"))
    }

    @Test("no pid means no owner question can be asked, so the tty stands")
    func noPidKeepsTty() {
        #expect(focusRoute(tty: "ttys003", pid: nil, isPidAlive: dead,
                           ownerBundleID: owner("dev.zed.Zed"))
                == .terminal(tty: "ttys003"))
    }

    @Test("an IDE-owned tty whose process died is unavailable, never a raise")
    func deadIdeProcess() {
        // Same reasoning as the tty-less path: the kernel recycles pids, and
        // raising "whatever owns 900" now could bring forward anything at all.
        guard case let .unavailable(reason) = focusRoute(
            tty: "ttys003", pid: 900, isPidAlive: dead, ownerBundleID: owner("dev.zed.Zed"))
        else {
            Issue.record("expected .unavailable")
            return
        }
        #expect(reason.contains("900"))
    }

    @Test("the owner is not consulted at all when there is no tty")
    func noOwnerProbeWithoutTty() {
        // The tty-less path already routes to activation; asking who owns the
        // pid twice would be a wasted ppid walk on every click.
        let probes = OwnerProbe()
        _ = focusRoute(tty: nil, pid: 37255, isPidAlive: alive, ownerBundleID: probes.lookup)
        #expect(probes.count == 0)
    }

    @Test("the default keeps the old behaviour exactly")
    func defaultIsUnchanged() {
        // Every existing call site passes no owner, and must be unaffected.
        #expect(focusRoute(tty: "ttys003", pid: 900, isPidAlive: alive) == .terminal(tty: "ttys003"))
    }

    @Test("the Session overload threads the owner through")
    func sessionOverload() {
        let now = Date()
        let inIDE = Session(id: "a", source: .claudeCode, tty: "ttys009", pid: 900,
                            updatedAt: now, createdAt: now)
        #expect(focusRoute(for: inIDE, isPidAlive: alive, ownerBundleID: owner("dev.zed.Zed"))
                == .activateApp(pid: 900))
        #expect(focusRoute(for: inIDE, isPidAlive: alive,
                           ownerBundleID: owner(terminalBundleIdentifier))
                == .terminal(tty: "ttys009"))
    }
}

private final class OwnerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    var lookup: (Int32) -> String? {
        { [self] _ in
            lock.lock(); calls += 1; lock.unlock()
            return "dev.zed.Zed"
        }
    }
}
