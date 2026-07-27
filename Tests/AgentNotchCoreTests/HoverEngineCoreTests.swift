import CoreGraphics
import Foundation
import Testing

@testable import AgentNotchCore

/// Zones from the real 14" fixture, so the distances the velocity gate sees are
/// the distances it will see in production.
///
/// `pillContentWidth` is PINNED rather than left to the default. The collapsed
/// width tracks the session count now, and `velocityGateRestarts` flicks across
/// `pillHotRect` in 20 ms and asserts it reads as fast: at the zero-session width
/// that crossing is 30 pt, i.e. 1300 pt/s against a 1400 pt/s gate, and the test
/// would fail for a reason that has nothing to do with hover.
private let geometry = NotchGeometryResolver.resolve(
    screen: ScreenFixture.notched14,
    listContentHeight: 140,
    pillContentWidth: PillMetrics.contentWidth(sessionCount: 3))
private let zones = geometry.hoverZones

private var pill: CGPoint { CGPoint(x: geometry.pillRect.midX, y: geometry.pillRect.midY) }
/// Inside the panel, well below the menu bar.
private var panelBody: CGPoint { CGPoint(x: geometry.expandedFrame.midX, y: geometry.expandedFrame.minY + 20) }
/// The middle of the screen — outside everything.
private var wilderness: CGPoint { CGPoint(x: geometry.screenFrame.midX, y: geometry.screenFrame.midY) }
/// Control Center's corner: outside us, but inside the menu bar strip.
private var controlCentre: CGPoint {
    CGPoint(x: geometry.screenFrame.maxX - 40, y: geometry.screenFrame.maxY - 10)
}

@Suite("HoverEngineCore")
struct HoverEngineCoreTests {

    // MARK: - Speed

    @Test("fewer than two samples is speed 0, never 'unknown'")
    func speedNeedsTwoSamples() {
        let sample = PointerSample(location: .zero, time: 1)
        // The gate may only ever RESTART a dwell, so treating missing data as
        // slow is the safe direction: we never suppress an open for lack of it.
        #expect(pointerSpeed(nil, sample) == 0)
    }

    @Test("a sub-4ms delta is discarded rather than divided by")
    func speedIgnoresTinyDeltas() {
        let a = PointerSample(location: CGPoint(x: 0, y: 0), time: 1.000)
        let b = PointerSample(location: CGPoint(x: 1, y: 0), time: 1.001)
        // 1 pt in 1 ms is 1000 pt/s of pure rounding error.
        #expect(pointerSpeed(a, b) == 0)
    }

    @Test("speed is plain euclidean points per second")
    func speedMaths() {
        let a = PointerSample(location: CGPoint(x: 0, y: 0), time: 0)
        let b = PointerSample(location: CGPoint(x: 30, y: 40), time: 0.1)
        #expect(abs(pointerSpeed(a, b) - 500) < 0.001)
    }

    // MARK: - Dwell

    @Test("a resting cursor opens after the dwell and not before")
    func dwellOpens() {
        var core = HoverEngineCore()
        #expect(core.pointer(pill, at: 0, zones: zones).isEmpty)
        #expect(core.dwellDeadline == 0.180)
        // 179 ms is not 180.
        #expect(core.tick(0.179).isEmpty)
        #expect(core.phase == .collapsed)
        #expect(core.tick(0.180) == [.expand])
        #expect(core.phase == .peeking)
    }

    @Test("leaving before the dwell fires cancels it outright")
    func leavingCancelsTheDwell() {
        var core = HoverEngineCore()
        _ = core.pointer(pill, at: 0, zones: zones)
        _ = core.pointer(wilderness, at: 0.05, zones: zones)
        #expect(core.dwellDeadline == nil)
        #expect(core.tick(1.0).isEmpty)
        #expect(core.phase == .collapsed)
    }

    @Test("a slow cursor accumulates dwell instead of restarting it")
    func slowMovementAccumulates() {
        var core = HoverEngineCore()
        _ = core.pointer(pill, at: 0, zones: zones)
        // 2 pt over 60 ms ≈ 33 pt/s. Nudging the mouse must not reset the timer,
        // or a hand resting on a trackpad would never open the panel.
        _ = core.pointer(CGPoint(x: pill.x + 2, y: pill.y), at: 0.06, zones: zones)
        #expect(core.dwellDeadline == 0.180)
        #expect(core.tick(0.180) == [.expand])
    }

