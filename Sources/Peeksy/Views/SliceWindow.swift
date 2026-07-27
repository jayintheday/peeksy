import AppKit
import Foundation
import SwiftUI

/// The M2 window. An ORDINARY panel, on purpose.
///
/// Titled, closable, draggable, standard window level. No borderless panel, no
/// shielding window level, no notch geometry, no hover, no tracking areas — M3
/// replaces this file wholesale, and building any of that here would mean
/// debugging the presentation layer before the data layer has ever been looked
/// at with human eyes. It exists so real sessions can be watched all day.
@MainActor
final class SliceWindow {
    private let panel: NSPanel

    /// Big enough for ~6 two-line rows without scrolling.
    private static let size = NSSize(width: 420, height: 360)
    private static let margin: CGFloat = 20

    init(store: SessionStore, onInstallHook: @escaping () -> Void = {}) {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Peeksy (slice)"
        panel.level = .floating
        panel.isFloatingPanel = true
        // The app is an LSUIElement accessory with no Dock icon, so it is almost
        // never the active app. Without this the panel would vanish the moment
        // focus lands on the Terminal it just raised — which is every click.
        panel.hidesOnDeactivate = false
        // NSWindow defaults to releasing itself on close. Nothing else keeps this
        // panel alive, so a close would leave `panel` dangling.
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(
            rootView: SliceListView(store: store, onInstallHook: onInstallHook))
        // EMPTY sizingOptions, deliberately. NSHostingView defaults to driving
        // the window's size from SwiftUI's ideal size, which made this panel
        // grow to whatever the content wanted (measured: 613 pt) and then get
        // shoved around by `constrainFrameRect(toScreen:)`. The slice is a
        // fixed-size box that scrolls; the content must not move it.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setContentSize(Self.size)

        positionTopRight()
    }

    func show() {
        // …Regardless: an accessory app is not active, and a plain `orderFront`
        // from an inactive app is a no-op.
        panel.orderFrontRegardless()
    }

    private func positionTopRight() {
        guard let visible = NSScreen.main?.visibleFrame else {
            panel.center()
            return
        }
        // `panel.frame`, not `Self.size`: the frame includes the title bar, and
        // measuring from the content size would push the title bar up under the
        // menu bar — at which point AppKit constrains the window back down and
        // the placement silently stops being the one asked for.
        let frame = panel.frame
        // visibleFrame already excludes the menu bar and the Dock, so this lands
        // below the menu bar rather than behind it.
        let origin = NSPoint(
            x: visible.maxX - frame.width - Self.margin,
            y: visible.maxY - frame.height - Self.margin
        )
        panel.setFrameOrigin(origin)
    }
}
