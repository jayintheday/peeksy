import PeeksyCore
import AppKit
import Foundation
import Observation
import SwiftUI

// MARK: - View model

/// The one thing SwiftUI observes.
///
/// `phase` is mutated by the controller INSIDE `withAnimation`; `geometry` is
/// mutated OUTSIDE it, because a display rearrangement must move the window
/// instantly and animating a notch to a new position looks like a bug.
@MainActor
@Observable
final class NotchModel {
    var geometry: NotchGeometry
    var phase: NotchPhase = .collapsed
    /// False while the panel is ordered out. The pill's only animation is gated
    /// on this — see `PillView.breathing`.
    var isVisible = true

    @ObservationIgnored var onPillTap: () -> Void = {}
    @ObservationIgnored var onRowTap: (Session) -> Void = { _ in }
    @ObservationIgnored var onInstallHook: () -> Void = {}

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }
}

// MARK: - Controller

/// The state machine, and the single authority on window frames.
///
/// | from      | to        | trigger                              |
/// |-----------|-----------|--------------------------------------|
/// | collapsed | peeking   | cursor dwells in `pillHot`           |
/// | collapsed | pinned    | click on the pill                    |
/// | peeking   | pinned    | click on the pill or the band        |
/// | peeking   | collapsed | cursor leaves every zone, after grace|
/// | pinned    | collapsed | Escape / outside click / resign key / second pill click / row click |
/// | pinned    | peeking   | NEVER — a pin the pointer could undo would not be a pin |
/// | any       | collapsed + orderOut | the probe reports no menu bar  |
/// | any       | collapsed | space change, sleep, lock            |
@MainActor
final class NotchController {

    // MARK: Animation

    /// SwiftUI owns the visual size. The window frame is a STEP FUNCTION and is
    /// never animated: `setFrame(_:display:animate: true)` runs AppKit's blocking
    /// resize on a private timer outside SwiftUI's `CATransaction`, and at
    /// shielding level on a borderless panel that shears visibly against the notch.
    static let expandAnimation = Animation.spring(response: 0.34, dampingFraction: 0.82, blendDuration: 0)
    /// CRITICALLY damped on purpose. A ringing collapse has an unpredictable
    /// settle time, and settle time is exactly what the frame-shrink is
    /// scheduled against.
    static let collapseAnimation = Animation.spring(response: 0.26, dampingFraction: 1.00, blendDuration: 0)
    static let reducedMotionAnimation = Animation.easeOut(duration: 0.12)
    /// Conservative upper bound on how long `collapseAnimation` takes to settle.
    static let collapseSettle: TimeInterval = 0.45
    /// Grace added on top of `collapseSettle` before the watchdog fires.
    static let settleWatchdogSlack: TimeInterval = 0.12

    // MARK: Collaborators

    private let store: SessionStore
    private let scanner = MenuBarScanner()
    private lazy var menuBar = MenuBarProbe(scanner: scanner)
    /// Off switch, read once. If the window-list measurement ever goes wrong on
    /// a macOS we have not seen, this restores the previous behaviour without a
    /// rebuild.
    private let yieldEnabled = ProcessInfo.processInfo.environment["PEEKSY_YIELD"] != "off"
    private let screens = ScreenMetricsReader()
    private let hover = HoverEngine()
    private let dismiss = DismissMonitor()
    private let system = SystemEventObserver()
    private let layout = NotchLayout.default

    private var panel: NotchPanel?
    private var hosting: FirstMouseHostingView<NotchRootView>?
    private var model: NotchModel?

    // MARK: State

    private(set) var phase: NotchPhase = .collapsed
    private(set) var geometry: NotchGeometry?

    /// Set by `AppDelegate`. The empty state's "Install hook" affordance ends up
    /// here; the controller collapses first and then hands off, for the same
    /// reason a row tap does — holding the panel open across another window
    /// coming forward is a fight with the window server that we lose.
    var onInstallHookRequested: (() -> Void)?