    @Test("a fast traverse RESTARTS the dwell rather than banking it")
    func velocityGateRestarts() {
        var core = HoverEngineCore()
        // Arrive slowly at the left edge of the hot rect and start dwelling.
        _ = core.pointer(CGPoint(x: geometry.pillHotRect.minX + 2, y: pill.y), at: 0, zones: zones)
        #expect(core.dwellDeadline == 0.180)
        // Then flick across it: 60 pt in 20 ms = 3000 pt/s, comfortably over the
        // 1400 pt/s gate and still landing inside the pill.
        _ = core.pointer(CGPoint(x: geometry.pillHotRect.maxX - 2, y: pill.y), at: 0.02, zones: zones)
        #expect(core.lastSpeed > 1400)
        // Re-armed from now, so the 20 ms already served is forfeit.
        #expect(abs((core.dwellDeadline ?? 0) - 0.200) < 1e-9)
        #expect(core.tick(0.180).isEmpty)
        #expect(core.tick(0.200) == [.expand])
    }

    @Test("the dwell timer is itself the primary gate: a fly-by never opens")
    func flyByNeverOpens() {
        var core = HoverEngineCore()
        // ~30 ms to cross a 52 pt pill is what a fast traverse actually costs.
        _ = core.pointer(CGPoint(x: geometry.pillHotRect.minX + 1, y: pill.y), at: 0, zones: zones)
        _ = core.pointer(CGPoint(x: geometry.pillHotRect.maxX + 200, y: pill.y), at: 0.03, zones: zones)
        #expect(core.tick(1.0).isEmpty)
        #expect(core.phase == .collapsed)
    }

    // MARK: - Grace

    @Test("leaving every zone collapses after the 250 ms grace")
    func exitGrace() {
        var core = openedCore()
        _ = core.pointer(wilderness, at: 1.0, zones: zones)
        #expect(core.graceDeadline == 1.250)
        #expect(core.tick(1.24).isEmpty)
        #expect(core.tick(1.25) == [.collapse])
        #expect(core.phase == .collapsed)
    }

    @Test("a cursor heading into the menu bar gets the short grace")
    func menuBarGrace() {
        var core = openedCore()
        // 100 ms, not 250: a user reaching for Control Center should not have a
        // black panel sitting over the target.
        _ = core.pointer(controlCentre, at: 1.0, zones: zones)
        #expect(core.graceDeadline == 1.100)
        #expect(core.tick(1.100) == [.collapse])
    }

    @Test("coming back inside cancels the grace")
    func returningCancelsGrace() {
        var core = openedCore()
        _ = core.pointer(wilderness, at: 1.0, zones: zones)
        #expect(core.graceDeadline != nil)
        _ = core.pointer(panelBody, at: 1.1, zones: zones)
        #expect(core.graceDeadline == nil)
        #expect(core.tick(2.0).isEmpty)
        #expect(core.phase == .peeking)
    }

    @Test("the grace corridor keeps a fast downward flick alive")
    func corridorHoldsTheFlick() {
        var core = openedCore()
        // Just outside the panel but inside the corridor, which is derived from
        // the FINAL expanded frame — so this is "inside" even while the window
        // is still growing.
        let justBelow = CGPoint(x: geometry.expandedFrame.midX, y: geometry.expandedFrame.minY - 8)
        _ = core.pointer(justBelow, at: 1.0, zones: zones)
        #expect(core.graceDeadline == nil)
        #expect(core.phase == .peeking)
    }

    @Test("the grace is armed once and not re-armed by further movement outside")
    func graceIsNotRetriggered() {
        var core = openedCore()
        _ = core.pointer(wilderness, at: 1.0, zones: zones)
        _ = core.pointer(CGPoint(x: wilderness.x + 5, y: wilderness.y), at: 1.1, zones: zones)
        // Still 1.25. Otherwise a cursor wandering outside would keep the panel
        // open indefinitely.
        #expect(core.graceDeadline == 1.250)
    }

    // MARK: - Pinning

    @Test("a pinned panel ignores the pointer entirely")
    func pinnedIgnoresHover() {
        var core = openedCore()
        core.setPhase(.pinned)
        _ = core.pointer(wilderness, at: 2.0, zones: zones)
        #expect(core.graceDeadline == nil)
        #expect(core.tick(10).isEmpty)
        // pinned → peeking never happens: a pin the pointer could undo would not
        // be a pin.
        #expect(core.phase == .pinned)
    }

