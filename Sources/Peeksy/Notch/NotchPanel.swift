import AppKit
import SwiftUI

// The window and its hosting view. Every line of configuration below is
// load-bearing; the panel is the one place where a wrong default is invisible
// until it is a 24/7 bug.
//
// The NSPanel configuration is adapted from open-focus (MIT, © 2026 Filip
// Sokolowski) — see NOTICE.

// MARK: - Panel

@MainActor
final class NotchPanel: NSPanel {

    /// Whether the panel is ALLOWED to be key. False everywhere except `.pinned`.
    ///
    /// This is what makes `acceptsFirstMouse` mandatory rather than an
    /// optimisation: while this is false the panel can never become key, so
    /// every click on the pill is a "first" click, and `NSHostingView`'s default
    /// `acceptsFirstMouse == false` would make the pill permanently dead.
    var wantsKey = false {
        didSet { if !wantsKey && isKeyWindow { yieldKey() } }
    }

    /// Escape, via `NSResponder.cancelOperation`. Only reachable while the panel
    /// is key, which is only while `.pinned` — exactly when Escape should mean
    /// "close".
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { wantsKey }
    /// Never main. A main window would put us in the window cycle and make
    /// Cmd-` land on a 32 pt black band.
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Identity. The default clamps a window to the screen's VISIBLE frame,
    /// which is exactly the menu-bar strip we are trying to draw in — the
    /// default silently slid the panel 33 pt down the screen, and the resulting
    /// black bar under the menu bar looks like a layout bug rather than a
    /// constraint. The controller is the only authority on this window's frame.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // ORDER IS LOAD-BEARING. `isFloatingPanel`'s setter assigns
        // `level = .floating` as a side effect, so setting the level first and
        // this second silently reverts it — measured: the window came back at
        // layer 3 and AppKit then constrained it to below the menu bar.
        isFloatingPanel = true
        // One below the shielding level. THIS is what draws over the menu bar;
        // `.floating` and `.statusBar` both render underneath it.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
            .fullScreenDisallowsTiling,
        ]
        // MANDATORY OVERRIDE, not a tidy-up. NSPanel defaults this to true, and
        // this app is `.accessory` so it is almost never the active app — the
        // pill would vanish the instant focus landed on the Terminal it just
        // raised, which is every single click.
        hidesOnDeactivate = false
        // Nothing else retains the panel.
        isReleasedWhenClosed = false
        hasShadow = false
        backgroundColor = .clear
        isOpaque = false
        // AppKit's own window animations run on a private timer outside SwiftUI's
        // CATransaction. At shielding level on a borderless panel that shears
        // visibly against the notch.
        animationBehavior = .none
        // Tracking areas want this even though they nominally manage it
        // themselves; without it a `.mouseMoved` tracking option is unreliable
        // for an inactive app.
        acceptsMouseMovedEvents = true
        // A borderless panel has no title bar to drag, but AppKit will still
        // move it by the background if asked.
        isMovableByWindowBackground = false
        isMovable = false
    }

    /// Hand key status back.
    ///
    /// `resignKey()` alone only posts the notification — the window server still
    /// believes we are key, and the user's next keystroke goes nowhere. An
    /// `orderOut`/`orderFrontRegardless` pair in the SAME runloop turn is
    /// definitive and never draws an intermediate frame.
    private func yieldKey() {
        let wasVisible = isVisible
        orderOut(nil)
        if wasVisible { orderFrontRegardless() }
    }
}

// MARK: - Hosting view

/// `NSHostingView` with three overrides, each of which the panel does not work
/// without.
@MainActor
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {

    /// Interactive regions in this view's WINDOW coordinate space (y-up).
    ///
    /// Driven by `NotchController` from `NotchGeometry` and never by a SwiftUI
    /// preference: the mask has to follow LOGICAL state, and a preference is by
    /// construction a report of VISUAL state one layout pass late.
    var interactiveMask: [CGRect] = []

    var onMouseEntered: (() -> Void)?
    var onMouseExited: (() -> Void)?
    var onMouseMoved: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        // EMPTY, deliberately. The default lets SwiftUI's ideal size drive the
        // window, which in M2 grew the panel to 613 pt and then let
        // `constrainFrameRect(toScreen:)` shove it to the top-left. The window
        // is a step function owned by the controller; the content must never
        // move it.
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// True, and not negotiable — see `NotchPanel.wantsKey`.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Off, so our black is literal #000 and indistinguishable from the bezel.
    /// Vibrancy would tint it with whatever is behind the menu bar.
    override var allowsVibrancy: Bool { false }

    /// Nil outside the mask.
    ///
    /// Returning nil means the click does nothing at all — AppKit does not
    /// re-route it to the window below. That is the intended behaviour over the
    /// notch x-range: an invisible cursor cannot make an informed click, and a
    /// pin-toggle the user cannot see is the most confusing failure this app has.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in the SUPERVIEW's space. For a content view that is
        // already window space, but converting explicitly keeps this correct if
        // the view is ever nested and costs nothing.
        let windowPoint = superview?.convert(point, to: nil) ?? point
        for rect in interactiveMask where rect.contains(windowPoint) {
            return super.hitTest(point)
        }
        return nil
    }

    // MARK: Tracking

    /// The collapsed state's ONLY input, on purpose.
    ///
    /// `.activeAlways` fires for an inactive app, which we always are. A global
    /// `.mouseMoved` monitor would do the same job and wake this process on
    /// every pointer movement, forever; for an app that runs all day that is the
    /// difference between zero idle wakeups and thousands.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero, // ignored under .inVisibleRect
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onMouseEntered?() }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
    override func mouseMoved(with event: NSEvent) { onMouseMoved?() }
}
