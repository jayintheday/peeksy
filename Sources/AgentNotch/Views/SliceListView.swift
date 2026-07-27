import AgentNotchCore
import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - Row model

/// One rendered row. A flat value so the label rules — which need to look at
/// ALL visible rows to spot a duplicate project — are computed once per
/// snapshot instead of per row inside a `body`.
struct SliceRow: Identifiable, Equatable {
    let id: String
    let session: Session
    let label: String
    let stateText: String
    let symbol: String
    /// Second line. `nil` when there is nothing worth saying.
    let detail: String?
    /// False for the Claude.app case — the row still works, it just raises an
    /// app rather than a terminal tab.
    let hasTerminal: Bool

    /// Build the visible rows from a registry snapshot.
    ///
    /// `sessions` arrives already ordered by the registry; this never re-sorts.
    static func build(
        from sessions: [Session],
        ownerName: (Int32) -> String?
    ) -> [SliceRow] {
        // A project can legitimately have two agents in it (two tabs, same repo).
        // Showing "agent-notch" twice is indistinguishable from a duplicate-row
        // bug, so both get disambiguated — never just the second one.
        var projectCounts: [String: Int] = [:]
        for session in sessions {
            guard let key = ProjectLabel.projectKey(session.cwd) else { continue }
            projectCounts[key, default: 0] += 1
        }

        return sessions.map { session in
            let hasTerminal = normalizeTty(session.tty) != nil
            var label = self.label(for: session, hasTerminal: hasTerminal, ownerName: ownerName)

            if let key = ProjectLabel.projectKey(session.cwd),
               projectCounts[key, default: 0] > 1,
               let tty = normalizeTty(session.tty) {
                label += " · \(tty)"
            }

            return SliceRow(
                id: session.id,
                session: session,
                label: label,
                stateText: stateText(for: session),
                symbol: symbol(for: session),
                detail: session.pendingPermission?.summary ?? session.lastToolSummary,
                hasTerminal: hasTerminal
            )
        }
    }

    private static func label(
        for session: Session,
        hasTerminal: Bool,
        ownerName: (Int32) -> String?
    ) -> String {
        if let project = ProjectLabel.display(session.cwd) { return project }
        // No cwd. For a tty-less session the owning application IS the most
        // useful identity we have ("Claude" for the desktop app's embedded agent).
        if !hasTerminal, let pid = session.pid, let name = ownerName(pid) { return name }
        return session.source.displayName
    }

    private static func stateText(for session: Session) -> String {
        // Provenance beats state: a bootstrap row's state is a guess, and
        // printing "working" for a guess manufactures urgency we cannot back up.
        if session.origin == .bootstrap { return "waiting…" }
        switch session.state {
        case .idle: return "idle"
        case .working: return "working"
        case .needsAttention: return "needs you"
        case .done: return "done"
        case .stale: return "stalled"
        }
    }

    /// Plain SF Symbols. No colour, no pulsing, no `TimelineView` — that is M4.
    private static func symbol(for session: Session) -> String {
        if session.origin == .bootstrap { return "questionmark.circle" }
        switch session.state {
        case .idle: return "circle"
        case .working: return "circle.dotted"
        case .needsAttention: return "exclamationmark.circle.fill"
        case .done: return "checkmark.circle"
        case .stale: return "clock"
        }
    }
}

/// `m:ss` under an hour, `Hh Mm` above it.
///
/// Clamped at zero: sleep/wake and NTP steps move the wall clock backwards, and
/// "-3:-12" on screen is worse than "0:00".
func elapsedText(_ interval: TimeInterval) -> String {
    let total = Int(max(0, interval))
    if total < 3600 {
        return String(format: "%d:%02d", total / 60, total % 60)
    }
    return "\(total / 3600)h \((total % 3600) / 60)m"
}

// MARK: - View

/// The M2 list. Deliberately plain — M3 throws this away.
struct SliceListView: View {
    let store: SessionStore

    /// ONE timer for the whole list. A per-row timer at 60 rows is 60 run-loop
    /// sources to render text that changes once a second.
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.rows.isEmpty {
                emptyState
            } else {
                list
            }
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(tick) { now = $0 }
    }

    private var rows: [SliceRow] {
        // Reading `ownerNameGeneration` registers the dependency that makes a
        // late-resolved app name repaint the row.
        _ = store.ownerNameGeneration
        return SliceRow.build(from: store.rows, ownerName: store.ownerName(forPid:))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    Button {
                        store.focus(row.session)
                    } label: {
                        rowBody(row)
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func rowBody(_ row: SliceRow) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: row.symbol)
                    .frame(width: 14)
                Text(row.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !row.hasTerminal {
                    Text("no terminal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(row.stateText)
                    .foregroundStyle(.secondary)
                Text(elapsedText(now.timeIntervalSince(row.session.updatedAt)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let detail = row.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No agent sessions.")
            if !store.hookInstalled {
                Text("Hook not installed — run scripts/install_hook.sh")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var footer: some View {
        if store.tccBlocked {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text(Tcc.remedy)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Automation settings") {
                    guard let url = URL(string: automationSettingsURL) else { return }
                    NSWorkspace.shared.open(url)
                }
                .controlSize(.small)
            }
            .padding(10)
        }
    }
}

private let automationSettingsURL =
    "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