    /// MANDATORY, not defensive.
    ///
    /// Hover-out → hover-in inside 300 ms is an ordinary gesture. Without an
    /// epoch, the stale collapse completion lands AFTER the new expand and slams
    /// the window down to pill size while the content is at full height. That is
    /// the tear, arriving late. Bumped on every transition and every geometry
    /// change; `applySettledFrame` returns early if it moved.
    private var frameEpoch = 0
    private var pendingSettleFrame: CGRect?
    private var settleTask: Task<Void, Never>?
    private var isHidden = false
    private var visibilityTimer: Timer?
    /// Last width handed to the resolver, for change detection in `observeStore`.
    private var lastPillWidth: CGFloat?
    /// Whether we are currently standing aside for somebody else's status icon.
    private var yield = NeighbourYield()
    /// True when yielding on this display means hiding rather than shrinking —
    /// a display with no notch has no body to shrink to.
    private var yieldMeansHide = false

    init(store: SessionStore) {
        self.store = store
    }

    // MARK: - Lifecycle

    func start() {
        guard panel == nil else { return }
        guard let initial = computeGeometry() else {
            uiLog.error("no screen available — the notch window cannot be built")
            return
        }
        geometry = initial
        NotchGeometryResolver.assertInvariant(initial)
        uiLog.info("notch geometry:\n\(initial.description, privacy: .public)")

        let model = NotchModel(geometry: initial)
        self.model = model

        let panel = NotchPanel(contentRect: initial.collapsedFrame)
        let hosting = FirstMouseHostingView(rootView: NotchRootView(model: model, store: store))
        hosting.frame = CGRect(origin: .zero, size: initial.collapsedFrame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        // Explicit, because `sizingOptions = []` means nothing else will do it.
        panel.setContentSize(initial.collapsedFrame.size)
        self.panel = panel
        self.hosting = hosting

        wire(model: model, hosting: hosting, panel: panel)

        hover.update(zones: initial.hoverZones)
        refreshHitMask()
        dismiss.interactiveRects = initial.interactiveRects(for: .collapsed)

        // …Regardless: an accessory app is never active, and a plain
        // `orderFront` from an inactive app is a no-op.
        panel.orderFrontRegardless()
        system.start()
        observeStore()
        // After `orderFrontRegardless`, because the calibration check wants our
        // own window in the list, and before the first hover.
        housekeepingTick()
        hover.burst()
    }

    func stop() {
        settleTask?.cancel()
        settleTask = nil
        stopVisibilityWatch()
        system.stop()
        dismiss.disarm()
        hover.stop()
        panel?.orderOut(nil)
    }

    private func wire(model: NotchModel, hosting: FirstMouseHostingView<NotchRootView>, panel: NotchPanel) {
        model.onPillTap = { [weak self] in self?.togglePin() }
        model.onRowTap = { [weak self] session in self?.handleRowTap(session) }
        model.onInstallHook = { [weak self] in
            self?.collapse()
            self?.onInstallHookRequested?()
        }

        hosting.onMouseEntered = { [weak self] in self?.hover.pointerEnteredBand() }
        hosting.onMouseExited = { [weak self] in self?.hover.pointerExitedBand() }
        hosting.onMouseMoved = { [weak self] in self?.hover.pointerMovedInBand() }

        hover.onEffect = { [weak self] effect in
            guard let self else { return }
            switch effect {
            case .expand:
                if self.phase == .collapsed { self.open(as: .peeking) }
            case .collapse:
                if self.phase == .peeking { self.collapse() }
            }
        }

        panel.onCancel = { [weak self] in self?.collapse() }
        dismiss.onDismiss = { [weak self] in self?.collapse() }

        system.onGeometryChanged = { [weak self] in self?.housekeepingTick() }
        // A new app's status item can push the run left into where the pill
        // sits, and a quitting app's departure is how the room comes back.
        system.onMenuBarPopulationChanged = { [weak self] in self?.housekeepingTick() }
        // The reap tick, borrowed. See `SessionStore.onHousekeeping`.
        store.onHousekeeping = { [weak self] in self?.housekeepingTick() }
        system.onWake = { [weak self] in
            self?.refreshGeometry()
            self?.hover.burst()
        }
        system.onDismiss = { [weak self] in
            self?.collapse()
            // A Space change is also how entering and leaving another app's full
            // screen arrives, and full screen is the commonest reason the menu
            // bar disappears. Re-resolving here is what makes the pill come back
            // the moment the menu bar does.
            self?.refreshGeometry()
        }
    }

    // MARK: - Geometry

    /// `screen` is passed in by `refreshGeometry`, which has just taken a
    /// reading; resolving it again here would be a second window-list scan per
    /// refresh for an answer we already have.
    private func computeGeometry(on screen: NSScreen? = nil) -> NotchGeometry? {
        guard let screen = screen ?? menuBar.read().screen ?? NSScreen.main else { return nil }
        return NotchGeometryResolver.resolve(
            screen: screens.metrics(for: screen),
            listContentHeight: currentContentHeight(),
            pillContentWidth: currentPillWidth(),
            layout: layout
        )
    }

    /// The collapsed window's width is a function of the pill, and the pill is
    /// narrower with nothing to count. Sitting on menu bar we are not drawing in
    /// is what covers other apps' status icons, so the frame tracks the content.
    private func currentPillWidth() -> CGFloat {
        yield.pillContentWidth(wanting: wantedPillWidth())
    }

    /// The width the pill would like to be, before any yielding.
    private func wantedPillWidth() -> CGFloat {
        PillMetrics.contentWidth(sessionCount: store.aggregate.count)
    }

    /// Has the collapsed width moved since the last time anyone asked?
    ///
    /// `store.aggregate` is published in the same `publish()` as `store.rows`, so
    /// the already-tracked `rows` read is enough to be told about it — this needs
    /// no new observation dependency, only a comparison.
    private func pillWidthChanged() -> Bool {
        let width = currentPillWidth()
        guard width != lastPillWidth else { return false }
        lastPillWidth = width
        return true
    }

    private func currentContentHeight() -> CGFloat {
        // Must be built EXACTLY as the view builds it, task titles included: the
        // height is a step function of `detail != nil`, so a row that has a
        // subtitle here and not there is the window drawing content it did not
        // make room for.
        let rows = SliceRow.build(
            from: store.rows,
            ownerName: store.ownerName(forPid:),
            taskTitle: store.taskTitle(forSessionID:))
        return NotchListMetrics.contentHeight(
            rows: rows, tccBlocked: store.tccBlocked, hookInstalled: store.hookInstalled)
    }

    /// Recompute and, if anything moved, `setFrame` IN PLACE.
    ///
    /// Never a teardown-and-rebuild. The reference app rebuilds its panel on
    /// every `didChangeScreenParameters`; that flashes and drops key status, and
    /// a laptop user hits it several times a day just opening and closing the
    /// lid.
    func refreshGeometry() {
        guard panel != nil, let model else { return }
        // ONE reading, both consumers. `setHidden` and `computeGeometry` used to
        // ask the anchor separately, which was free; asking the window server
        // twice per refresh is not.
        let menuBarReading = menuBar.read()
        // Yielding on a display with no notch means hiding: there the collapsed
        // window IS the pill, so there is nothing to shrink back to.
        setHidden(!menuBarReading.isPresent || (yield.level == .yielded && yieldMeansHide))
        guard let fresh = computeGeometry(on: menuBarReading.screen),
              fresh != geometry
        else { return }

        let previousLiveFrame = geometry?.frame(for: phase)
        geometry = fresh
        NotchGeometryResolver.assertInvariant(fresh)
        frameEpoch &+= 1

        // Outside `withAnimation`: a display rearrangement teleports.
        model.geometry = fresh
        hover.update(zones: fresh.hoverZones)
        dismiss.interactiveRects = fresh.interactiveRects(for: phase)
        refreshHitMask()

        // Only if the window we are ACTUALLY showing moved. A new session
        // arriving changes the expanded height while we are collapsed, and
        // burst-polling the pointer for three seconds every time a Bash-heavy
        // turn ticks would undo the whole reason the collapsed state installs no
        // global monitor.
        guard previousLiveFrame != fresh.frame(for: phase) else { return }
        stepFrame(to: fresh.frame(for: phase))
        // The rects just moved under a possibly stationary cursor.
        hover.burst()
    }

    /// `orderOut` when there is no menu bar: hidden bar, or another app in full
    /// screen. Both mean the same thing — there is nowhere to hang the pill.
    ///
    /// Status-item OVERFLOW used to arrive here too, because the oracle was a
    /// status item that overflowed. It no longer does, and should not: a
    /// shielding-level window cannot overflow, and hiding the product because
    /// somebody else's icon got dropped is backwards.
    private func setHidden(_ hide: Bool) {
        guard isHidden != hide else { return }
        isHidden = hide
        // Before the orderOut, so the animation is torn down while the layer
        // still exists rather than being left attached to a hidden window.
        model?.isVisible = !hide
        if hide {
            collapseImmediately()
            panel?.orderOut(nil)
            startVisibilityWatch()
        } else {
            stopVisibilityWatch()
            panel?.orderFrontRegardless()
            hover.burst()
        }
    }

    /// Re-measure the menu bar and, if the verdict changed, move the window.
    ///
    /// Deliberately NOT part of `refreshGeometry`. That runs on the hover path
    /// via `open(as:)`, and a window-list scan is the kind of work the collapsed
    /// state's whole design exists to keep out of it.
    @discardableResult
    func refreshYield() -> Bool {
        guard yieldEnabled, let g = geometry else { return false }
        let screen = menuBar.read().screen ?? NSScreen.main
        guard let screen else { return false }
        let metrics = screens.metrics(for: screen)
        yieldMeansHide = !metrics.hasNotch

        // What we would occupy if we were NOT yielding. Asking about the
        // yielded footprint would be circular — it always fits, so we would
        // never come back.
        let atFull = NotchGeometryResolver.resolve(
            screen: metrics,
            listContentHeight: 0,
            pillContentWidth: wantedPillWidth(),
            layout: layout)

        let occupancy = scanner.occupancy(
            screen: metrics,
            bandHeight: g.bandHeight,
            // Our own panel, whose true frame we know, as live proof that the
            // bounds and the y-flip both still mean what we think.
            calibration: panel.map { (UInt32($0.windowNumber), $0.frame) })

        let before = yield.level
        guard yield.apply(occupancy, fullFootprintMaxX: atFull.collapsedFrame.maxX) else {
            return false
        }
        uiLog.info("""
            menu bar yield \(String(describing: before), privacy: .public) → \
            \(String(describing: self.yield.level), privacy: .public) \
            (run at \(occupancy.statusRunMinX ?? -1, privacy: .public), \
            we would end at \(atFull.collapsedFrame.maxX, privacy: .public))
            """)
        return true
    }

    /// Re-measure, then re-resolve. Driven by `SessionStore`'s reap tick and by
    /// the same system events that already move the window, so this adds no
    /// timer and no idle wakeups of its own.
    func housekeepingTick() {
        refreshYield()
        refreshGeometry()
    }

    /// The ONLY way back from hidden.
    ///
    /// Every other call site for `refreshGeometry` is an event — a screen change,
    /// a wake, a store update while open. None of those fire when the user simply
    /// leaves another app's full-screen Space and the menu bar comes back, and a
    /// hidden collapsed panel generates no events of its own. Without this the
    /// app hides once and never returns, which is indistinguishable from a crash.
    /// It runs ONLY while hidden, so the steady-state cost is zero.
    private func startVisibilityWatch() {
        guard visibilityTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            // `housekeepingTick`, not `refreshGeometry`: on a display with no
            // notch a yield IS the hide, so measuring is the only way back out
            // of it.
            MainActor.assumeIsolated { self?.housekeepingTick() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        visibilityTimer = timer
    }

    private func stopVisibilityWatch() {
        visibilityTimer?.invalidate()
        visibilityTimer = nil
    }

    // MARK: - Transitions

    /// GROW. Order is the whole point and there is no `DispatchQueue.main.async`
    /// anywhere in it — all five steps are one runloop turn.
    ///
    /// The single frame where the window is expanded but the content is still
    /// collapsed renders transparent, i.e. invisible.
    private func open(as target: NotchPhase) {
        guard target.isOpen else { return }
        // The expanded height is a function of the row list, and while collapsed
        // that height is not tracked (see `observeStore`). Settle it here, in the
        // one moment it starts to matter.
        refreshGeometry()
        // `isHidden` is re-read AFTER the refresh: that refresh is also where the
        // menu bar gets re-examined, so checking first would let us expand a
        // panel that the same call had just ordered out.
        guard !isHidden, let g = geometry, let model, let panel else { return }
        // Bumped here so any collapse completion still in flight from a
        // hover-out 300 ms ago is invalidated before it can shrink the window
        // under freshly expanded content.
        frameEpoch &+= 1
        cancelSettle()

        phase = target
        hover.setPhase(target)

        // 1. The mask follows LOGICAL state and is set synchronously at the START
        //    of the transition, so the list is clickable on frame 1 — mid-animation.
        refreshHitMask()
        dismiss.interactiveRects = g.interactiveRects(for: target)

        // 2. Window to the larger of {current, target}. Step function.
        stepFrame(to: g.expandedFrame)

        // 3. On screen before the animation, never after.
        panel.orderFrontRegardless()

        // 4. Only now does anything animate.
        withAnimation(animation(for: .expand)) { model.phase = target }

        setWantsKey(target == .pinned)
        if target == .pinned { dismiss.arm(window: panel) }

        // 5. AppKit re-evaluates tracking-area membership only on POINTER
        //    movement; a stationary cursor after a `setFrame` would otherwise
        //    never be re-examined and the machine would wedge.
        hover.burst()
    }

    /// SHRINK — the direction that tears.
    ///
    /// The naive order (setFrame small, then animate) shrinks the hosting view's
    /// bounds instantly and SwiftUI CLIPS the list away instead of animating it,
    /// because window layers always mask to bounds. So: mask first, animate the
    /// content, and only apply the smaller frame once the content has settled.
    func collapse() {
        guard phase != .collapsed, let g = geometry, let model else { return }
        frameEpoch &+= 1
        let epoch = frameEpoch
        cancelSettle()

        // Before the shrink, so key moves on immediately — a panel that still
        // holds key while collapsing eats the user's next keystroke. Disarm
        // first, or `wantsKey = false` yielding key re-enters `onDismiss`.
        dismiss.disarm()
        setWantsKey(false)

        phase = .collapsed
        // Suppress a re-open ONLY when the pointer is actually sitting on the
        // pill. That is the case where a dismissal would otherwise undo itself
        // 180 ms later — the pointer never moved, so the dwell simply restarts
        // and the pill becomes uncloseable. Asking the question here, rather
        // than passing an unconditional flag, means a grace-driven collapse
        // (pointer elsewhere by definition) never arms a suppression that would
        // then need something to come along and clear it.
        let pointerOnPill = g.pillHotRect.contains(NSEvent.mouseLocation)
        hover.setPhase(.collapsed, suppressReopenUntilExit: pointerOnPill)

        // Dead on frame 1, so a click during the fade-out passes to the menu bar
        // as the user intended.
        refreshHitMask()
        dismiss.interactiveRects = g.interactiveRects(for: .collapsed)

        pendingSettleFrame = g.collapsedFrame
        withAnimation(animation(for: .collapse), completionCriteria: .removed) {
            model.phase = .collapsed
        } completion: { [weak self] in
            self?.applySettledFrame(epoch: epoch)
        }
        // Belt and braces: SwiftUI skips the completion when an animation is
        // interrupted or when the value never actually changes.
        scheduleSettleWatchdog(epoch: epoch)
        hover.burst()
    }

    /// No animation, no settle. For "the world changed underneath us" — the
    /// menu bar vanished, we are about to `orderOut`.
    private func collapseImmediately() {
        guard let g = geometry, let model else { return }
        frameEpoch &+= 1
        cancelSettle()
        dismiss.disarm()
        setWantsKey(false)
        phase = .collapsed
        // No suppression: the panel is about to be ordered out entirely, and
        // `open(as:)` refuses to run while hidden.
        hover.setPhase(.collapsed)
        model.phase = .collapsed
        commitFrame(g.collapsedFrame)
        dismiss.interactiveRects = g.interactiveRects(for: .collapsed)
    }

    /// A pill click. Pre-empts a pending dwell in the open direction, and is the
    /// only thing that closes a pinned panel from the pill.
    func togglePin() {
        guard !isHidden else { return }
        if phase == .pinned {
            collapse()
        } else {
            open(as: .pinned)
        }
    }

    /// Collapse SYNCHRONOUSLY first, then focus.
    ///
    /// `SessionStore.focus` already settles every piece of local state before
    /// anything slow starts. Holding the panel open across an app activation is a
    /// fight with the window server that we lose.
    private func handleRowTap(_ session: Session) {
        collapse()
        store.focus(session)
    }

    // MARK: - Frames

    /// The window teleports to the larger of {current, target}; the transparent
    /// excess hides the difference. Tearing is definitionally "the window is
    /// smaller than the content it draws", so this formulation makes it
    /// impossible by construction.
    private func stepFrame(to target: CGRect) {
        guard let panel else { return }
        let current = panel.frame
        // A display change can move the window somewhere entirely different.
        // Unioning across two displays would produce an absurd rect; there is
        // nothing to tear against in a teleport, so just go.
        if current.isEmpty || !current.intersects(target) || contains(target, current) {
            commitFrame(target)
            return
        }
        let union = target.union(current)
        if !approxEqual(union, current) { commitFrame(union) }
        pendingSettleFrame = target
        scheduleSettleWatchdog(epoch: frameEpoch)
    }

    private func commitFrame(_ frame: CGRect) {
        guard let panel, let hosting else { return }
        // display: false and NEVER animate: true. See `expandAnimation`.
        panel.setFrame(frame, display: false)
        hosting.frame = CGRect(origin: .zero, size: frame.size)
        // The mask is stored window-local, so it is stale the instant the frame
        // moves. Recomputing here means the two can never disagree.
        refreshHitMask()
    }

    private func applySettledFrame(epoch: Int) {
        guard epoch == frameEpoch, let target = pendingSettleFrame else { return }
        cancelSettle()
        commitFrame(target)
        hover.burst()
    }

    private func scheduleSettleWatchdog(epoch: Int) {
        settleTask?.cancel()
        let delay = settleDuration + Self.settleWatchdogSlack
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard !Task.isCancelled else { return }
            self?.applySettledFrame(epoch: epoch)
        }
    }

    private func cancelSettle() {
        settleTask?.cancel()
        settleTask = nil
        pendingSettleFrame = nil
    }

    // MARK: - Mask

    /// Window-local, recomputed from the window's ACTUAL frame.
    ///
    /// During a collapse the window is still expanded while the mask is already
    /// the collapsed one — those are different origins, and converting against
    /// the phase's nominal frame instead of the live one would offset the whole
    /// mask by the list's height.
    private func refreshHitMask() {
        guard let hosting, let panel, let g = geometry else { return }
        let frame = panel.frame
        hosting.interactiveMask = g.interactiveRects(for: phase).map {
            NotchGeometryResolver.windowRect($0, in: frame)
        }
    }

    // MARK: - Key

    private func setWantsKey(_ want: Bool) {
        guard let panel else { return }
        if want {
            panel.wantsKey = true
            // `.nonactivatingPanel` means this takes key WITHOUT activating the
            // app — which is what makes a local `.keyDown` monitor (and therefore
            // Escape) work without an Accessibility grant.
            panel.makeKey()
        } else {
            // The setter hands key back if we are holding it.
            panel.wantsKey = false
        }
    }

    // MARK: - Animation choice

    private enum Direction { case expand, collapse }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private func animation(for direction: Direction) -> Animation {
        if reduceMotion { return Self.reducedMotionAnimation }
        return direction == .expand ? Self.expandAnimation : Self.collapseAnimation
    }

    private var settleDuration: TimeInterval {
        reduceMotion ? 0.12 : Self.collapseSettle
    }

    // MARK: - Store observation

    /// Row count and the TCC footer both change the expanded height, and the
    /// expanded height is an INPUT to the window frame — so a new session
    /// arriving while the panel is open has to move the window.
    private func observeStore() {
        withObservationTracking {
            _ = store.rows
            _ = store.tccBlocked
            _ = store.ownerNameGeneration
            // A resolved task title gives a row a second line it did not have,
            // and `rowHeight(hasDetail:)` is a step function — so this is a
            // content-height change, not just a repaint.
            _ = store.taskTitleGeneration
            // The empty state is TALLER while the hook is missing, so the probe
            // flipping is a content-height change like any other.
            _ = store.hookInstalled
        } onChange: {
            // `onChange` fires BEFORE the value is applied, hence the hop.
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Only while the list is on screen. A Bash-heavy turn publishes
                // ten snapshots a second; re-deriving row labels and rects that
                // nobody can see, all day, is exactly the kind of cost a 24/7
                // menu-bar app cannot afford. `open(as:)` refreshes on the way in.
                //
                // …EXCEPT that the COLLAPSED width now tracks the pill, so the
                // one content change that must move a closed window is the pill
                // growing or shrinking. `pillWidthChanged` is two-valued, so this
                // costs a refresh on a 0 ↔ 1 session crossing and nothing on the
                // other nine publishes that second.
                if self.phase.isOpen || self.pillWidthChanged() { self.refreshGeometry() }
                self.observeStore()
            }
        }
    }

