import AgentNotchCore
import Dispatch
import Foundation
import Observation
import os

let uiLog = Logger(subsystem: "com.agentnotch.app", category: "ui")

// MARK: - Health mirror

/// A lock-guarded copy of `registry.sessions.count`.
///
/// `/v1/health` is answered on the socket's io queue and MUST NOT hop to the
/// main actor: a health probe that blocks behind a busy main thread turns a
/// diagnostic into a hang, and `doctor.sh` would report the app dead while it is
/// merely laying out a list. One `Int` behind a lock is the whole cost of
/// keeping that path synchronous.
final class SessionCountMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ count: Int) {
        lock.lock(); value = count; lock.unlock()
    }
}

// MARK: - Hook install probe

/// "Is our hook wired into Claude Code?"
///
/// Answered by the SAME merge the installer uses: if a fresh install would be a
/// no-op, we are installed. READ-ONLY — this runs on the reap tick and must
/// never write.
///
/// It replaced a substring scan for `agent-notch-hook.sh`, which said yes to a
/// half-finished install. Five events of nine, or a `Notification` group that
/// picked up a matcher, both leave a file that mentions us and a UI that never
/// moves — and "installed" is exactly the wrong thing to tell somebody in that
/// state.
enum HookProbe {
    static func isInstalled(
        settingsURL: URL = SupportPaths.claudeSettings(),
        command: String = HookSpec.shellQuoted(SupportPaths.hookScript().path)
    ) -> Bool {
        HookInstaller(settingsURL: settingsURL, command: command).isInstalled()
    }
}

// MARK: - Store

/// The app's single source of truth: a `@MainActor` shell around the pure
/// `SessionRegistry` struct.
///
/// The registry stays a struct — see its own doc comment — and this class is the
/// one thing that owns mutation. That replaces M0's `RegistryBox` lock: the main
/// actor is now the serialisation point, and the ONE cross-actor edge in the
/// whole app is the `Task { @MainActor in store.ingest(…) }` hop out of the
/// socket's io queue.
@MainActor
@Observable
final class SessionStore {

    /// Snapshot of `registry.ordered()`. Recomputed at most every
    /// `coalesceInterval`, never per event.
    private(set) var rows: [Session] = []
    private(set) var aggregate = Aggregate(count: 0, top: nil, attentionCount: 0, hasUnknown: false)

    /// Latched when a focus click is denied by Automation. Drives the footer.
    var tccBlocked = false

    /// Drives the "Hook not installed" line. Re-probed on the reap tick so
    /// installing the hook while the app runs clears the message.
    private(set) var hookInstalled = HookProbe.isInstalled()

    /// pid → owning application name, for tty-less rows. Cached because the
    /// answer cannot change for a live pid and the lookup walks the process tree.
    @ObservationIgnored private var ownerNameCache: [Int32: String] = [:]
    /// Bumped whenever `ownerNameCache` gains an entry, so SwiftUI re-reads the
    /// labels that depend on it. (`ownerNameCache` itself is observation-ignored:
    /// a dictionary read per row per second would register a dependency on every
    /// pid in it.)
    private(set) var ownerNameGeneration = 0

    @ObservationIgnored let sessionCounts = SessionCountMirror()

    @ObservationIgnored private var registry: SessionRegistry
    @ObservationIgnored private let focuser: TerminalFocuser
    @ObservationIgnored private let activator: any AppActivating
    @ObservationIgnored private let ownerLookup: @Sendable (Int32) -> String?

    /// Focus work runs here. `TerminalFocuser` spawns `osascript` and
    /// `activate` talks to the window server; neither may ever run on the main
    /// thread with a 5 s watchdog behind it.
    @ObservationIgnored private let focusQueue = DispatchQueue(
        label: "com.agentnotch.focus", qos: .userInitiated)

    @ObservationIgnored private var reapTimer: Timer?
    @ObservationIgnored private var snapshotScheduled = false

    /// Snapshot floor.
    ///
    /// Load-bearing, not a nicety. A Bash-heavy turn fires PreToolUse+PostToolUse
    /// pairs at tens per second; recomputing `ordered()` and re-laying out the
    /// list on each one burns CPU to render frames nobody can perceive. Events
    /// still fold into the registry immediately — only the PUBLISH is throttled.
    @ObservationIgnored private let coalesceInterval: Duration = .milliseconds(100)
    /// `reap` is idempotent, so this is a knob and not a correctness constant.
    @ObservationIgnored private let reapInterval: TimeInterval = 15

    init(
        registry: SessionRegistry = SessionRegistry(),
        focuser: TerminalFocuser,
        activator: any AppActivating,
        ownerLookup: @escaping @Sendable (Int32) -> String?
    ) {
        self.registry = registry
        self.focuser = focuser
        self.activator = activator
        self.ownerLookup = ownerLookup
        publish()
    }

    // MARK: - Ingest

    /// Fold one hook event in. Called from the io queue via a MainActor hop.
    func ingest(_ envelope: HookEnvelope) {
        switch registry.apply(envelope, now: envelope.receivedAt) {
        case .updated, .removed:
            break
        case let .dropped(reason):
            Log.registry.error("dropped event: \(reason, privacy: .public)")
            return
        }
        scheduleSnapshot()
    }

