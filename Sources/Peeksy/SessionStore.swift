import PeeksyCore
import Dispatch
import Foundation
import Observation
import os

let uiLog = Logger(subsystem: "com.peeksy.app", category: "ui")

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
/// It replaced a substring scan for `peeksy-hook.sh`, which said yes to a
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

    /// Called at the end of every reap tick. The notch uses it to re-measure the
    /// menu bar without owning a timer; nothing else may assume an interval.
    @ObservationIgnored var onHousekeeping: (() -> Void)?

    /// Snapshot of `registry.ordered()`. Recomputed at most every
    /// `coalesceInterval`, never per event.
    private(set) var rows: [Session] = []
    private(set) var aggregate = Aggregate(count: 0, top: nil, attentionCount: 0, hasUnknown: false)

    /// Latched when a focus click is denied by Automation. Drives the footer.
    var tccBlocked = false

    /// Drives the "Hook not installed" line. Re-probed on the reap tick so
    /// installing the hook while the app runs clears the message.
    private(set) var hookInstalled = HookProbe.isInstalled()

    /// pid → owning application. Cached because the answer cannot change for a
    /// live pid and the lookup walks the process tree. Resolved for every
    /// session with a pid, not only tty-less ones: a real tty owned by Zed, VS
    /// Code or Cursor is the row-labelling signal that says "this is running
    /// inside an IDE", not just the tty-less fallback for Claude.app's embedded
    /// agent.
    @ObservationIgnored private var ownerCache: [Int32: OwningApp] = [:]
    /// Bumped whenever `ownerCache` gains an entry, so SwiftUI re-reads the
    /// labels that depend on it. (`ownerCache` itself is observation-ignored: a
    /// dictionary read per row per second would register a dependency on every
    /// pid in it.)
    private(set) var ownerNameGeneration = 0

    /// session id → transcript path, learned from the hook envelope. Recorded
    /// non-nil-only, the same discipline `SessionRegistry.apply` uses for tty and
    /// cwd: a later event must not be able to null out a path we already have.
    @ObservationIgnored private var transcriptPaths: [String: String] = [:]
    /// session id → Claude Code's own name for the task, read out of the
    /// transcript. Absent until the agent has written one (~13 messages in).
    @ObservationIgnored private var taskTitles: [String: String] = [:]
    /// session id → when we last looked. The whole refresh policy lives in the
    /// comparison against `Session.updatedAt`, which is what stops a finished
    /// session being re-read every 15 s until it is reaped.
    @ObservationIgnored private var titleReadAt: [String: Date] = [:]
    /// Bumped whenever a title actually changes, for the same reason
    /// `ownerNameGeneration` exists — the dictionary itself is
    /// observation-ignored so a per-row read does not register a dependency on
    /// every session in it.
    private(set) var taskTitleGeneration = 0

    @ObservationIgnored let sessionCounts = SessionCountMirror()

    @ObservationIgnored private var registry: SessionRegistry
    @ObservationIgnored private let focuser: TerminalFocuser
    @ObservationIgnored private let activator: any AppActivating
    @ObservationIgnored private let ownerLookup: @Sendable (Int32) -> OwningApp?
    @ObservationIgnored private let titleReader: TranscriptTitleReader
    /// The `ps` sweep behind `refreshAgentPids`. A seam, for the same reason
    /// `ownerLookup` is one: it forks a process, and no test may.
    @ObservationIgnored private let pidScanner: @Sendable () -> Set<Int32>?

    /// Focus work runs here. `TerminalFocuser` spawns `osascript` and
    /// `activate` talks to the window server; neither may ever run on the main
    /// thread with a 5 s watchdog behind it.
    @ObservationIgnored private let focusQueue = DispatchQueue(
        label: "com.peeksy.focus", qos: .userInitiated)

    /// The reap tick's off-main work runs here — NOT on `focusQueue`.
    ///
    /// `focusQueue` is serial and it is the click path. Queueing a batch of file
    /// reads onto it would put disk latency in front of the app's primary
    /// interaction. This is a third dispatch queue, not a second ingest edge:
    /// the "one cross-actor edge" invariant is about the socket hop that admits
    /// events to the model, and this queue admits nothing.
    ///
    /// Two jobs ride it, both driven by the same 15 s tick and both bounded: the
    /// transcript reads that resolve task titles, and the `ps` sweep that tells
    /// the reaper which pids are agents. A fourth queue to separate them would
    /// buy nothing — the sweep tolerates a full `scanFreshness` of latency and
    /// the reads are a tail per session — and a 24/7 accessory app should not
    /// hold threads it cannot justify.
    @ObservationIgnored private let titleQueue = DispatchQueue(
        label: "com.peeksy.title", qos: .utility)

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
    /// How stale a title we ALREADY have is allowed to get. Only reached by a
    /// session that keeps working; see `refreshTitles`.
    @ObservationIgnored private let titleRefreshInterval: TimeInterval = 120

    init(
        registry: SessionRegistry = SessionRegistry(),
        focuser: TerminalFocuser,
        activator: any AppActivating,
        ownerLookup: @escaping @Sendable (Int32) -> OwningApp?,
        titleReader: TranscriptTitleReader = .system,
        pidScanner: @escaping @Sendable () -> Set<Int32>? = { ProcessScanner().liveAgentPids() }
    ) {
        self.registry = registry
        self.focuser = focuser
        self.activator = activator
        self.ownerLookup = ownerLookup
        self.titleReader = titleReader
        self.pidScanner = pidScanner
        publish()
    }

    // MARK: - Ingest

    /// Fold one hook event in. Called from the io queue via a MainActor hop.
    func ingest(_ envelope: HookEnvelope) {
        switch registry.apply(envelope, now: envelope.receivedAt) {
        case .updated:
            // The envelope carries the transcript path but never the title
            // itself; reading it is deferred to the reaper. A per-event read is
            // not an option — one captured session produced 281 events.
            if let path = envelope.transcriptPath, !path.isEmpty {
                transcriptPaths[envelope.sessionID] = path
            }
        case let .removed(id):
            forgetTitle(id)
            pruneOwnerCache()
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
        // Kicked off first, consumed NEXT tick. The reap below judges sessions
        // against the sweep taken 15 s ago, never one taken after the state it
        // is judging — and a sweep that has not landed yet is simply absent,
        // which `liveness` reads as "no information".
        refreshAgentPids()

        let result = registry.reap(now: Date())
        if !result.isEmpty {
            uiLog.info("""
                reap: removed \(result.removed.count, privacy: .public) \
                staled \(result.staled.count, privacy: .public) \
                permissions expired \(result.permissionsExpired.count, privacy: .public)
                """)
        }
        if !result.removed.isEmpty {
            for id in result.removed { forgetTitle(id) }
            pruneOwnerCache()
        }
        hookInstalled = HookProbe.isInstalled()
        refreshTitles()
        publish()
        // The notch hangs its menu-bar re-measurement off this tick rather than
        // starting a timer of its own. This one already fires forever; a second
        // repeating source in a 24/7 accessory app is a cost with no upside, and
        // a 0.31 ms window-list scan every 15 s is free next to a reap.
        onHousekeeping?()
    }

    // MARK: - Agent pids

    /// Re-sweep which live pids are agent processes.
    ///
    /// The reaper needs this because a live pid is not the same claim as a live
    /// session: for an IDE agent panel the pid on the wire is the extension
    /// host, which outlives every chat inside it. See
    /// `SessionRegistry.liveness(of:now:)`.
    ///
    /// A failed sweep leaves the previous one in place rather than publishing an
    /// empty set — `scanFreshness` then ages it out on its own. Writing `[]`
    /// here would tell the reaper that nothing on the machine is an agent, and
    /// every row would fall to `orphanTTL` at once.
    private func refreshAgentPids() {
        let scanner = pidScanner
        titleQueue.async { [weak self] in
            guard let pids = scanner() else { return }
            let scan = AgentPidScan(pids: pids, at: Date())
            Task { @MainActor in self?.registry.agentPidScan = scan }
        }
    }

    // MARK: - Task titles

    /// Claude Code's own one-line name for what a session is doing.
    func taskTitle(forSessionID id: String) -> String? { taskTitles[id] }

    /// Re-read the transcripts that could have something new to say.
    ///
    /// Deliberately driven by the existing 15 s reaper rather than a timer of its
    /// own: this app has no `TimelineView` and no periodic run-loop source by
    /// policy, and a title is stable for minutes — 15 s of latency on it is
    /// invisible.
    ///
    /// Two gates, and a session must clear both:
    ///
    /// 1. **It did something since we last looked** (`updatedAt > readAt`).
    ///    Nothing can have been appended to the transcript of a session that has
    ///    not moved, so a finished row is read once more and then left alone
    ///    rather than re-read every tick until it is reaped.
    /// 2. **We do not already have a title, or the backoff has elapsed.** A
    ///    session mid-turn moves on every single tick, so gate 1 alone would
    ///    re-read 256 KB every 15 s per session for as long as the app is up —
    ///    and this app runs all day. A title we already have changes rarely
    ///    (measured: once, mid-session, in 93 of 1 881 transcripts), so once it
    ///    is known the read drops to `titleRefreshInterval`. While it is UNKNOWN
    ///    there is no backoff: that is the ~13-messages-in window where the row
    ///    is still showing its project label and we want the title as it lands.
    private func refreshTitles() {
        let now = Date()
        var due: [(id: String, path: String)] = []
        for session in registry.ordered() {
            guard let path = transcriptPaths[session.id] else { continue }
            if let readAt = titleReadAt[session.id] {
                guard session.updatedAt > readAt else { continue }
                if taskTitles[session.id] != nil,
                   now.timeIntervalSince(readAt) < titleRefreshInterval { continue }
            }
            // Stamped BEFORE the read, not after, so a transcript that has no
            // title yet is not retried until the session does something else.
            titleReadAt[session.id] = now
            due.append((session.id, path))
        }
        guard !due.isEmpty else { return }

        // Off the main actor. The read is sub-millisecond warm, but a stalled
        // network home directory would beachball the panel, and file I/O on the
        // main thread is not a thing this app does.
        let reader = titleReader
        let batch = due
        titleQueue.async { [weak self] in
            let resolved = batch.compactMap { item -> (String, String)? in
                guard let title = reader.title(atPath: item.path) else { return nil }
                return (item.id, title)
            }
            guard !resolved.isEmpty else { return }
            Task { @MainActor in self?.applyTitles(resolved) }
        }
    }

    private func applyTitles(_ resolved: [(String, String)]) {
        var changed = false
        for (id, title) in resolved where taskTitles[id] != title {
            // Logged because the title comes from a file this app does not own,
            // in an undocumented format, and "the row still says the project" is
            // otherwise indistinguishable from "the transcript has no title yet".
            uiLog.info("title for \(id, privacy: .public): \(title, privacy: .public)")
            taskTitles[id] = title
            changed = true
        }
        // Only on a real change: `Observation` does not diff, and bumping this
        // would invalidate every row's body for nothing. The bump is the whole
        // notification — `rows` is untouched, so `publish()` would be a no-op.
        guard changed else { return }
        taskTitleGeneration += 1
    }

    private func forgetTitle(_ id: String) {
        transcriptPaths[id] = nil
        taskTitles[id] = nil
        titleReadAt[id] = nil
    }

    // MARK: - Dismiss

    /// Forget a row on the user's say-so.
    ///
    /// The escape hatch for the case the reaper cannot decide: an IDE-hosted
    /// session whose pid belongs to a host that is still very much alive has no
    /// liveness signal at all, and `orphanTTL` is a guess about how long to
    /// wait. The user knows. This costs no panel height — it hangs off a context
    /// menu, not a control — which is the only reason it can exist at all
    /// without a pinned constant.
    ///
    /// Unlike `focus`, the panel deliberately stays open: clearing several dead
    /// rows in a row is the whole use case.
    func dismiss(_ session: Session) {
        guard registry.remove(id: session.id) else { return }
        uiLog.info("dismissed \(session.id, privacy: .public)")
        forgetTitle(session.id)
        pruneOwnerCache()
        publish()
    }

    /// Drop cached app names for pids no session refers to any more.
    ///
    /// `ownerCache` is keyed by pid and pids are recycled. Without this, a pid
    /// that resolved to Cursor an hour ago hands that label to whatever
    /// unrelated process inherits the number — and the cache is never otherwise
    /// invalidated, because for a LIVE pid the answer genuinely cannot change.
    ///
    /// No `ownerNameGeneration` bump: the rows that depended on these entries
    /// are the ones that just went away.
    private func pruneOwnerCache() {
        guard !ownerCache.isEmpty else { return }
        let live = Set(registry.sessions.values.compactMap(\.pid))
        ownerCache = ownerCache.filter { live.contains($0.key) }
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

    /// The owning application's name, but only when it is worth telling the user
    /// about: never Terminal.app (the ordinary case, which needs no label) and
    /// never "no answer yet". For a tty-less session (Claude.app's embedded
    /// agent) this is the whole row label; for a real tty owned by something
    /// else — Zed, VS Code, Cursor — `SliceRow` appends it, which is what makes
    /// an IDE-hosted session visibly different from a plain Terminal one.
    func ownerName(forPid pid: Int32) -> String? {
        guard let owner = ownerCache[pid], owner.bundleID != terminalBundleIdentifier else {
            return nil
        }
        return owner.localizedName
    }

    // MARK: - Snapshot

    private func publish() {
        let ordered = registry.ordered()
        let snapshot = registry.aggregate()

        sessionCounts.set(snapshot.count)
        resolveOwners(in: ordered)

        // Assign only on change. `Observation` does not diff, so writing an
        // equal array would invalidate every row's body for nothing.
        if ordered != rows { rows = ordered }
        if snapshot != aggregate { aggregate = snapshot }
    }

    /// Resolve the owning application for every session with a pid, once per
    /// pid.
    ///
    /// Cheap enough for the main actor: it is a `NSRunningApplication` lookup
    /// plus at most five `sysctl` calls, and only the first time a given pid is
    /// seen — every session (Terminal-backed included) needs the answer now,
    /// not only tty-less ones, so a Zed/VS Code/Cursor row can be labelled too.
    private func resolveOwners(in sessions: [Session]) {
        var gained = false
        for session in sessions {
            guard let pid = session.pid,
                  ownerCache[pid] == nil,
                  let owner = ownerLookup(pid)
            else { continue }
            ownerCache[pid] = owner
            gained = true
        }
        if gained { ownerNameGeneration += 1 }
    }
}
