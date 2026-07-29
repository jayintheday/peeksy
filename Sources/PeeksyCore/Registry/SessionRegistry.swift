import Foundation

/// What `apply` did.
public enum ApplyResult: Sendable, Equatable {
    case updated(String)
    case removed(String)
    case dropped(reason: String)
}

/// What one `reap` pass did. Empty when nothing changed, which is the common case.
public struct ReapResult: Sendable, Equatable {
    public let removed: [String]
    public let staled: [String]
    public let permissionsExpired: [String]
    /// Rows that stopped claiming to need you. See `ReapPolicy.attentionTTL`.
    public let attentionExpired: [String]

    public init(
        removed: [String] = [],
        staled: [String] = [],
        permissionsExpired: [String] = [],
        attentionExpired: [String] = []
    ) {
        self.removed = removed
        self.staled = staled
        self.permissionsExpired = permissionsExpired
        self.attentionExpired = attentionExpired
    }

    public var isEmpty: Bool {
        removed.isEmpty && staled.isEmpty && permissionsExpired.isEmpty
            && attentionExpired.isEmpty
    }
}

/// The whole list boiled down to what a status indicator needs.
public struct Aggregate: Sendable, Equatable {
    public let count: Int
    /// Highest-priority state present, `nil` when there are no sessions.
    public let top: SessionState?
    public let attentionCount: Int
    /// Any session whose `origin == .bootstrap` — i.e. at least one row is a
    /// launch-time guess rather than hook-truth.
    public let hasUnknown: Bool

    public init(count: Int, top: SessionState?, attentionCount: Int, hasUnknown: Bool) {
        self.count = count
        self.top = top
        self.attentionCount = attentionCount
        self.hasUnknown = hasUnknown
    }
}

/// Every tracked session, and the rules for moving them between states.
///
/// A STRUCT — not a class, not an actor. This is the single most important
/// design call in the core:
///
///  * a struct is trivially `Sendable`, so it crosses queues without ceremony;
///  * it needs no isolation, so there is no `await` anywhere in the read path
///    that a UI will hammer at 60 Hz;
///  * and every test is a synchronous three-liner with no clock, no disk and no
///    expectation plumbing.
///
/// The cost is that the owner must serialise mutation. That is one lock in one
/// place (see `Sources/Peeksy/main.swift`), which is a much smaller problem
/// than actor-isolating the model.
///
/// There is deliberately no timer in here. `reap(now:)` is idempotent and the
/// caller drives it.
public struct SessionRegistry: Sendable {
    public private(set) var sessions: [String: Session]
    public var policy: ReapPolicy
    public var isPidAlive: PidLiveness
    /// Which live pids are actually agent processes. Refreshed off the main
    /// actor from the reap tick; `nil` until the first sweep lands, and treated
    /// as absent once older than `policy.scanFreshness`.
    public var agentPidScan: AgentPidScan?

    public init(
        policy: ReapPolicy = .default,
        isPidAlive: @escaping PidLiveness = systemPidLiveness,
        agentPidScan: AgentPidScan? = nil
    ) {
        self.sessions = [:]
        self.policy = policy
        self.isPidAlive = isPidAlive
        self.agentPidScan = agentPidScan
    }

    // MARK: - Reads (pure)

    public subscript(id: String) -> Session? { sessions[id] }

    /// Display order: needsAttention → stale → working → done → idle. Within a
    /// tier, hook-truth before bootstrap guesses, then most-recent `updatedAt`
    /// first, then id for a total order (so the list never shuffles under a
    /// stable input).
    public func ordered() -> [Session] {
        sessions.values.sorted { a, b in
            let pa = statePriority(a.state)
            let pb = statePriority(b.state)
            if pa != pb { return pa > pb }
            if a.origin != b.origin { return a.origin == .hook }
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            return a.id < b.id
        }
    }

    public func aggregate() -> Aggregate {
        var top: SessionState?
        var attention = 0
        var hasUnknown = false
        for s in sessions.values {
            if let current = top {
                if statePriority(s.state) > statePriority(current) { top = s.state }
            } else {
                top = s.state
            }
            if s.state == .needsAttention { attention += 1 }
            if s.origin == .bootstrap { hasUnknown = true }
        }
        return Aggregate(
            count: sessions.count,
            top: top,
            attentionCount: attention,
            hasUnknown: hasUnknown
        )
    }

    // MARK: - Writes