    /// Trailing-edge coalescing: the first event after a quiet period arms a
    /// single task, and every event inside the window rides on it.
    private func scheduleSnapshot() {
        guard !snapshotScheduled else { return }
        snapshotScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.coalesceInterval)
            self.snapshotScheduled = false
            self.publish()
        }
    }

    // MARK: - Cold start

    /// Fold a launch-time process scan in.
    ///
    /// Called once, from `AppDelegate`, AFTER the socket is listening — so a
    /// hook event that beats the scan wins on the merits: `seed` skips any pid
    /// or tty already tracked, and the rows it does create are `.bootstrap`,
    /// which the list renders as "waiting…" rather than inventing a state.
    func bootstrap(_ found: [DiscoveredProcess]) {
        let created = registry.seed(found, source: .claudeCode, now: Date())
        guard !created.isEmpty else { return }
        uiLog.info("cold start: adopted \(created.count, privacy: .public) running session(s)")
        publish()
    }

    // MARK: - Housekeeping

    /// The app's only model-side timer. Started by `AppDelegate` once the server
    /// is up, so a failed launch never leaves a timer running.
    func startReaping() {
        guard reapTimer == nil else { return }
        let timer = Timer(timeInterval: reapInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reapTick() }
        }
        timer.tolerance = 2
        // .common, not .default: a run loop tracking a window drag would
        // otherwise stop reaping until the user let go.
        RunLoop.main.add(timer, forMode: .common)
        reapTimer = timer
    }

    func stopReaping() {
        reapTimer?.invalidate()
        reapTimer = nil
    }

    func reapTick() {
        let result = registry.reap(now: Date())
        if !result.isEmpty {
            uiLog.info("""
                reap: removed \(result.removed.count, privacy: .public) \
                staled \(result.staled.count, privacy: .public) \
                permissions expired \(result.permissionsExpired.count, privacy: .public)
                """)
        }
        hookInstalled = HookProbe.isInstalled()
        publish()
    }

    // MARK: - Focus

    /// Route a click.
    ///
    /// ORDER MATTERS, and it is the order M3 needs: every piece of local state is
    /// settled synchronously, and only then does anything slow start. Nothing UI
    /// is ever held open across an activation — by the time the window server
    /// hears from us, this actor has already finished its turn.
    func focus(_ session: Session) {
        // Local state first. Clearing the latch here means the footer reflects
        // THIS attempt rather than one from ten minutes ago.
        tccBlocked = false

        // The owner decides whether the tty is worth using. A session in VS
        // Code's, Cursor's or iTerm2's integrated terminal has a real tty that
        // Terminal.app cannot script — raising the IDE is the honest answer
        // there, and it is what makes those rows clickable at all.
        let activator = self.activator
        let route = focusRoute(
            for: session,
            isPidAlive: registry.isPidAlive,
            ownerBundleID: { pid in activator.owner(ofPid: pid)?.bundleID })
        switch route {
        case let .terminal(tty):
            let focuser = self.focuser
            focusQueue.async { [weak self] in
                let outcome = focuser.focus(tty: tty)
                Task { @MainActor in self?.record(outcome, tty: tty) }
            }

        case let .activateApp(pid):
            // Claude.app's embedded Claude Code lands here: real session, real
            // hook events, no terminal tab behind it. Raising the owning app is
            // the honest best answer, and beats a permanently dead row.
            let activator = self.activator
            focusQueue.async { [weak self] in
                let outcome = activator.activateOwner(ofPid: pid)
                Task { @MainActor in self?.record(outcome, pid: pid) }
            }

        case let .unavailable(reason):
            uiLog.info("focus ignored for \(session.id, privacy: .public): \(reason, privacy: .public)")
        }
    }

    private func record(_ outcome: FocusOutcome, tty: String) {
        switch outcome {
        case .focused:
            break
        case .blockedByTCC:
            tccBlocked = true
            uiLog.error("focus blocked by TCC")
        default:
            uiLog.info("focus \(tty, privacy: .public): \(String(describing: outcome), privacy: .public)")
        }
    }

    private func record(_ outcome: ActivationOutcome, pid: Int32) {
        switch outcome {
        case .activated:
            break
        case .noOwner:
            uiLog.info("no owning application for pid \(pid, privacy: .public)")
        case let .failed(message):
            uiLog.error("activation failed for pid \(pid, privacy: .public): \(message, privacy: .public)")
        }
    }

    // MARK: - Labels

    /// Owning application name for a tty-less session, e.g. "Claude".
    func ownerName(forPid pid: Int32) -> String? {
        ownerNameCache[pid]
    }

    // MARK: - Snapshot

    private func publish() {
        let ordered = registry.ordered()
        let snapshot = registry.aggregate()

        sessionCounts.set(snapshot.count)
        resolveOwnerNames(in: ordered)

        // Assign only on change. `Observation` does not diff, so writing an
        // equal array would invalidate every row's body for nothing.
        if ordered != rows { rows = ordered }
        if snapshot != aggregate { aggregate = snapshot }
    }

    /// Resolve app names for tty-less rows, once per pid.
    ///
    /// Cheap enough for the main actor: it is a `NSRunningApplication` lookup
    /// plus at most five `sysctl` calls, only for rows that have no tty, and only
    /// the first time a given pid is seen.
    private func resolveOwnerNames(in sessions: [Session]) {
        var gained = false
        for session in sessions {
            guard normalizeTty(session.tty) == nil,
                  let pid = session.pid,
                  ownerNameCache[pid] == nil,
                  let name = ownerLookup(pid)
            else { continue }
            ownerNameCache[pid] = name
            gained = true
        }
        if gained { ownerNameGeneration += 1 }
    }
}
