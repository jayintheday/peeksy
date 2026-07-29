import PeeksyCore
import SwiftUI

/// The single continuous black shape.
///
/// ONE `UnevenRoundedRectangle` that resizes — not two hierarchies swapping, and
/// specifically not `matchedGeometryEffect`. A matched-geometry crossfade between
/// a "pill" view and a "panel" view has two shapes on screen during the
/// transition, and two black shapes over a notch is exactly the seam this design
/// exists to avoid.
///
/// The `UnevenRoundedRectangle` notch-continuation treatment is adapted from
/// open-focus (MIT, © 2026 Filip Sokolowski) — see NOTICE.
///
/// SwiftUI owns the VISUAL size here. The window frame is a step function driven
/// by `NotchController` and is never animated; whenever the window is larger
/// than this shape the excess is transparent and invisible.
struct NotchChrome: View {
    let geometry: NotchGeometry
    let phase: NotchPhase
    /// The window's LIVE committed frame — see `NotchModel.windowFrame`. NOT
    /// `geometry.frame(for: phase)`: during a collapse the phase is already
    /// `.collapsed` while the window is still the wide, left-shifted rect.
    let windowFrame: CGRect
    let isVisible: Bool
    let store: SessionStore
    let onPillTap: () -> Void
    let onRowTap: (Session) -> Void
    let onInstallHook: () -> Void

    private var expanded: Bool { phase.isOpen }

    /// The list container's height. THE ONLY animating dimension besides width.
    /// `bandHeight` never animates — the notch must not appear to move.
    private var listHeight: CGFloat { expanded ? geometry.listHeight : 0 }

    private var width: CGFloat {
        expanded ? geometry.expandedFrame.width : geometry.collapsedFrame.width
    }

    /// Cancels the window's own movement.
    ///
    /// The expanded frame is centred on the notch and the collapsed frame is
    /// not, so the window's top-left steps LEFT to open and back RIGHT to close.
    /// This offset steps by the same amount in the opposite direction, which
    /// makes everything below it live in one fixed coordinate space whose origin
    /// is `collapsedFrame.minX` — the space every other offset in this view is
    /// already measured in.
    ///
    /// It MUST NOT animate. `NotchController.commitFrame` publishes
    /// `windowFrame` inside `withTransaction(animation: nil)` for that reason:
    /// animating it would slide the pill sideways across the camera housing on
    /// every open and close.
    private var windowCompensation: CGFloat {
        geometry.collapsedFrame.minX - windowFrame.minX
    }

    /// Where the panel's left edge sits, in the space `windowCompensation`
    /// establishes. Negative: the centred panel starts left of the band.
    /// A CONSTANT — the list is laid out here from frame one and never moves.
    private var panelX: CGFloat {
        geometry.expandedFrame.minX - geometry.collapsedFrame.minX
    }

    /// The unfurl: 0 collapsed, `panelX` open.
    ///
    /// The shape grows LEFT out of the band's own x-range by exactly this much
    /// while its `width` grows past the band's right edge, so the panel opens
    /// symmetrically about the notch instead of appearing at full width.
    /// THIS one animates — it is the only horizontal thing that does.
    private var unfurlX: CGFloat { expanded ? panelX : 0 }

    /// Where the pill sits inside the shape.
    ///
    /// Computed through the tested global→SwiftUI conversion rather than by
    /// hand, and measured against `collapsedFrame` — which is NOT the window's
    /// frame any more, but IS the origin of the space `windowCompensation`
    /// establishes. So this offset stays phase-independent and the pill still
    /// provably cannot drift during the animation. Its `y` is 0, since the panel
    /// top and the pill top are both pinned to `screenFrame.maxY`.
    private var pillFrame: CGRect {
        NotchGeometryResolver.swiftUIRect(geometry.pillRect, in: geometry.collapsedFrame)
    }

    /// The capsule's own width, which is narrower than the slot only if someone
    /// sets `NotchLayout.pillPadding`. Read from the geometry rather than
    /// recomputed, so the drawn width and the reserved width are the same number.
    private var pillContentFrame: CGRect {
        NotchGeometryResolver.swiftUIRect(geometry.pillContentRect, in: geometry.collapsedFrame)
    }