    /// Fold one hook event in.
    ///
    /// Unknown session ids auto-register, so an app started mid-flight still
    /// tracks a session that began before it launched. Before creating a new
    /// row it tries `adopt`, so a bootstrap placeholder for the same process is
    /// upgraded rather than duplicated.
    @discardableResult
    public mutating func apply(_ e: HookEnvelope, now: Date) -> ApplyResult {
        let id = e.sessionID
        guard !id.isEmpty else { return .dropped(reason: "empty session id") }

        if sessions[id] == nil {
            // May be the first real event from a process we seeded at launch.
            _ = adopt(realID: id, pid: e.pid, tty: e.tty, now: now)
        }

        var s = sessions[id] ?? Session(
            id: id,
            source: e.source,
            state: .idle,
            origin: .hook,
            updatedAt: now,
            createdAt: now
        )

        // A hook event is hook-truth. Whatever this row used to be, it is real now.
        s.origin = .hook
        s.updatedAt = now

        // Metadata is NON-NIL-ONLY. Hook payloads are ragged: `cwd` shows up on
        // some events and not others, and `_meta.tty` is missing whenever `ps`
        // fails. Assigning the optional straight through would let a late event
        // null out a tty we already learned — and the tty is what "focus this
        // session's terminal" is built on.
        if let cwd = e.cwd { s.cwd = cwd }
        if let tty = e.tty { s.tty = tty }
        if let pid = e.pid { s.pid = pid }
        if let toolSummary = e.toolSummary { s.lastToolSummary = toolSummary }

        switch e.hookEventName {
        case "SessionStart":
            s.state = .idle
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure":
            s.state = .working
            // BACKSTOP: a permission dialog answered on the KEYBOARD fires the next
            // progress event but never tells us the pending resolved. Any progress
            // means the turn moved on, so drop it here. Deliberately NOT on
            // Notification — that is what RAISED the attention.
            s.pendingPermission = nil
        case "Notification":
            if HookEnvelope.attentionNotifications.contains(e.notificationType ?? "") {
                s.state = .needsAttention
            }
        case "PermissionRequest":
            s.state = .needsAttention
            s.pendingPermission = PendingPermission(
                requestID: e.permissionRequestID ?? "\(id)#\(now.timeIntervalSince1970)",
                toolName: e.toolName ?? "",
                summary: e.toolSummary ?? e.toolName ?? "Permission requested",
                detail: e.toolDetail ?? e.toolSummary ?? e.toolName ?? "Permission requested",
                receivedAt: now
            )
        case "Stop":
            s.state = .done
            s.pendingPermission = nil
        case "SessionEnd":
            sessions.removeValue(forKey: id)
            return .removed(id)
        default:
            break // unknown event: activity noted via updatedAt, no state change
        }

        sessions[id] = s
        return .updated(id)
    }

    /// Forget a session outright. Returns false if there was nothing to forget.
    ///
    /// The user's escape hatch, for the row the heuristics get wrong. Safe to
    /// offer because it is not destructive: this app owns no session state that
    /// the session itself will not re-assert. A live agent's next hook event
    /// re-registers it through `apply` with its real state intact.
    @discardableResult
    public mutating func remove(id: String) -> Bool {
        sessions.removeValue(forKey: id) != nil
    }

    /// Seed from a launch-time process scan.
    ///
    /// Skips pids/ttys already tracked, so running it after hooks have started
    /// arriving is a no-op rather than a duplicate. Returns the ids created.
    @discardableResult
    public mutating func seed(_ found: [DiscoveredProcess], source: AgentSource, now: Date) -> [String] {
        var created: [String] = []
        for process in found {
            if sessions.values.contains(where: { $0.pid == process.pid }) { continue }
            if let tty = bareTTY(process.tty),
               sessions.values.contains(where: { bareTTY($0.tty) == tty }) { continue }

            let id = "boot:\(process.pid)"
            guard sessions[id] == nil else { continue }

            sessions[id] = Session(
                id: id,
                source: source,
                cwd: process.cwd,
                tty: bareTTY(process.tty),
                pid: process.pid,
                // .idle, not .working: a guess must never manufacture urgency.
                state: .idle,
                origin: .bootstrap,
                updatedAt: now,
                createdAt: now
            )
            created.append(id)
        }
        return created
    }

    /// Fold a bootstrap placeholder into a real hook session.
    ///
    /// Match order: exact pid, then exact normalised tty. `createdAt` and `cwd`
    /// carry forward so "started 40 minutes ago" survives the upgrade — that is
    /// the whole point of bootstrapping.
    ///
    /// Returns the placeholder id that was consumed, or `nil` when there was
    /// nothing to adopt.
    @discardableResult
    public mutating func adopt(realID: String, pid: Int32?, tty: String?, now: Date) -> String? {
        guard !realID.isEmpty, sessions[realID] == nil else { return nil }

        let wantedTTY = bareTTY(tty)
        var placeholder: Session?

        if let pid {
            placeholder = candidates.first { $0.pid == pid }
        }
        if placeholder == nil, let wantedTTY {
            placeholder = candidates.first { bareTTY($0.tty) == wantedTTY }
        }
        guard let found = placeholder else { return nil }

        sessions.removeValue(forKey: found.id)
        sessions[realID] = Session(
            id: realID,
            source: found.source,
            cwd: found.cwd,
            tty: wantedTTY ?? found.tty,
            pid: pid ?? found.pid,
            state: found.state,
            origin: .hook,
            updatedAt: now,
            createdAt: found.createdAt,
            pendingPermission: found.pendingPermission,
            lastToolSummary: found.lastToolSummary
        )
        return found.id
    }

