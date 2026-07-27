import AppKit
import Foundation

/// Escape and click-outside, armed ONLY while `.pinned`.
///
/// Not while `.peeking`: there, hover-exit already IS the dismissal and a click
/// is a PIN. Arming here would race the pin — the same mouseDown would both
/// create and destroy the pinned state, and which one won would depend on
/// monitor ordering.
@MainActor
final class DismissMonitor {

    /// Called when something says "close". Always a full dismissal to
    /// `.collapsed`; there is no path back to `.peeking`, because a pin the user
    /// could lose by moving the mouse would not be a pin.
    var onDismiss: (() -> Void)?

    /// Global-coordinate rects a click may land in WITHOUT dismissing.
    var interactiveRects: [CGRect] = []

    private var globalMouse: Any?
    private var localMouse: Any?
    private var localKey: Any?
    private var resignKeyObserver: NSObjectProtocol?

    private(set) var isArmed = false

    private let notificationCenter: NotificationCenter

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func arm(window: NSWindow) {
        guard !isArmed else { return }
        isArmed = true

        // Observe-only. The click still reaches whatever the user aimed at,
        // which is the correct behaviour: an outside click should do its own job
        // AND dismiss us. Mouse types need no TCC grant.
        globalMouse = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseDown() }
        }

        // The local half. Without it a click on our own pill or a row would be
        // read as "outside", because a global monitor never sees events destined
        // for our windows and this one does.
        localMouse = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseDown() }
            return event
        }

        // Escape via a LOCAL key monitor. A GLOBAL key monitor would require an
        // Accessibility grant and is banned outright — see HoverEngine. This
        // works because `.nonactivatingPanel` lets the panel be key while the app
        // stays inactive, which is exactly what `NotchPanel.wantsKey` is for.
        localKey = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Escape
            MainActor.assumeIsolated { self?.onDismiss?() }
            return nil // swallow it
        }

        // Cmd-Tab, Spotlight, Mission Control: all of them take key away, and a
        // black panel left over the menu bar afterwards is a bug report.
        resignKeyObserver = notificationCenter.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onDismiss?() }
        }
    }

    func disarm() {
        guard isArmed else { return }
        isArmed = false
        for monitor in [globalMouse, localMouse, localKey].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        globalMouse = nil
        localMouse = nil
        localKey = nil
        if let resignKeyObserver { notificationCenter.removeObserver(resignKeyObserver) }
        resignKeyObserver = nil
    }

    /// `NSEvent.mouseLocation`, never `event.locationInWindow`: for a global
    /// monitor the latter is in SOMEBODY ELSE'S window, and comparing it to our
    /// global rects produces a number that is wrong by an arbitrary offset.
    private func handleMouseDown() {
        let point = NSEvent.mouseLocation
        for rect in interactiveRects where rect.contains(point) { return }
        onDismiss?()
    }
}
