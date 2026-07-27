import CoreGraphics

/// The pill's DRAWN dimensions.
///
/// These live in Core rather than in `PillView` for one reason: the collapsed
/// window reserves menu bar pixels for the capsule, and "what is drawn" drifting
/// apart from "what the window reserves" is exactly how this app came to paint
/// 64 pt of other apps' menu bar black in order to show a 44 pt capsule.
/// `NotchGeometryResolver.check` asserts the two still agree, so the drift
/// cannot come back silently.
public enum PillMetrics {

    /// The capsule's height, and — because a bare dot is a circle rather than a
    /// capsule — also its width when there is nothing to count.
    public static let capsuleHeight: CGFloat = 22
    public static let dotSize: CGFloat = 6
    /// Dot + gap + count.
    public static let countedWidth: CGFloat = 44

    /// Two-valued ON PURPOSE.
    ///
    /// The count is `monospacedDigit()` and 44 pt already clears three digits, so
    /// a width that tracked the digit count would buy a few points back and
    /// reintroduce the 9 → 10 jitter that the monospacing exists to prevent. A
    /// pill that changes size on its own looks broken.
    public static func contentWidth(sessionCount: Int) -> CGFloat {
        sessionCount > 0 ? countedWidth : capsuleHeight
    }
}
