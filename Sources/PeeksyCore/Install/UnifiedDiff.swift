import Foundation

/// A small unified diff over lines. Pure, no dependencies, no shelling out to
/// `diff(1)`.
///
/// It exists so the user can approve a change to their own settings file having
/// SEEN it. Both sides are serialized through `SettingsIO.canonicalData` first,
/// so the reordering `JSONSerialization` imposes cancels out and what is left on
/// screen is only what the merge actually did.
public enum UnifiedDiff {

    /// Above this, the O(n·m) table stops being free. A settings file is a few
    /// hundred lines; anything near this bound is not a settings file, and a
    /// count is more honest than a diff we made the user wait for.
    static let lineLimit = 4000

    public static func between(
        _ before: String,
        _ after: String,
        fromLabel: String = "before",
        toLabel: String = "after",
        context: Int = 3
    ) -> String {
        let a = before.components(separatedBy: "\n")
        let b = after.components(separatedBy: "\n")
        if a == b { return "" }

        guard a.count <= lineLimit, b.count <= lineLimit else {
            return "(files are too large to diff line by line: \(a.count) → \(b.count) lines)"
        }

        let ops = script(a, b)
        let hunks = hunks(from: ops, context: context)
        guard !hunks.isEmpty else { return "" }

        var out = ["--- \(fromLabel)", "+++ \(toLabel)"]
        for hunk in hunks {
            out.append(hunk.header)
            out.append(contentsOf: hunk.lines)
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Edit script

    enum Op: Equatable {
        case keep(String)
        case remove(String)
        case insert(String)
    }

    /// Classic LCS table plus a backtrack. Chosen over Myers because the input
    /// is small and bounded, and because a table you can read is worth more here
    /// than an algorithm you cannot.
    static func script(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        // (n+1) × (m+1), flattened. `width` and not `stride` — the latter
        // shadows the global `stride(from:through:by:)` used just below.
        let width = m + 1
        var lcs = [Int](repeating: 0, count: (n + 1) * width)

        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i * width + j] = a[i] == b[j]
                        ? lcs[(i + 1) * width + (j + 1)] + 1
                        : max(lcs[(i + 1) * width + j], lcs[i * width + (j + 1)])
                }
            }
        }

        var ops: [Op] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                ops.append(.keep(a[i])); i += 1; j += 1
            } else if lcs[(i + 1) * width + j] >= lcs[i * width + (j + 1)] {
                ops.append(.remove(a[i])); i += 1
            } else {
                ops.append(.insert(b[j])); j += 1
            }
        }
        while i < n { ops.append(.remove(a[i])); i += 1 }
        while j < m { ops.append(.insert(b[j])); j += 1 }
        return ops
    }

    // MARK: - Hunks

    struct Hunk {
        let header: String
        let lines: [String]
    }

    private static func hunks(from ops: [Op], context: Int) -> [Hunk] {
        // Indices of every changed op, so the context windows can be grown
        // around them and merged where they overlap.
        let changed = ops.indices.filter { isChange(ops[$0]) }
        guard !changed.isEmpty else { return [] }

        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let lower = max(0, index - context)
            let upper = min(ops.count - 1, index + context)
            if let last = ranges.last, lower <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, upper)
            } else {
                ranges.append(lower...upper)
            }
        }

        // Line numbers are 1-based and counted per side, so they have to be
        // accumulated across the whole script rather than per hunk.
        var beforeLine = 1, afterLine = 1
        var startBefore: [Int: Int] = [:], startAfter: [Int: Int] = [:]
        for (index, op) in ops.enumerated() {
            startBefore[index] = beforeLine
            startAfter[index] = afterLine
            switch op {
            case .keep: beforeLine += 1; afterLine += 1
            case .remove: beforeLine += 1
            case .insert: afterLine += 1
            }
        }

        return ranges.map { range in
            var lines: [String] = []
            var removed = 0, inserted = 0, kept = 0
            for index in range {
                switch ops[index] {
                case let .keep(line): lines.append(" " + line); kept += 1
                case let .remove(line): lines.append("-" + line); removed += 1
                case let .insert(line): lines.append("+" + line); inserted += 1
                }
            }
            let header = "@@ -\(startBefore[range.lowerBound] ?? 1),\(kept + removed)"
                + " +\(startAfter[range.lowerBound] ?? 1),\(kept + inserted) @@"
            return Hunk(header: header, lines: lines)
        }
    }

    private static func isChange(_ op: Op) -> Bool {
        if case .keep = op { return false }
        return true
    }
}
