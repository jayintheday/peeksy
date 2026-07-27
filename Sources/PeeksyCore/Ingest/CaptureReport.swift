import Foundation

/// What a capture file actually says. Pure, so it is testable against fixture
/// lines rather than against a day of somebody's work.
///
/// The question this exists to answer is narrow and specific: **which
/// `notification_type` values does Claude Code really send, and do they match
/// the three we hard-coded in `HookEnvelope.attentionNotifications`?** Everything
/// else here is context for reading that answer.
public struct CaptureReport: Sendable, Equatable {

    public struct Counted: Sendable, Equatable {
        public let value: String
        public let count: Int
    }

    public let totalEvents: Int
    public let unparseable: Int
    /// `hook_event_name` → count. Events we never registered show up here too.
    public let eventNames: [Counted]
    /// `notification_type` → count, across every `Notification` event.
    public let notificationTypes: [Counted]
    /// Values we WOULD treat as "needs a human".
    public let recognisedAttention: [Counted]
    /// Values that arrived and that we currently ignore. **The finding.** Any
    /// entry here is a moment the pill should have gone red and did not.
    public let unrecognisedAttention: [Counted]
    /// Values we are watching for that never arrived. Dead constants.
    public let neverSeenAttention: [String]
    public let distinctSessions: Int
    /// How often each top-level key was present. Reveals which fields are
    /// actually populated versus which ones we hopefully read.
    public let fieldPresence: [Counted]

    public var sawAnyNotification: Bool { !notificationTypes.isEmpty }

    // MARK: - Building

    /// Parse a JSONL capture file.
    public static func parse(_ text: String, attention: Set<String> = HookEnvelope.attentionNotifications) -> CaptureReport {
        var total = 0, unparseable = 0
        var events: [String: Int] = [:]
        var notifications: [String: Int] = [:]
        var sessions = Set<String>()
        var fields: [String: Int] = [:]

        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            total += 1
            guard let line = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let body = line["body"] as? [String: Any]
            else {
                unparseable += 1
                continue
            }

            for key in body.keys { fields[key, default: 0] += 1 }

            let event = (body["hook_event_name"] as? String) ?? "(none)"
            events[event, default: 0] += 1

            if let id = body["session_id"] as? String, !id.isEmpty { sessions.insert(id) }

            // Read the field regardless of the event name. If the value we need
            // arrives under an event we did not expect, that is exactly the kind
            // of thing this report has to be able to show.
            if let type = body["notification_type"] as? String, !type.isEmpty {
                notifications[type, default: 0] += 1
            }
        }

        let recognised = notifications.filter { attention.contains($0.key) }
        let unrecognised = notifications.filter { !attention.contains($0.key) }

        return CaptureReport(
            totalEvents: total,
            unparseable: unparseable,
            eventNames: sorted(events),
            notificationTypes: sorted(notifications),
            recognisedAttention: sorted(recognised),
            unrecognisedAttention: sorted(unrecognised),
            neverSeenAttention: attention.subtracting(notifications.keys).sorted(),
            distinctSessions: sessions.count,
            fieldPresence: sorted(fields)
        )
    }

    /// Descending by count, then by name, so the output is stable.
    private static func sorted(_ counts: [String: Int]) -> [Counted] {
        counts.map { Counted(value: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.value < $1.value }
    }

    // MARK: - Rendering

    public var description: String {
        var out: [String] = []
        out.append("events captured:  \(totalEvents)"
            + (unparseable > 0 ? "  (\(unparseable) unparseable)" : ""))
        out.append("distinct sessions: \(distinctSessions)")
        out.append("")

        out.append("hook events seen:")
        if eventNames.isEmpty { out.append("  (none)") }
        for e in eventNames { out.append("  \(pad(e.value))  \(e.count)") }
        out.append("")

        out.append("notification_type values seen:")
        if notificationTypes.isEmpty {
            out.append("  (none — no Notification event carried one)")
        }
        for n in notificationTypes {
            let mark = recognisedAttention.contains(n) ? "→ ATTENTION" : "   ignored"
            out.append("  \(pad(n.value))  \(n.count)   \(mark)")
        }
        out.append("")

        // The verdict, stated plainly, because this is the whole point.
        if !unrecognisedAttention.isEmpty {
            out.append("FINDING: these arrived and we IGNORE them —")
            out.append("         every one is a moment the pill should have gone red and did not:")
            for n in unrecognisedAttention { out.append("           \(n.value)  (\(n.count)×)") }
            out.append("")
        }
        if !neverSeenAttention.isEmpty {
            out.append("FINDING: we watch for these and they NEVER arrived —")
            out.append("         each is a dead constant until proven otherwise:")
            for value in neverSeenAttention { out.append("           \(value)") }
            out.append("")
        }
        if unrecognisedAttention.isEmpty && neverSeenAttention.isEmpty && sawAnyNotification {
            out.append("VERDICT: attentionNotifications matches what actually arrives.")
            out.append("")
        }
        if !sawAnyNotification {
            out.append("VERDICT: no Notification carried a notification_type in this capture.")
            out.append("         Either none occurred, or the field is named something else —")
            out.append("         check `fields present` below against what you expected.")
            out.append("")
        }

        out.append("fields present, by frequency:")
        for f in fieldPresence { out.append("  \(pad(f.value))  \(f.count)") }
        return out.joined(separator: "\n")
    }

    private func pad(_ s: String) -> String {
        s.padding(toLength: max(24, s.count), withPad: " ", startingAt: 0)
    }
}
