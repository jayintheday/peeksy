import AgentNotchCore
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

    /// Where the pill sits inside the shape.
    ///
    /// Computed through the tested global→SwiftUI conversion rather than by
    /// hand, and measured against `collapsedFrame` because the collapsed and
    /// expanded frames share a top-left origin by construction — so this offset
    /// is phase-independent and the pill provably cannot drift during the
    /// animation. Its `y` is 0, since the panel top and the pill top are both
    /// pinned to `screenFrame.maxY`.
    private var pillFrame: CGRect {
        NotchGeometryResolver.swiftUIRect(geometry.pillRect, in: geometry.collapsedFrame)
    }

    private var radii: RectangleCornerRadii {
        let r = min(12, geometry.bandHeight / 2)
        return RectangleCornerRadii(
            // Flush with the screen's top edge in every state.
            topLeading: 0,
            // On a notched display the collapsed shape's bottom-left corner sits
            // under the hardware notch, where a radius would be invisible; once
            // the panel hangs below the menu bar the same corner is very much
            // visible and wants one. Without a notch it is always visible.
            bottomLeading: geometry.hasNotch && !expanded ? 0 : r,
            bottomTrailing: r,
            topTrailing: 0
        )
    }

    var body: some View {
        let shape = UnevenRoundedRectangle(cornerRadii: radii, style: .continuous)
        return ZStack(alignment: .topLeading) {
            listContainer
                .offset(y: geometry.bandHeight)
            band
        }
        .frame(width: width, height: geometry.bandHeight + listHeight, alignment: .topLeading)
        // Literal #000. `FirstMouseHostingView.allowsVibrancy` is false so this
        // is not tinted by whatever is behind the menu bar, which is what makes
        // it indistinguishable from the bezel.
        .background(shape.fill(Color.black))
        .clipShape(shape)
        // The window is frequently bigger than the shape — always during a
        // collapse, briefly during an expand. Pin to the top-left so the excess
        // is transparent rather than the shape being centred in it.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            isVisible: model.isVisible,
            store: store,
            onPillTap: { model.onPillTap() },
            onRowTap: { model.onRowTap($0) },
            onInstallHook: { model.onInstallHook() }
        )
    }
}