    /// What the reaper can prove about the process behind a session.
    ///
    /// The middle guard is the load-bearing one. A pid the hook reported is the
    /// process that SPAWNED the hook, which for a terminal-hosted agent is the
    /// agent itself — but for an IDE agent panel it is the extension-host helper
    /// (see LEARNINGS, "Agents inside IDEs"). That helper hosts many chats and
    /// outlives every one of them, so `kill(pid, 0)` says "alive" about a chat
    /// closed hours ago. Answering `.alive` there made those rows immortal:
    /// removal required a dead pid, and the pid never died.
    ///
    /// So liveness is only believed when the pid is itself an agent process.
    /// Anything else is `.unknown` and falls to a time ceiling — including the
    /// case where we have no scan to check against, which stays `.alive` because
    /// a failed `ps` must never start reaping live sessions.
    func liveness(of session: Session, now: Date) -> PidStatus {
        guard let pid = session.pid, pid > 0 else { return .unknown }
        guard isPidAlive(pid) else { return .dead }
        guard let scan = agentPidScan,
              max(0, now.timeIntervalSince(scan.at)) < policy.scanFreshness
        else { return .alive }
        return scan.pids.contains(pid) ? .alive : .unknown
    }

    /// One housekeeping pass. Idempotent, no timers — the caller drives this
    /// from a 15 s `Timer`.
    ///
    /// Four jobs, in this order per session:
    ///  1. remove: a `.dead` pid idle ≥ `policy.deadGrace`, or an `.unknown` one
    ///     idle ≥ `policy.orphanTTL`. An `.alive` agent is never time-removed,
    ///     however long it has been quiet;
    ///  2. expire: `pendingPermission` older than `policy.permissionTTL`;
    ///  3. calm: a `.needsAttention` session idle ≥ `policy.attentionTTL`;
    ///  4. stale: a `.working` session idle ≥ `policy.stale`.
    ///
    /// Removal short-circuits so a session never reports in two lists at once.
    @discardableResult
    public mutating func reap(now: Date) -> ReapResult {
        var removed: [String] = []
        var staled: [String] = []
        var permissionsExpired: [String] = []
        var attentionExpired: [String] = []

        for id in sessions.keys.sorted() {
            guard var s = sessions[id] else { continue }

            // CLOCK HARDENING: max(0, ...) everywhere. Sleep/wake and NTP steps
            // both move the wall clock backwards; a negative elapsed time makes
            // every comparison below false forever and the reaper silently stops.
            let idle = max(0, now.timeIntervalSince(s.updatedAt))

            switch liveness(of: s, now: now) {
            case .dead where idle >= policy.deadGrace,
                 .unknown where idle >= policy.orphanTTL:
                sessions.removeValue(forKey: id)
                removed.append(id)
                continue
            case .alive, .dead, .unknown:
                break
            }

            if let pending = s.pendingPermission {
                let age = max(0, now.timeIntervalSince(pending.receivedAt))
                if age >= policy.permissionTTL {
                    s.pendingPermission = nil
                    permissionsExpired.append(id)
                }
            }

            // Red is a claim about NOW. Nothing used to retract it: attention was
            // the one state with no way out but another hook event, so a session
            // that asked for you yesterday afternoon was still asking this
            // morning — and a pill that is permanently red is a pill nobody
            // reads. After this long of total silence we do not know what it
            // wants, and `.idle` is what "no signal" looks like here. Same rule
            // the bootstrap rows already follow: a guess must never manufacture
            // urgency.
            //
            // The pending guard is belt and braces — `permissionTTL` is far
            // shorter, so it has already cleared above — but it says the intent
            // out loud: a dialog we still believe is open keeps shouting.
            if s.state == .needsAttention, s.pendingPermission == nil,
               idle >= policy.attentionTTL {
                s.state = .idle
                attentionExpired.append(id)
            }

            if s.state == .working, idle >= policy.stale {
                s.state = .stale
                staled.append(id)
            }

            sessions[id] = s
        }

        return ReapResult(
            removed: removed,
            staled: staled,
            permissionsExpired: permissionsExpired,
            attentionExpired: attentionExpired)
    }

    // MARK: - Private

    /// Bootstrap placeholders, in a deterministic order. Sorted because two
    /// placeholders can share a tty (a shell that respawned an agent) and a
    /// dictionary's iteration order would make adoption a coin flip.
    private var candidates: [Session] {
        sessions.values.filter { $0.origin == .bootstrap }.sorted { $0.id < $1.id }
    }

    /// Bare-form tty, defensively.
    ///
    /// Both inputs — `DiscoveredProcess.tty` from the process scan and
    /// `HookEnvelope.tty` from an adapter — are documented as already bare. This
    /// normalises anyway because a mismatch here does not throw, it just quietly
    /// fails to adopt and leaves a duplicate row on screen.
    private func bareTTY(_ raw: String?) -> String? {
        guard var t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.hasPrefix("/dev/") { t = String(t.dropFirst("/dev/".count)) }
        switch t {
        case "", "??", "?", "-": return nil
        default: return t
        }
    }
}