    @Test("clicking the pill to close does not re-open it under a stationary cursor")
    func explicitDismissalSuppressesReopen() {
        var core = openedCore()
        core.setPhase(.pinned)
        // The user clicks the pill again. The pointer has not moved, so without
        // suppression the dwell simply restarts and the panel reopens 180 ms
        // later — the pill would be uncloseable.
        core.setPhase(.collapsed, suppressReopenUntilExit: true)
        #expect(core.reopenSuppressed)
        _ = core.pointer(pill, at: 1.0, zones: zones)
        _ = core.pointer(pill, at: 1.5, zones: zones)
        #expect(core.dwellDeadline == nil)
        #expect(core.tick(5.0).isEmpty)
        #expect(core.phase == .collapsed)
    }

    @Test("moving away and back re-opens: the suppression is intent-scoped, not a lockout")
    func suppressionClearsOnExit() {
        var core = openedCore()
        core.setPhase(.collapsed, suppressReopenUntilExit: true)
        _ = core.pointer(pill, at: 1.0, zones: zones)
        #expect(core.dwellDeadline == nil)
        // Leaving expresses that the previous intent is spent.
        _ = core.pointer(wilderness, at: 1.2, zones: zones)
        #expect(!core.reopenSuppressed)
        _ = core.pointer(pill, at: 2.0, zones: zones)
        #expect(core.tick(2.18) == [.expand])
    }

    @Test("a grace-driven collapse never suppresses — the controller only arms it on the pill")
    func graceCollapseDoesNotSuppress() {
        var core = openedCore()
        _ = core.pointer(wilderness, at: 1.0, zones: zones)
        #expect(core.tick(1.25) == [.collapse])
        // `NotchController.collapse` passes `suppressReopenUntilExit` only when
        // the pointer is inside `pillHot`, which by construction it is not here.
        core.setPhase(.collapsed, suppressReopenUntilExit: false)
        #expect(!core.reopenSuppressed)
        _ = core.pointer(pill, at: 1.30, zones: zones)
        #expect(core.tick(1.48) == [.expand])
    }

    @Test("a forced phase change clears both timers")
    func setPhaseClearsTimers() {
        var core = HoverEngineCore()
        _ = core.pointer(pill, at: 0, zones: zones)
        #expect(core.dwellDeadline != nil)
        // Escape, a space change, the anchor vanishing — every one of them makes
        // the pending decision moot.
        core.setPhase(.collapsed)
        #expect(core.dwellDeadline == nil)
        #expect(core.graceDeadline == nil)
    }

    // MARK: - Polling

    @Test("an idle collapsed engine wants no polling at all")
    func zeroIdleWakeups() {
        var core = HoverEngineCore()
        // The whole reason the collapsed state installs no global monitor: for a
        // 24/7 app this is the difference between zero idle wakeups and one per
        // pointer movement, forever.
        #expect(!core.wantsPolling)
        _ = core.pointer(wilderness, at: 0, zones: zones)
        #expect(!core.wantsPolling)
        _ = core.pointer(pill, at: 1, zones: zones)
        #expect(core.wantsPolling) // a dwell is armed
    }

    @Test("an open panel always wants polling, because a still cursor gets no events")
    func openWantsPolling() {
        let core = openedCore()
        #expect(core.wantsPolling)
        #expect(core.nextDeadline == nil)
    }

    @Test("forgetMotion stops a setFrame from being mistaken for a gesture")
    func forgetMotionAfterFrameChange() {
        var core = HoverEngineCore()
        _ = core.pointer(CGPoint(x: pill.x - 500, y: pill.y), at: 0, zones: zones)
        // The window just resized under a stationary cursor. The next sample is
        // at a "new" position only because the zones moved; computing a speed
        // across that gap would invent a 20 000 pt/s flick out of nothing.
        core.forgetMotion()
        _ = core.pointer(pill, at: 0.01, zones: zones)
        #expect(core.lastSpeed == 0)
        #expect(core.dwellDeadline == 0.190)
    }

    // MARK: - Round trip

    @Test("hover-out then hover-in inside 300 ms is an ordinary gesture")
    func rapidReentry() {
        var core = openedCore()
        _ = core.pointer(wilderness, at: 1.0, zones: zones)
        #expect(core.tick(1.25) == [.collapse])
        // Back on the pill 50 ms later. This is the sequence the controller's
        // frame epoch exists for: without it the stale collapse completion lands
        // after this re-expansion.
        _ = core.pointer(pill, at: 1.30, zones: zones)
        #expect(core.tick(1.48) == [.expand])
        #expect(core.phase == .peeking)
    }

    private func openedCore() -> HoverEngineCore {
        var core = HoverEngineCore()
        _ = core.pointer(pill, at: 0, zones: zones)
        _ = core.tick(0.180)
        precondition(core.phase == .peeking)
        return core
    }
}