    // MARK: - Harness

    /// Read-only windows into the AppKit state, for `--notch-harness`.
    ///
    /// The alternative to a harness is driving the real pointer across a real
    /// user's screen, which is both intrusive and unreproducible. These two
    /// accessors make the frame ordering — the part with no pure equivalent —
    /// observable from a script.
    var debugPanelFrame: CGRect? { panel?.frame }
    var debugMask: [CGRect] { hosting?.interactiveMask ?? [] }
    /// `nil` here is the app's single "there is no menu bar" signal, so it is
    /// worth being able to see it without guessing. `debugMenuBarInset` is the
    /// independent second opinion — the two disagreeing is the thing to look at.
    var debugMenuBarRect: CGRect? { menuBar.read().rect }
    var debugMenuBarScreen: String? { menuBar.read().screen?.localizedName }
    var debugMenuBarInset: CGFloat? { menuBar.read().inset }
    var debugYieldLevel: NotchYieldLevel { yield.level }

    // MARK: - Rect helpers

    private func contains(_ outer: CGRect, _ inner: CGRect) -> Bool {
        let eps = NotchGeometryResolver.epsilon
        return inner.minX >= outer.minX - eps && inner.maxX <= outer.maxX + eps
            && inner.minY >= outer.minY - eps && inner.maxY <= outer.maxY + eps
    }

    private func approxEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        let eps = NotchGeometryResolver.epsilon
        return abs(a.minX - b.minX) <= eps && abs(a.minY - b.minY) <= eps
            && abs(a.width - b.width) <= eps && abs(a.height - b.height) <= eps
    }
}
