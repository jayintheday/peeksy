import AgentNotchCore
import AppKit
import SwiftUI

// MARK: - Metrics

/// Row heights, pinned.
///
/// The window is a STEP FUNCTION around the animation, so the controller has to
/// know the content's height before the content has ever been laid out. Every
/// height below is therefore fixed and applied with an explicit `.frame(height:)`
/// in the view — an estimate that merely approximates the layout would leave the
/// window smaller than what it draws, and "the window is smaller than its
/// content" is the definition of tearing.
enum NotchListMetrics {
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 32
    static let rowWithDetailHeight: CGFloat = 47
    static let separatorHeight: CGFloat = 1
    static let emptyStateHeight: CGFloat = 58
    static let tccFooterHeight: CGFloat = 78
    static let horizontalPadding: CGFloat = 10

    static func rowHeight(hasDetail: Bool) -> CGFloat {
        hasDetail ? rowWithDetailHeight : rowHeight
    }

    /// Height the expanded list WANTS. `NotchGeometryResolver` caps it at 60% of
    /// the screen; anything beyond that scrolls.
    static func contentHeight(rows: [SliceRow], tccBlocked: Bool) -> CGFloat {
        var height = headerHeight
        if rows.isEmpty {
            height += emptyStateHeight
        } else {
            for row in rows { height += rowHeight(hasDetail: row.detail != nil) }
            height += CGFloat(max(0, rows.count - 1)) * separatorHeight
        }
        if tccBlocked { height += tccFooterHeight }
        return height
    }
}

// MARK: - View

/// The expanded list: header, rows, and the Automation footer.
///
/// The row MODEL is `SliceRow`, reused wholesale from M2 — the duplicate-cwd
/// `· ttysNNN` disambiguation, the "no terminal" marker, the bootstrap
/// "waiting…" rule and the symbol table are all rules that were argued about
/// once and must not be re-derived here with subtly different answers.
struct NotchPanelView: View {
    let store: SessionStore
    let width: CGFloat
    /// Collapse SYNCHRONOUSLY, then focus. Never the other way round: holding a
    /// panel open across an app activation is a fight with the window server
    /// that we lose.
    let onRowTap: (Session) -> Void

    @State private var now = Date()
    @State private var hovered: String?
    /// ONE timer for the whole list. Sixty rows with a timer each is sixty
    /// run-loop sources to redraw text that changes once a second.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if rows.isEmpty {
                emptyState
            } else {
                list
            }
            footer
        }
        .frame(width: width, alignment: .topLeading)
        .foregroundStyle(.white)
        .onReceive(tick) { now = $0 }
    }

    private var rows: [SliceRow] {
        // Reading `ownerNameGeneration` registers the dependency that makes a
        // late-resolved app name ("Claude", for the desktop app's embedded
        // agent) repaint its row.
        _ = store.ownerNameGeneration
        return SliceRow.build(from: store.rows, ownerName: store.ownerName(forPid:))
    }

    // MARK: Header

    /// Lives BELOW the band, not inside it.
    ///
    /// The band's notch x-range is inert in every phase, so any control placed
    /// there would be invisible and unclickable. Putting the header in the list
    /// container sidesteps the constraint entirely and gives it the panel's full
    /// width instead of the ~140 pt left over to the right of the pill.
    private var header: some View {
        HStack(spacing: 6) {
            Text(headerText)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, NotchListMetrics.horizontalPadding)
        .frame(height: NotchListMetrics.headerHeight, alignment: .leading)
    }

    private var headerText: String {
        let aggregate = store.aggregate
        guard aggregate.count > 0 else { return "No agent sessions" }
        var text = aggregate.count == 1 ? "1 session" : "\(aggregate.count) sessions"
        if aggregate.attentionCount > 0 { text += " · \(aggregate.attentionCount) needs you" }
        return text
    }

    // MARK: Rows

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    rowButton(row)
                    if index < rows.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(height: NotchListMetrics.separatorHeight)
                    }
                }
            }
        }
        .scrollIndicators(.never)
    }

    private func rowButton(_ row: SliceRow) -> some View {
        rowBody(row)
            .frame(height: NotchListMetrics.rowHeight(hasDetail: row.detail != nil))
            .background(hovered == row.id ? Color.white.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
            // `.onHover` is for the row highlight and NOTHING else. It is never
            // allowed to drive panel state: SwiftUI hover is a visual-state
            // signal and the panel machine runs on logical state.
            .onHover { hovered = $0 ? row.id : (hovered == row.id ? nil : hovered) }
            .onTapGesture { onRowTap(row.session) }
    }

    private func rowBody(_ row: SliceRow) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: row.symbol)
                    .font(.system(size: 11))
                    .frame(width: 14)
                Text(row.label)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !row.hasTerminal {
                    Text("no terminal")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer(minLength: 6)
                Text(row.stateText)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                Text(elapsedText(now.timeIntervalSince(row.session.updatedAt)))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.4))
            }
            if let detail = row.detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, NotchListMetrics.horizontalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Empty & footer

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Nothing running.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
            if !store.hookInstalled {
                Text("Hook not installed — run scripts/install_hook.sh")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, NotchListMetrics.horizontalPadding)
        .frame(height: NotchListMetrics.emptyStateHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private var footer: some View {
        if store.tccBlocked {
            VStack(alignment: .leading, spacing: 6) {
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                Text(Tcc.remedy)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Automation settings") {
                    guard let url = URL(string: automationSettingsURL) else { return }
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
            .padding(.horizontal, NotchListMetrics.horizontalPadding)
            .frame(height: NotchListMetrics.tccFooterHeight, alignment: .topLeading)
        }
    }
}

private let automationSettingsURL =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
