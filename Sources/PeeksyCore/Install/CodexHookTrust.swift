import Foundation

/// What Codex has been told about our hooks — read from ITS record, never
/// inferred from ours.
///
/// Registering a hook in `hooks.json` is necessary and not sufficient. Codex
/// "records trust against the hook's current hash, so new or changed hooks are
/// marked for review and skipped until trusted". That record lives in
/// `$CODEX_HOME/config.toml` under `[hooks.state."<key>"]`, one table per
/// hook, and only the `/hooks` browser inside Codex writes it. A skipped hook
/// leaves no trace anywhere else we can read — nothing on the socket, nothing
/// in Codex's own log — so this is the one check that separates "registered"
/// from "running". `--doctor` prints it. The installer never writes it: that
/// file is somebody else's, and a trust grant is the user's to give.
///
/// The key Codex uses is `<hooks.json path>:<snake_case event>:<group>:<hook>`,
/// where the last two are OUR entry's coordinates in the event's array — which
/// is why `SettingsMerge.positions` exists rather than assuming `0:0`. The hash
/// covers the hook definition (the JSON entry), not the script body: swapping
/// the script in place does not invalidate trust, changing the entry does. We
/// cannot recompute Codex's hash, so "trusted" here means "a trust record
/// exists", and a definition edited since it was recorded will still read as
/// trusted until Codex re-lists it.
///
/// Pure. The TOML handling is deliberately narrow: table headers of the exact
/// shape Codex writes and the two keys it puts under them. Everything else in
/// the file is skipped, and a file we cannot make sense of reads as "no
/// record" — never as somebody else's hook being ours.
public enum CodexHookTrust {

    public enum Status: Equatable, Sendable {
        /// A `trusted_hash` is recorded and the hook has not been switched off.
        case trusted
        /// Trusted once, then disabled in `/hooks`. It will not run.
        case disabled
        /// No record. Codex has never been asked, or the definition changed
        /// since it was. It will not run.
        case untrusted
    }

    public struct Entry: Equatable, Sendable {
        public let event: String
        public let status: Status
    }

    public struct Report: Equatable, Sendable {
        /// In the order the events were asked about, which is install order.
        public let entries: [Entry]

        public var trusted: [String] { entries.filter { $0.status == .trusted }.map(\.event) }
        public var disabled: [String] { entries.filter { $0.status == .disabled }.map(\.event) }
        public var untrusted: [String] { entries.filter { $0.status == .untrusted }.map(\.event) }
        public var isFullyTrusted: Bool { !entries.isEmpty && trusted.count == entries.count }

        /// One line for `--doctor`. Counts, then names, then what to do —
        /// "8/8 trusted" is checkable and "looks fine" is not.
        public var summary: String {
            guard !entries.isEmpty else { return "nothing registered to check" }
            var line = "\(trusted.count)/\(entries.count) trusted by Codex"
            if isFullyTrusted { return line }
            if untrusted.count == entries.count {
                return line + " — open /hooks in Codex and trust the Peeksy hooks"
            }
            if !disabled.isEmpty {
                line += " · \(disabled.count) disabled (\(disabled.joined(separator: ", ")))"
            }
            if !untrusted.isEmpty {
                line += " · \(untrusted.count) need\(untrusted.count == 1 ? "s" : "") review (\(untrusted.joined(separator: ", ")))"
            }
            return line + " — open /hooks in Codex"
        }
    }

    /// `PreToolUse` → `pre_tool_use`. Codex keys its state by the snake-case
    /// form of the event even though `hooks.json` spells it in PascalCase.
    public static func snakeCase(_ event: String) -> String {
        var out = ""
        for (index, ch) in event.enumerated() {
            if ch.isUppercase, index > 0 { out.append("_") }
            out.append(ch.lowercased())
        }
        return out
    }

    /// Codex's key for one hook.
    public static func stateKey(settingsPath: String, event: String, position: SettingsMerge.Position) -> String {
        "\(settingsPath):\(snakeCase(event)):\(position.group):\(position.hook)"
    }

    /// The status of each event we hold a position for, in `events` order.
    /// Events with no position are not registered and are left out; the
    /// installer's own probe already reports that.
    public static func audit(
        configTOML: String,
        settingsPath: String,
        events: [String],
        positions: [String: SettingsMerge.Position]
    ) -> Report {
        let records = parseStateTables(configTOML)
        var entries: [Entry] = []
        for event in events {
            guard let position = positions[event] else { continue }
            let key = stateKey(settingsPath: settingsPath, event: event, position: position)
            let status: Status
            if let record = records[key], record.hasHash {
                status = record.enabled ? .trusted : .disabled
            } else {
                status = .untrusted
            }
            entries.append(Entry(event: event, status: status))
        }
        return Report(entries: entries)
    }

    // MARK: - TOML, the two lines of it we need

    struct StateRecord: Equatable {
        var hasHash = false
        var enabled = true
    }

    /// Every `[hooks.state."<key>"]` table and the `trusted_hash` / `enabled`
    /// lines beneath it, keyed by `<key>`. Any other header ends the table.
    static func parseStateTables(_ toml: String) -> [String: StateRecord] {
        var records: [String: StateRecord] = [:]
        var current: String?
        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") {
                current = stateTableKey(line)
                if let key = current, records[key] == nil { records[key] = StateRecord() }
                continue
            }
            guard let key = current, let pair = keyValue(line) else { continue }
            switch pair.name {
            case "trusted_hash": records[key]?.hasHash = !pair.value.isEmpty
            case "enabled": records[key]?.enabled = pair.value != "false"
            default: break
            }
        }
        return records
    }

    /// `[hooks.state."/path/hooks.json:stop:0:0"]` → the quoted key. Single
    /// quotes are accepted too; TOML allows either. Anything else → `nil`.
    static func stateTableKey(_ header: String) -> String? {
        let prefix = "[hooks.state."
        guard header.hasPrefix(prefix), header.hasSuffix("]") else { return nil }
        var inner = header.dropFirst(prefix.count).dropLast()
        while inner.last == " " { inner = inner.dropLast() }
        guard let quote = inner.first, quote == "\"" || quote == "'",
              inner.count >= 2, inner.last == quote else { return nil }
        let body = inner.dropFirst().dropLast()
        return quote == "'" ? String(body) : unescape(String(body))
    }

    /// `name = "value"` or `name = true` → `(name, value)`, quotes and a
    /// trailing comment stripped.
    private static func keyValue(_ line: String) -> (name: String, value: String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let name = line[..<eq].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), let close = value.dropFirst().firstIndex(of: "\"") {
            value = unescape(String(value[value.index(after: value.startIndex)..<close]))
        } else if value.hasPrefix("'"), let close = value.dropFirst().firstIndex(of: "'") {
            value = String(value[value.index(after: value.startIndex)..<close])
        } else if let hash = value.firstIndex(of: "#") {
            value = value[..<hash].trimmingCharacters(in: .whitespaces)
        }
        return (name, value)
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}