    private var radii: RectangleCornerRadii {
        let r = min(12, geometry.bandHeight / 2)
        return RectangleCornerRadii(
            // Flush with the screen's top edge in every state.
            topLeading: 0,
            // The notch's OWN bottom-left corner sits under the camera
            // housing, where a radius would be invisible — but
            // `geometry.leftCapRect` gives this corner a few points of real
            // screen pixels to curve into instead, mirroring the pill's
            // rounded end on the right. Safe to round unconditionally: on
            // the rare display with no room for the cap, this degenerates
            // back to the old invisible-but-harmless case.
            bottomLeading: r,
            bottomTrailing: r,
            topTrailing: 0
        )
    }

    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
        // BOTH children carry `-unfurlX`, so the shape is the only thing that
        // actually travels. That is not a flourish: the shape is the `.background`
        // of this whole stack, and the pill is painted with a 6% white wash that
        // is only legible ON that black. Hoisting the pill out of this subtree to
        // stop it moving takes its backdrop away with it, and it turns into a
        // near-invisible outline over the wallpaper.
        //
        // Note what this collapses to when `unfurlX == 0`: the exact tree that
        // shipped before centring, offsets and all. The collapsed state cannot
        // regress, by construction.
        return ZStack(alignment: .topLeading) {
            // `panelX - unfurlX` holds the list STILL in screen space while the
            // container slides out from under it, so the text is laid out at its
            // final position from frame one and the shape's clip does the reveal.
            listContainer
                .offset(x: panelX - unfurlX, y: geometry.bandHeight)
            // And the pill, which must not move at all — it is a fixed landmark
            // beside a physical notch.
            band
                .offset(x: -unfurlX)
        }
        .frame(width: width, height: geometry.bandHeight + listHeight, alignment: .topLeading)
        // Literal #000. `FirstMouseHostingView.allowsVibrancy` is false so this
        // is not tinted by whatever is behind the menu bar, which is what makes
        // it indistinguishable from the bezel.
        .background(shape.fill(Color.black))
        .clipShape(shape)
        // The unfurl, paired with the `width` above: the shape's left edge
        // travels out as its right edge does, so it opens symmetrically about
        // the notch rather than only rightwards. Every child cancels it.
        .offset(x: unfurlX)
        // The window is frequently bigger than the shape — always during a
        // collapse, briefly during an expand. Pin to the top-left so the excess
        // is transparent rather than the shape being centred in it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // OUTSIDE the frame above, and a step rather than an animation: this one
        // cancels the window's own movement, so everything inside it is laid out
        // as though the window never moved at all. Kept as a separate modifier
        // from `unfurlX` precisely so the two cannot share a transaction.
        .offset(x: windowCompensation)
    }

    // MARK: Band

    /// The band is IDENTICAL in every phase. Nothing in it moves, appears or
    /// resizes, which is the cheapest possible guarantee that the notch does not
    /// appear to shift when the panel opens.
    private var band: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            PillView(
                aggregate: store.aggregate,
                slotWidth: pillFrame.width,
                contentWidth: pillContentFrame.width,
                bandHeight: geometry.bandHeight,
                isVisible: isVisible
            )
            .offset(x: pillFrame.minX, y: pillFrame.minY)
            .onTapGesture { onPillTap() }
        }
        .frame(width: width, height: geometry.bandHeight, alignment: .topLeading)
    }

    // MARK: List

    @ViewBuilder
    private var listContainer: some View {
        // Laid out at the FINAL expanded width even mid-animation, so the text
        // does not reflow on every frame while the shape widens; the clip does
        // the reveal.
        Group {
            if listHeight > 0 {
                NotchPanelView(
                    store: store,
                    width: geometry.expandedFrame.width,
                    isVisible: isVisible,
                    onRowTap: onRowTap,
                    onInstallHook: onInstallHook
                )
            }
        }
        .frame(width: geometry.expandedFrame.width, height: listHeight, alignment: .topLeading)
        .opacity(expanded ? 1 : 0)
        .clipped()
    }
}

// MARK: - Root

/// What the hosting view actually hosts. One observable read of `model.phase`
/// and `model.geometry`; everything else is derived.
struct NotchRootView: View {
    let model: NotchModel
    let store: SessionStore

    var body: some View {
        NotchChrome(
            geometry: model.geometry,
            phase: model.phase,
            windowFrame: model.windowFrame,
            isVisible: model.isVisible,
            store: store,
            onPillTap: { model.onPillTap() },
            onRowTap: { model.onRowTap($0) },
            onInstallHook: { model.onInstallHook() }
        )
    }
}
