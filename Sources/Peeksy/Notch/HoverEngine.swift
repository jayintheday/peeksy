import PeeksyCore
import AppKit
import Foundation

/// The AppKit half of the hover machine: event sources and timers. Every
/// decision lives in `HoverEngineCore`; this file only decides WHEN to ask.
///
/// The permission surface is the constraint that shapes all of it. This app must
/// never need anything beyond Automation→Terminal, which the user has already
/// granted. `NSEvent.addGlobalMonitorForEvents` silently restricts KEY events
/// (`.keyDown`, `.keyUp`, `.flagsChanged`) to processes with an Accessibility
/// grant; MOUSE types need no grant at all. So: global mouse monitors are fine,
/// and `.flagsChanged` must never appear in a global monitor even for something
/// as innocent as an Option-click modifier — it would fail silently and tempt
/// the next person into adding the entitlement.
@MainActor
final class HoverEngine {

    private var core: HoverEngineCore
    private var zones: HoverZones?

    /// Called with `.expand` / `.collapse`. The controller owns what those mean.
    var onEffect: ((HoverEffect) -> Void)?

    /// Expanded-state monitors. A PAIR, because a global monitor never sees
    /// events destined for our own windows and a local one never sees anybody
    /// else's.
    private var globalMove: Any?
    private var localMove: Any?

    /// Burst poll and the expanded idle poll. See `burst(reason:)`.
    private var burstTimer: Timer?
    private var burstUntil: TimeInterval = 0
    private var idleTimer: Timer?

    init(policy: HoverPolicy = .default) {
        core = HoverEngineCore(policy: policy)
    }

    var phase: NotchPhase { core.phase }

    func update(zones: HoverZones) {
        self.zones = zones
    }

    /// Externally forced phase (pill click, Escape, space change…).
    ///
    /// `suppressReopenUntilExit` is what stops a click on the pill from being
    /// undone by the dwell it is sitting in the middle of.
    func setPhase(_ phase: NotchPhase, suppressReopenUntilExit: Bool = false) {
        core.setPhase(phase, suppressReopenUntilExit: suppressReopenUntilExit)
        core.forgetMotion()
        syncMonitors()
    }

    // MARK: - Collapsed: tracking area only

    /// The pointer entered the collapsed band.
    ///
    /// Arms a short pump rather than trusting `mouseMoved:` to keep arriving: an
    /// inactive app's window is not a reliable source of `.mouseMoved`, whereas
    /// `NSEvent.mouseLocation` is a pull and always works. The pump costs
    /// nothing when the pointer is elsewhere, which is ~100% of the day.
    func pointerEnteredBand() {
        burst(seconds: core.policy.burstDuration)
    }

    func pointerExitedBand() {
        sample()
        // Do not stop the burst here. A `mouseExited` immediately followed by a
        // stationary cursor is exactly the wedge case; the burst is what unwedges
        // it, and it expires on its own.
    }

    func pointerMovedInBand() {
        sample()
    }

    // MARK: - Expanded: global + local pair

    /// `.peeking` ONLY, not "open".
    ///
    /// A pinned panel ignores the pointer by definition — there is no
    /// `pinned → peeking` edge — so leaving a global mouse monitor installed
    /// while pinned would wake this process on every pointer movement to compute
    /// a decision that can never be acted on.
    private func syncMonitors() {
        if core.phase == .peeking {
            installMoveMonitors()
            startIdlePoll()
        } else {
            removeMoveMonitors()
            stopIdlePoll()
        }
    }

    private func installMoveMonitors() {
        guard globalMove == nil else { return }
        // `.mouseMoved` only. No `.flagsChanged` — see the file comment.
        globalMove = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        localMove = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.sample() }
            return event
        }
    }

    private func removeMoveMonitors() {
        if let globalMove { NSEvent.removeMonitor(globalMove) }
        if let localMove { NSEvent.removeMonitor(localMove) }
        globalMove = nil
        localMove = nil
    }

    private func startIdlePoll() {
        guard idleTimer == nil else { return }
        let timer = Timer(timeInterval: core.policy.idlePoll, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer.tolerance = core.policy.idlePoll / 4
        // `.common`: a run loop tracking a scroll must not stop the poll.
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func stopIdlePoll() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    // MARK: - Burst poll

    /// The PULL source, and mandatory.
    ///
    /// AppKit re-evaluates tracking-area membership only on pointer MOVEMENT. A
    /// stationary cursor after a `setFrame` therefore gets neither `mouseExited`
    /// nor `mouseEntered` — the rects moved underneath it — and the state machine
    /// wedges open or wedges shut with no event that could ever free it. Polling
    /// `NSEvent.mouseLocation` for a few seconds after every frame change, every
    /// geometry settle, every completed transition and every wake is what makes
    /// the machine self-correcting instead of merely usually-right.
    func burst(seconds: TimeInterval? = nil) {
        let duration = seconds ?? core.policy.burstDuration
        burstUntil = max(burstUntil, ProcessInfo.processInfo.systemUptime + duration)
        // The zones just moved under a possibly stationary cursor; any speed
        // computed across that change would be fiction.
        core.forgetMotion()
        guard burstTimer == nil else { return }
        let timer = Timer(timeInterval: core.policy.burstInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.burstTick() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        burstTimer = timer
        sample()
    }

    private func burstTick() {
        sample()
        let now = ProcessInfo.processInfo.systemUptime
        // Keep polling past the deadline while a decision is actually pending —
        // stopping mid-dwell would strand it. But an open panel with nothing
        // pending hands over to the 500 ms idle poll rather than sitting at
        // 60 ms for as long as the user reads the list.
        guard now >= burstUntil, core.nextDeadline == nil else { return }
        burstTimer?.invalidate()
        burstTimer = nil
    }

    // MARK: - Sampling

    /// One observation, from wherever. The engine cannot tell a polled sample
    /// from an event-driven one and must not care.
    private func sample() {
        guard let zones else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let effects = core.pointer(NSEvent.mouseLocation, at: now, zones: zones)
        deliver(effects)
    }

    /// Fire pending deadlines without a new position. Used by the controller
    /// after it changes geometry.
    func tick() {
        deliver(core.tick(ProcessInfo.processInfo.systemUptime))
    }

    private func deliver(_ effects: [HoverEffect]) {
        guard !effects.isEmpty else { return }
        syncMonitors()
        for effect in effects { onEffect?(effect) }
    }

    // MARK: - Teardown

    func stop() {
        removeMoveMonitors()
        stopIdlePoll()
        burstTimer?.invalidate()
        burstTimer = nil
    }
}
