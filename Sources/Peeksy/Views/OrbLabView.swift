import PeeksyCore
import AppKit
import SwiftUI

/// The orb tuning harness, behind `--orb-lab`.
///
/// It exists because of a hard process rule: `screencapture` is banned in this
/// repo, so an agent cannot look at what it just built. Anything that can only
/// be judged with eyes — does a 16pt orb read on black, does the loop pop, is
/// `.idle` grey legible — has to be handed to a person, and handing them a
/// window beats handing them a description.
///
/// Everything here is drawn at the REAL metrics from `NotchListMetrics` and
/// `RowTint.notchColour`, on literal #000, beside the SF Symbols it would
/// replace. A harness that flatters the thing it is testing is worse than none.
struct OrbLabView: View {
    /// Sizes worth arguing about. 16 is the proposal; 20 is the smallest size
    /// upstream actually tuned, and 12 is where it should visibly fall apart.
    private static let sizes: [CGFloat] = [12, 14, 16, 20, 24]

    private static let states: [(tint: RowTint, symbol: String, label: String, text: String)] = [
        (.working, "circle.dotted", "peeksy", "working"),
        (.attention, "exclamationmark.circle.fill", "customer-portal", "needs you"),
        (.stale, "clock", "some-project", "stalled"),
        (.done, "checkmark.circle", "othertool", "done"),
        (.idle, "circle", "localtool", "idle"),
        (.unknown, "questionmark.circle", "unknown-repo", "waiting…"),
    ]

    @State private var spinAll = true
    @State private var orbSide: CGFloat = 16
    @State private var mode: OrbMode = .globe

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                controls
                headToHead
                inSitu
                sizeSweep
                tintGrid
                notes
            }
            .padding(18)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Controls")
            HStack(spacing: 16) {
                Picker("", selection: $mode) {
                    ForEach(OrbMode.allCases, id: \.self) { m in
                        Text(m == .globe ? "globe (searching)" : "orbits (working)").tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Toggle("Spin", isOn: $spinAll).toggleStyle(.switch)
                Divider().frame(height: 16)
                Text("\(Int(orbSide))pt")
                    .font(.system(size: 11).monospacedDigit())
                Slider(value: $orbSide, in: 10...28, step: 1).frame(width: 130)
            }
            .foregroundStyle(.white)
            .font(.system(size: 11))

            Text(
                "\(mode == .globe ? "globe" : "orbits"): \(mode.dotCount) dots a frame, "
                    + "\(String(format: "%.1f", mode.loopDuration))s a loop. "
                    + "globe is a lat/long field, orbits is three rings — which is why "
                    + "orbits thins out first as the size drops."
            )
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: Head to head

    /// Both modes at once, ignoring the picker. The picker changes everything
    /// else on this page; this row is the one place you can see them together.
    private var headToHead: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("globe vs orbits, side by side")
            HStack(alignment: .top, spacing: 28) {
                ForEach(OrbMode.allCases, id: \.self) { candidate in
                    VStack(spacing: 10) {
                        HStack(alignment: .bottom, spacing: 14) {
                            ForEach(Self.sizes, id: \.self) { size in
                                SessionOrb(
                                    tint: .working, spinning: spinAll, mode: candidate, side: size)
                            }
                        }
                        Text(
                            "\(candidate.rawValue) · \(candidate.dotCount) dots · "
                                + "\(String(format: "%.1f", candidate.loopDuration))s"
                        )
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(12)
                    .background(Color.black)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                candidate == mode ? .white.opacity(0.35) : .white.opacity(0.12),
                                lineWidth: 1)
                    )
                }
            }
        }
    }

    // MARK: In situ — the actual decision

    private var inSitu: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("In situ — real row metrics, on literal #000")
            Text(
                "Left: the orb. Right: today's SF Symbol. "
                    + "Row height \(Int(NotchListMetrics.rowHeight))pt, label 12pt, as shipped."
            )
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.45))

            HStack(alignment: .top, spacing: 24) {
                mockList(useOrb: true)
                mockList(useOrb: false)
            }
        }
    }

    private func mockList(useOrb: Bool) -> some View {
        VStack(spacing: NotchListMetrics.separatorHeight) {
            ForEach(Self.states, id: \.label) { state in
                HStack(spacing: 6) {
                    if useOrb {
                        SessionOrb(
                            tint: state.tint,
                            spinning: spinAll && state.tint == .working,
                            mode: mode,
                            side: orbSide
                        )
                    } else {
                        Image(systemName: state.symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(state.tint.notchColour)
                            .frame(width: 14)
                    }
                    Text(state.label)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(state.text)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("2:14")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.4))
                }
                .foregroundStyle(.white)
                .frame(height: NotchListMetrics.rowHeight)
                .padding(.horizontal, NotchListMetrics.horizontalPadding)
            }
        }
        .frame(width: 300)
        .background(Color.black)
        .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: Size sweep

    private var sizeSweep: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Size sweep — `working`, spinning")
            Text(
                "Upstream ships two hand-tuned sizes, 64 and 20, and is explicit that they are "
                    + "\"separate designs, not a scale factor\". 16 is off the end of that range."
            )
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.45))

            HStack(alignment: .bottom, spacing: 20) {
                ForEach(Self.sizes, id: \.self) { size in
                    VStack(spacing: 6) {
                        SessionOrb(tint: .working, spinning: spinAll, mode: mode, side: size)
                        Text("\(Int(size))")
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .padding(12)
            .background(Color.black)
            .overlay(
                RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
        }
    }

    // MARK: Tints

    private var tintGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Every tint, spinning and at rest")
            Text(
                "The rest frame is upstream's reduced-motion still "
                    + "(t = \(String(format: "%.1f", OrbitsMode.restPhase))), "
                    + "not t = 0 — settled rows get a picture, not a flat one."
            )
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.45))

            HStack(alignment: .top, spacing: 18) {
                ForEach(Self.states, id: \.label) { state in
                    VStack(spacing: 8) {
                        SessionOrb(tint: state.tint, spinning: true, mode: mode, side: orbSide)
                        SessionOrb(tint: state.tint, spinning: false, mode: mode, side: orbSide)
                        Text(state.text)
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
            .padding(12)
            .background(Color.black)
            .overlay(
                RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
        }
    }

    // MARK: Notes

    private var notes: some View {
        VStack(alignment: .leading, spacing: 5) {
            heading("What to look for")
            ForEach(
                [
                    "Does the orb read as a sphere at 16pt, or as noise?",
                    "Watch one orb for ~30s: the loop is \(String(format: "%.1f", mode.loopDuration))s. Any pop at the wrap is a bug.",
                    "Is `.idle` / `.unknown` grey still legible, or does it vanish into the black?",
                    "Toggle Spin off: does the still frame read as a deliberate state, or as broken?",
                    "Against the SF Symbols: is this better, or just busier?",
                ], id: \.self
            ) { note in
                Text("· " + note)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
    }
}

/// An ordinary titled panel, exactly like `SliceWindow` and for the same reason:
/// a harness that needs its own presentation layer debugged is not a harness.
@MainActor
final class OrbLabWindow {
    private let panel: NSPanel
    private static let size = NSSize(width: 720, height: 720)

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Peeksy — orb lab"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: OrbLabView())
        // As in SliceWindow: empty, or the content drives the window size and
        // `constrainFrameRect(toScreen:)` shoves the result around.
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: Self.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setContentSize(Self.size)
        panel.center()
    }

    func show() {
        // An LSUIElement accessory is not the active app, and a plain
        // `orderFront` from an inactive app is a no-op.
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }
}
